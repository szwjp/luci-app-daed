#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# 改造自 luci-app-homeproxy-pro 的同名脚本。
# 关键差异（与 homeproxy 的）：
#   - 本仓有两个包（luci-app-daed + daed），一个 i18n 子包（luci-i18n-daed-zh-cn）。
#     homeproxy 只有一个包；本脚本在循环里跑两个。
#   - luci-app-daed 是纯 lua + po + root（PKGARCH=all），用 homeproxy 套路。
#   - daed 走「路径 A」：从 szwjp/daed GitHub Release 拉 59.6MB Go 二进制，
#     解包后只挑 binary + init + UCI 模板入包；没有 native 编译。
#   - conffiles 列表、control 字段与 homeproxy 保持一致格式。

set -o errexit
set -o pipefail
set -o nounset

PKG_MGR="${1:-apk}"
RELEASE_TYPE="${2:-snapshot}"

if [[ "$PKG_MGR" != "apk" && "$PKG_MGR" != "ipk" ]]; then
	echo "error: unknown package manager '$PKG_MGR' (expected apk or ipk)" >&2
	exit 1
fi

export PKG_SOURCE_DATE_EPOCH="$(date "+%s")"
export SOURCE_DATE_EPOCH="$PKG_SOURCE_DATE_EPOCH"

BASE_DIR="$(cd "$(dirname "$0")"; pwd)"
PKG_DIR="$BASE_DIR/.."

# 要打的包：每个元素是 "<子目录名>:<LuCI_luci_name>"
# - luci-app-daed : 走 homeproxy 套路（PKGARCH=all）
# - daed          : 路径 A，从 szwjp/daed release 拉 binary
PACKAGES=(
	"luci-app-daed"
	"daed"
)

# ——— 通用解析 ———

get_mk_value() {
	# $1=Makefile 路径, $2=变量名
	awk -F "${2}:=" '/^'"${2}"':=/{print $2}' "$1" | xargs
}

get_mk_multiline_value() {
	# awk 处理多行续行（行尾 \\ 折叠）。原 homeproxy 用 sed + grep -P，
	# 在 macOS BSD sed / BSD grep 上会坏（CI 是 Linux GNU 工具，没问题；
	# 这里改成 portable，让 macOS 上 dry-run 也能用）。
	awk -v var="$2" '
		BEGIN { inblk=0; buf="" }
		$0 ~ "^"var":=" { inblk=1; buf=$0; sub(/^[^=]+=/, "", buf); next }
		inblk && /\\$/ { sub(/\\$/, "", $0); buf = buf " " $0; next }
		inblk { print buf; inblk=0; buf="" }
	' "$1" \
		| tr -s ' \t' ' ' \
		| sed -E 's/(^| )\+/\1/g' \
		| xargs || true
}

# 算 sha256（macOS 用 shasum，Linux 用 sha256sum）
sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

# 过滤掉 ipk/apk 里无法表达的 OpenWrt 构建期依赖语法。
#
# OpenWrt Makefile 的 DEPENDS 里有三种东西，只有第一种能进包的 Depends 字段：
#   1. 普通包名             kmod-veth / v2ray-geoip        -> 保留
#   2. buildconfig 依赖     @KERNEL_XDP_SOCKETS             -> 丢弃（内核 .config 选项，
#                              只在 OpenWrt 构建期有意义，opkg 不认）
#   3. 包配置变体依赖       DAED_USE_VMLINUX_BTF:vmlinux-btf -> 丢弃（依赖 menuconfig
#                              里的选择项，自建 ipk 无法表达；BTF 来源是运行时的事）
filter_runtime_deps() {
	local out="" t
	for t in $1; do
		case "$t" in
			@*) continue ;;
			[A-Z0-9_]*:*) continue ;;
		esac
		out="${out:+$out }$t"
	done
	printf '%s' "$out"
}

get_conffiles() {
	# $1=Makefile 路径, $2=PKG_NAME
	# 过滤 # 开头的注释行（OpenWrt Makefile 里常用注释解释为什么这些文件是 conffiles）
	awk -v pkg="$2" '
		$0 ~ "^define Package/"pkg"/conffiles" { flag=1; next }
		flag && /^endef/ { flag=0; next }
		flag && NF && !/^[ \t]*#/ { print }
	' "$1"
}

# 把 Makefile 变量引用 $(VAR) 替换成实际值（最多递归 5 层）。
# 用途：PKG_SOURCE_URL 里写的是 .../download/$(DAED_RELEASE_TAG)，这是 make 语法，
# shell 不会展开，需要这里手工展开后才能拿去 curl。
# 纯 awk + index 实现，避开 mawk/gawk 与 sed 转义的差异。
expand_mk_refs() {
	local mk="$1" s="$2"
	local i name val
	for i in 1 2 3 4 5; do
		name="$(printf '%s' "$s" | awk 'match($0, /\$\([A-Za-z_][A-Za-z0-9_]*\)/) { print substr($0, RSTART+2, RLENGTH-3); exit }')"
		[ -n "$name" ] || break
		val="$(get_mk_value "$mk" "$name")"
		s="$(printf '%s' "$s" | awk -v n="$name" -v v="$val" '{
			pat = "$(" n ")"
			out = ""
			while ((p = index($0, pat)) > 0) {
				out = out substr($0, 1, p - 1) v
				$0 = substr($0, p + length(pat))
			}
			print out $0
		}')"
	done
	printf '%s' "$s"
}

# 读 define Package/<pkg>/... 块里的某个变量赋值。
# 用途：daed/Makefile 把 DEPENDS 写在 define Package/daed 块里（不是行内 PKG_DEPENDS:=）。
# 用法：get_pkg_define_var daed/Makefile daed DEPENDS
get_pkg_define_var() {
	local mk="$1" pkg="$2" var="$3"
	# 第一步：sed 取 define Package/<pkg> 到对应 endef 的所有行
	local block
	block="$(sed -n "/^define Package\/${pkg}\$/,/^endef/p" "$mk")"
	# 第二步：awk 折叠续行、提取 <var>:= 后的内容
	# 把 awk 脚本写到独立文件传给 awk -f，避免命令行内联多行单引号
	# 字符串在 macOS / Linux 上行为差异。
	local awk_script
	awk_script="$(mktemp)"
	cat > "$awk_script" <<'EOF'
		BEGIN { buf="" }
		{
			t = $0
			p2 = index(t, VAR ":=")
			if (buf == "" && p2 == 0) next
			if (buf == "" && p2 > 0) {
				t = substr(t, p2 + length(VAR) + 2)
			}
			# 去行尾反斜杠（续行符）
			last_char = substr(t, length(t))
			if (last_char == "\\") {
				buf = buf substr(t, 1, length(t) - 1)
				next
			}
			print buf t
			buf = ""
		}
EOF
	echo "$block" | awk -v VAR="$var" -f "$awk_script" | tr -s ' \t' ' ' | sed -E 's/(^| )\+/\1/g' | xargs
	rm -f "$awk_script"
}

# ——— 每个包打 ipk/apk ———

# 对每个 PKG 生成 2 个文件名：<apk> 和 <ipk>，最终移到 BASE_DIR
declare -a GENERATED_FILES=()

build_one() {
	local subdir="$1"
	local pkg_name
	local pkg_dir="$PKG_DIR/$subdir"
	local mk="$pkg_dir/Makefile"

	pkg_name="$(get_mk_value "$mk" PKG_NAME)"
	if [ -z "$pkg_name" ]; then
		echo "error: $mk 缺 PKG_NAME" >&2
		return 1
	fi
	local app_id="${pkg_name#luci-app-}"

	# luci-* 用 LUCI_DEPENDS；其它包（daed 等）用 define Package/.../DEPENDS
	local depends depends_raw
	if [[ "$pkg_name" == luci-* ]]; then
		depends_raw="$(get_mk_multiline_value "$mk" LUCI_DEPENDS)"
	else
		depends_raw="$(get_pkg_define_var "$mk" "$pkg_name" DEPENDS)"
	fi
	# 丢掉 @buildconfig 与 VAR:pkg 这类构建期语法（ipk 的 Depends 字段不认）
	depends="$(filter_runtime_deps "$depends_raw")"
	if [ -z "$depends" ]; then
		echo "warning: $mk 缺 DEPENDS，包会缺失运行时依赖" >&2
	elif [ "$depends" != "$depends_raw" ]; then
		echo "  依赖已过滤构建期项：'$depends_raw' -> '$depends'"
	fi

	local description
	if [[ "$pkg_name" == luci-* ]]; then
		description="$(get_mk_value "$mk" LUCI_TITLE)"
	else
		# 非 luci 包的 TITLE 写在 define Package/<pkg> 块里，不是顶层变量
		description="$(get_pkg_define_var "$mk" "$pkg_name" TITLE)"
	fi
	[ -n "$description" ] || description="$pkg_name"

	local pkg_arch
	pkg_arch="$(get_mk_value "$mk" PKG_ARCH)"
	if [ -z "$pkg_arch" ]; then
		# luci 应用包默认 all；daed 二进制包是 x86_64
		if [[ "$pkg_name" == luci-* ]]; then
			pkg_arch="all"
		else
			pkg_arch="x86_64"
		fi
	fi

	# apk v3 不认 `all`：它只接受 noarch（架构无关）或具体架构名。
	# 实测 ImmortalWrt 25.12 设备上 luci-base 是 A:noarch、luci-compat 是 A:x86_64，
	# 而带 arch:all 的包直接被判 "uninstallable"（arch: all / error: uninstallable）。
	# ipk/opkg 那边反过来用 `all`，所以只在 apk 分支做映射。
	local pkg_arch_apk="$pkg_arch"
	[ "$pkg_arch_apk" = "all" ] && pkg_arch_apk="noarch"

	local mk_pkg_version mk_pkg_release pkg_version
	mk_pkg_version="$(get_mk_value "$mk" PKG_VERSION)"
	mk_pkg_release="$(get_mk_value "$mk" PKG_RELEASE)"
	if [ -n "$mk_pkg_version" ]; then
		if [ -n "$mk_pkg_release" ]; then
			pkg_version="${mk_pkg_version}-r${mk_pkg_release}"
		else
			pkg_version="$mk_pkg_version"
		fi
	else
		pkg_version="${PKG_SOURCE_DATE_EPOCH}~$(git -C "$PKG_DIR" rev-parse --short HEAD)-r99"
	fi

	# conffiles（用 read 循环而不是 mapfile：mapfile 是 bash 4+ 内建，
	# macOS 自带 bash 3.2 没有，换掉后本地也能 dry-run）
	conffiles=()
	while IFS= read -r line; do
		[ -n "$line" ] && conffiles+=("$line")
	done < <(get_conffiles "$mk" "$pkg_name")
	if [ "${#conffiles[@]}" -eq 0 ]; then
		echo "warning: $mk 缺 Package/$pkg_name/conffiles，包会缺 conffile 保护" >&2
	fi

	if [ "$PKG_MGR" = "apk" ]; then
		echo "=== Building $pkg_name $pkg_version (apk, arch=$pkg_arch_apk) ==="
	else
		echo "=== Building $pkg_name $pkg_version (ipk, arch=$pkg_arch) ==="
	fi

	local temp_dir temp_pkg_dir
	temp_dir="$(mktemp -d "$BASE_DIR/tmp.XXXXXX")"
	trap 'rm -rf "$temp_dir"' EXIT
	temp_pkg_dir="$temp_dir/$pkg_name"
	mkdir -p "$temp_pkg_dir/lib/upgrade/keep.d/"

	if [ "$PKG_MGR" == "apk" ]; then
		mkdir -p "$temp_pkg_dir/lib/apk/packages/"
		mkdir -p "$temp_pkg_dir/usr/lib/lua/luci/i18n/"
	else
		mkdir -p "$temp_pkg_dir/CONTROL/"
	fi

	# —— 装包内文件 ——
	if [ "$pkg_name" = "luci-app-daed" ]; then
		# LuCI 应用的目录映射（与 OpenWrt feeds/luci/luci.mk 的产物一致）：
		#   luasrc/  -> /usr/lib/lua/luci/      控制器、cbi 模型、view 模板
		#   root/    -> /                        init / hotplug / acl 等直接进根
		#   po/      -> 不进本包（编译成 .lmo 后由 luci-i18n-* 子包提供）
		#   htdocs/  -> /www/
		if [ -d "$pkg_dir/luasrc" ]; then
			mkdir -p "$temp_pkg_dir/usr/lib/lua/luci"
			cp -fpR "$pkg_dir/luasrc/." "$temp_pkg_dir/usr/lib/lua/luci/"
		fi
		if [ -d "$pkg_dir/root" ]; then
			cp -fpR "$pkg_dir/root/." "$temp_pkg_dir/"
		fi
		if [ -d "$pkg_dir/htdocs" ]; then
			mkdir -p "$temp_pkg_dir/www"
			cp -fpR "$pkg_dir/htdocs/." "$temp_pkg_dir/www/"
		fi
	elif [ "$pkg_name" = "daed" ]; then
		# 路径 A：从 szwjp/daed release 拉 tarball，按 daed/Makefile 的 install 段组装
		local pkg_hash pkg_source src_url tarball_url
		pkg_hash="$(get_mk_value "$mk" PKG_HASH)"
		if [ -z "$pkg_hash" ] || [ "$pkg_hash" = "skip" ]; then
			echo "error: $mk PKG_HASH 未设置（先跑 scripts/release-sync.sh 同步）" >&2
			return 1
		fi
		# 直接用 Makefile 里的 PKG_SOURCE_URL + PKG_SOURCE，避免两处各拼一次 URL 漂移。
		# OpenWrt 的约定：PKG_SOURCE_URL 是「目录」，PKG_SOURCE 是「文件名」，
		# 完整下载地址 = ${PKG_SOURCE_URL}/${PKG_SOURCE}。
		pkg_source="$(get_mk_value "$mk" PKG_SOURCE)"
		src_url="$(get_mk_value "$mk" PKG_SOURCE_URL)"
		if [ -z "$pkg_source" ] || [ -z "$src_url" ]; then
			echo "error: $mk 缺 PKG_SOURCE / PKG_SOURCE_URL" >&2
			return 1
		fi
		# PKG_SOURCE_URL 里可能有 $(DAED_RELEASE_TAG) 这类 make 变量引用，先展开
		src_url="$(expand_mk_refs "$mk" "$src_url")"
		tarball_url="${src_url%/}/${pkg_source}"
		local tarball="$temp_dir/$pkg_source"
		echo "  fetch $tarball_url"
		curl --fail --silent --show-error --location --output "$tarball" "$tarball_url" \
			|| { echo "error: 下载 release tarball 失败：$tarball_url" >&2; return 1; }
		# 校验 hash
		local actual
		actual="$(sha256_of "$tarball")"
		if [ "$actual" != "$pkg_hash" ]; then
			echo "error: release tarball hash 不符（期望 $pkg_hash，实测 $actual）" >&2
			return 1
		fi
		# 解包到 temp_dir 下的临时目录（不要放 temp_pkg_dir，否则整个 tarball
		# 内容会跟着进包 —— 里面有 16MB geoip + 11MB geosite + 图标）
		local src_dir="$temp_dir/daed-src"
		mkdir -p "$src_dir"
		tar -xzf "$tarball" -C "$src_dir"
		# 按 daed/Makefile 的 Package/daed/install 段复制（只挑要的）
		mkdir -p "$temp_pkg_dir/usr/bin"
		cp -fp "$src_dir/daed-linux-x86_64" "$temp_pkg_dir/usr/bin/daed"
		chmod 0755 "$temp_pkg_dir/usr/bin/daed"
		mkdir -p "$temp_pkg_dir/etc/init.d"
		cp -fp "$pkg_dir/files/daed.init" "$temp_pkg_dir/etc/init.d/daed"
		chmod 0755 "$temp_pkg_dir/etc/init.d/daed"
		mkdir -p "$temp_pkg_dir/etc/config"
		cp -fp "$pkg_dir/files/daed.config" "$temp_pkg_dir/etc/config/daed"
		chmod 0644 "$temp_pkg_dir/etc/config/daed"
		mkdir -p "$temp_pkg_dir/etc/daed"  # 目录占位；wing.db / geo 数据运行时建
		rm -rf "$src_dir"
	fi

	# —— conffiles 写入 lib/upgrade/keep.d/<pkg>（apk 路径才有效，但写了无害）——
	if [ "${#conffiles[@]}" -gt 0 ]; then
		{
			for f in "${conffiles[@]}"; do
				# 跳过 /etc/config/<app> 自身的 keep（apk 自带 conffiles 处理）
				[[ "$f" == "/etc/config/$app_id" ]] && continue
				echo "$f"
			done
		} > "$temp_pkg_dir/lib/upgrade/keep.d/$pkg_name"
		[ -s "$temp_pkg_dir/lib/upgrade/keep.d/$pkg_name" ] || \
			rm -f "$temp_pkg_dir/lib/upgrade/keep.d/$pkg_name"
	fi

	# —— 打 apk / ipk ——
	if [ "$PKG_MGR" == "apk" ]; then
		# 可移植的 apk 文件清单：GNU find 的 -printf 在 macOS/BSD 上没有，
		# 用 find + sed 生成同样的 "/路径" 列表（CI 是 Linux，两边都能跑）
		( cd "$temp_pkg_dir" && find . \( -type f -o -type l \) | sed 's|^\./|/|' | sort ) \
			> "$temp_dir/$pkg_name.list"
		mv "$temp_dir/$pkg_name.list" "$temp_pkg_dir/lib/apk/packages/$pkg_name.list"

		if [ "${#conffiles[@]}" -gt 0 ]; then
			printf '%s\n' "${conffiles[@]}" > "$temp_pkg_dir/lib/apk/packages/$pkg_name.conffiles"
		else
			echo "/etc/config/$app_id" > "$temp_pkg_dir/lib/apk/packages/$pkg_name.conffiles"
		fi
		# 算静态 hash（apk v3 用 .conffiles_static）
		if [ -f "$temp_pkg_dir/lib/apk/packages/$pkg_name.conffiles" ]; then
			while IFS= read -r file; do
				[ -f "$temp_pkg_dir/$file" ] || continue
				csum="$(sha256_of "$temp_pkg_dir/$file")"
				echo "$file $csum" >> "$temp_pkg_dir/lib/apk/packages/$pkg_name.conffiles_static"
			done < "$temp_pkg_dir/lib/apk/packages/$pkg_name.conffiles"
		fi

		cat > "$temp_dir/post-install" <<-EOF
			#!/bin/sh
			[ "\${IPKG_NO_SCRIPT}" = "1" ] && exit 0
			[ -s \${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
			. \${IPKG_INSTROOT}/lib/functions.sh
			export root="\${IPKG_INSTROOT}"
			export pkgname="$pkg_name"
			add_group_and_user
			default_postinst
			[ -n "\${IPKG_INSTROOT}" ] || {
				rm -f /tmp/luci-indexcache.*
				rm -rf /tmp/luci-modulecache/
				killall -HUP rpcd 2>/dev/null
				exit 0
			}
		EOF

		cat > "$temp_dir/post-upgrade" <<-EOF
			#!/bin/sh
			export PKG_UPGRADE=1
			[ "\${IPKG_NO_SCRIPT}" = "1" ] && exit 0
			[ -s \${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
			. \${IPKG_INSTROOT}/lib/functions.sh
			export root="\${IPKG_INSTROOT}"
			export pkgname="$pkg_name"
			add_group_and_user
			default_postinst
			[ -n "\${IPKG_INSTROOT}" ] || {
				rm -f /tmp/luci-indexcache.*
				rm -rf /tmp/luci-modulecache/
				killall -HUP rpcd 2>/dev/null
				exit 0
			}
		EOF

		cat > "$temp_dir/pre-deinstall" <<-EOF
			#!/bin/sh
			[ -s \${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
			. \${IPKG_INSTROOT}/lib/functions.sh
			export root="\${IPKG_INSTROOT}"
			export pkgname="$pkg_name"
			default_prerm
		EOF

		apk mkpkg \
			--info "name:$pkg_name" \
			--info "version:$pkg_version" \
			--info "description:$description" \
			--info "arch:$pkg_arch_apk" \
			--info "origin:$pkg_name" \
			--info "maintainer:szwjp <szwjp@users.noreply.github.com>" \
			${depends:+--info "depends:libc $depends"} \
			--script "post-install:$temp_dir/post-install" \
			--script "post-upgrade:$temp_dir/post-upgrade" \
			--script "pre-deinstall:$temp_dir/pre-deinstall" \
			--files "$temp_pkg_dir" \
			--output "$temp_dir/${pkg_name}-${pkg_version}.apk"

		mv "$temp_dir/${pkg_name}-${pkg_version}.apk" "$BASE_DIR/${pkg_name}-${pkg_version}.apk"
		GENERATED_FILES+=("$BASE_DIR/${pkg_name}-${pkg_version}.apk")
	else
		# ipk
		mkdir -p "$temp_pkg_dir/CONTROL/"

		cat > "$temp_pkg_dir/CONTROL/control" <<-EOF
			Package: $pkg_name
			Version: $pkg_version
			Depends: libc, ${depends// /, }
			Source: $pkg_name
			SourceName: $pkg_name
			Section: $(if [[ "$pkg_name" == luci-* ]]; then echo luci; else echo net; fi)
			SourceDateEpoch: $PKG_SOURCE_DATE_EPOCH
			Maintainer: szwjp <szwjp@users.noreply.github.com>
			Architecture: $pkg_arch
			Installed-Size: TO-BE-FILLED-BY-IPKG-BUILD
			Description: $description
		EOF
		chmod 0644 "$temp_pkg_dir/CONTROL/control"

		if [ "${#conffiles[@]}" -gt 0 ]; then
			printf '%s\n' "${conffiles[@]}" > "$temp_pkg_dir/CONTROL/conffiles"
		else
			echo "/etc/config/$app_id" > "$temp_pkg_dir/CONTROL/conffiles"
		fi

		cat > "$temp_pkg_dir/CONTROL/postinst" <<-'EOF'
			#!/bin/sh
			[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
			[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
			. ${IPKG_INSTROOT}/lib/functions.sh
			default_postinst $0 $@
		EOF
		chmod 0755 "$temp_pkg_dir/CONTROL/postinst"

		# LuCI 应用专属：装完清 LuCI 缓存 + 跑 uci-defaults。
		# 非 luci 包（daed）不需要这一段，所以只在 luci-* 时写。
		if [[ "$pkg_name" == luci-* ]]; then
			cat > "$temp_pkg_dir/CONTROL/postinst-pkg" <<-EOF
				[ -n "\${IPKG_INSTROOT}" ] || {
					[ -f /etc/uci-defaults/luci-$app_id ] && . /etc/uci-defaults/luci-$app_id && rm -f /etc/uci-defaults/luci-$app_id
					rm -f /tmp/luci-indexcache
					rm -rf /tmp/luci-modulecache/
					exit 0
				}
			EOF
			chmod 0755 "$temp_pkg_dir/CONTROL/postinst-pkg"
		fi

		cat > "$temp_pkg_dir/CONTROL/prerm" <<-'EOF'
			#!/bin/sh
			[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
			. ${IPKG_INSTROOT}/lib/functions.sh
			default_prerm $0 $@
		EOF
		chmod 0755 "$temp_pkg_dir/CONTROL/prerm"

		ipkg-build -m "" "$temp_pkg_dir" "$temp_dir"
		local ipk_name
		ipk_name="$(ls "$temp_dir"/${pkg_name}_${pkg_version}_*.ipk 2>/dev/null | head -1)"
		if [ -z "$ipk_name" ]; then
			echo "error: ipkg-build 未产出 ${pkg_name}_${pkg_version}_*.ipk" >&2
			return 1
		fi
		mv "$ipk_name" "$BASE_DIR/${pkg_name}-${pkg_version}.ipk"
		GENERATED_FILES+=("$BASE_DIR/${pkg_name}-${pkg_version}.ipk")
	fi

	trap - EXIT
	rm -rf "$temp_dir"

	# 把最终文件名回显给 caller
	echo "$BASE_DIR/${pkg_name}-${pkg_version}.$PKG_MGR"
}

# ——— 主循环：每个包打一次 ———

for subdir in "${PACKAGES[@]}"; do
	build_one "$subdir"
done

# ——— i18n 子包（luci-i18n-daed-zh-cn）：仅对 luci-app-daed ———

build_i18n() {
	local main_pkg="luci-app-daed"
	local main_dir="$PKG_DIR/$main_pkg"
	local po_zh="$main_dir/po/zh_Hans/daed.po"
	local app_id="daed"
	local locale="zh-cn"

	if [ ! -f "$po_zh" ]; then
		echo "note: $po_zh 不存在，跳过 i18n 子包"
		return 0
	fi

	local mk_version="$(get_mk_value "$main_dir/Makefile" PKG_VERSION)"
	local mk_release="$(get_mk_value "$main_dir/Makefile" PKG_RELEASE)"
	local pkg_version
	if [ -n "$mk_version" ] && [ -n "$mk_release" ]; then
		pkg_version="${mk_version}-r${mk_release}"
	else
		pkg_version="${PKG_SOURCE_DATE_EPOCH}~$(git -C "$PKG_DIR" rev-parse --short HEAD)-r99"
	fi

	local temp_dir="$(mktemp -d "$BASE_DIR/tmp.XXXXXX")"
	trap 'rm -rf "$temp_dir"' EXIT

	local lmo_name="${app_id}.${locale}.lmo"
	po2lmo "$po_zh" "$temp_dir/$lmo_name"

	local i18n_name="luci-i18n-${app_id}-${locale}"
	local i18n_dir="$temp_dir/$i18n_name"
	mkdir -p "$i18n_dir/usr/lib/lua/luci/i18n/"
	cp "$temp_dir/$lmo_name" "$i18n_dir/usr/lib/lua/luci/i18n/"

	local description="$(get_mk_value "$main_dir/Makefile" LUCI_TITLE)"
	[ -n "$description" ] || description="$main_pkg"

	if [ "$PKG_MGR" == "apk" ]; then
		mkdir -p "$i18n_dir/lib/apk/packages/"
		( cd "$i18n_dir" && find . \( -type f -o -type l \) | sed 's|^\./|/|' | sort ) \
			> "$temp_dir/$i18n_name.list"
		mv "$temp_dir/$i18n_name.list" "$i18n_dir/lib/apk/packages/$i18n_name.list"
		apk mkpkg \
			--info "name:$i18n_name" \
			--info "version:$pkg_version" \
			--info "description:$description ($locale translation)" \
			--info "arch:noarch" \
			--info "depends:$main_pkg" \
			--files "$i18n_dir" \
			--output "$temp_dir/${i18n_name}-${pkg_version}.apk"
		mv "$temp_dir/${i18n_name}-${pkg_version}.apk" "$BASE_DIR/${i18n_name}-${pkg_version}.apk"
		GENERATED_FILES+=("$BASE_DIR/${i18n_name}-${pkg_version}.apk")
	else
		mkdir -p "$i18n_dir/CONTROL/"
		cat > "$i18n_dir/CONTROL/control" <<-EOF
			Package: $i18n_name
			Version: $pkg_version
			Depends: $main_pkg
			Architecture: all
			Description: $description ($locale translation)
		EOF
		ipkg-build -m "" "$i18n_dir" "$temp_dir"
		mv "$temp_dir/${i18n_name}_${pkg_version}_all.ipk" "$BASE_DIR/${i18n_name}-${pkg_version}.ipk"
		GENERATED_FILES+=("$BASE_DIR/${i18n_name}-${pkg_version}.ipk")
	fi

	trap - EXIT
	rm -rf "$temp_dir"
}

build_i18n

echo "=== Generated files ==="
ls -la "${GENERATED_FILES[@]}"
