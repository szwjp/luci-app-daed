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

get_conffiles() {
	# $1=Makefile 路径, $2=PKG_NAME
	# 过滤 # 开头的注释行（OpenWrt Makefile 里常用注释解释为什么这些文件是 conffiles）
	awk -v pkg="$2" '
		$0 ~ "^define Package/"pkg"/conffiles" { flag=1; next }
		flag && /^endef/ { flag=0; next }
		flag && NF && !/^[ \t]*#/ { print }
	' "$1"
}

# 读 define Package/<pkg>/... 块里的某个变量赋值。
# 用途：daed/Makefile 把 DEPENDS 写在 define Package/daed 块里（不是行内 PKG_DEPENDS:=）。
# 用法：get_pkg_define_var daed/Makefile daed DEPENDS
# 读 define Package/<pkg>/... 块里的某个变量赋值。
# 用途：daed/Makefile 把 DEPENDS 写在 define Package/daed 块里（不是行内 PKG_DEPENDS:=）。
# 用法：get_pkg_define_var daed/Makefile daed DEPENDS
#
# 实现细节：macOS / Linux 上 mawk/gawk 的 split/awk 语法差异较多，
# 这里用「sed 取段 + awk 简单提取」两段法，避免依赖 awk 的高级语义。
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
	local depends
	if [[ "$pkg_name" == luci-* ]]; then
		depends="$(get_mk_multiline_value "$mk" LUCI_DEPENDS)"
	else
		depends="$(get_pkg_define_var "$mk" "$pkg_name" DEPENDS)"
	fi
	if [ -z "$depends" ]; then
		echo "warning: $mk 缺 DEPENDS，包会缺失运行时依赖" >&2
	fi

	local description
	if [[ "$pkg_name" == luci-* ]]; then
		description="$(get_mk_value "$mk" LUCI_TITLE)"
	else
		description="$(get_mk_value "$mk" TITLE)"
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

	# conffiles
	mapfile -t conffiles < <(get_conffiles "$mk" "$pkg_name")
	if [ "${#conffiles[@]}" -eq 0 ]; then
		echo "warning: $mk 缺 Package/$pkg_name/conffiles，包会缺 conffile 保护" >&2
	fi

	echo "=== Building $pkg_name $pkg_version ($PKG_MGR, arch=$pkg_arch) ==="

	local temp_dir temp_pkg_dir
	temp_dir="$(mktemp -d -p "$BASE_DIR")"
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
		# 标准 LuCI 包：luasrc / po / root / htdocs
		[ -d "$pkg_dir/luasrc" ] && cp -fpR "$pkg_dir/luasrc" "$temp_pkg_dir/"
		[ -d "$pkg_dir/po" ]      && cp -fpR "$pkg_dir/po"      "$temp_pkg_dir/"
		[ -d "$pkg_dir/root" ]    && cp -fpR "$pkg_dir/root"    "$temp_pkg_dir/"
		[ -d "$pkg_dir/htdocs" ]  && cp -fpR "$pkg_dir/htdocs"  "$temp_pkg_dir/" 2>/dev/null || true
	elif [ "$pkg_name" = "daed" ]; then
		# 路径 A：从 szwjp/daed release 拉 tarball，按 daed/Makefile 的 install 段组装
		local pkg_hash tarball_url
		pkg_hash="$(get_mk_value "$mk" PKG_HASH)"
		if [ -z "$pkg_hash" ] || [ "$pkg_hash" = "skip" ]; then
			echo "error: $mk PKG_HASH 未设置（先跑 scripts/release-sync.sh 同步）" >&2
			return 1
		fi
		tarball_url="https://github.com/szwjp/daed/releases/download/v${mk_pkg_version}-nightly/daed-linux-x86_64.tar.gz"
		local tarball="$temp_dir/daed-linux-x86_64.tar.gz"
		echo "  fetch $tarball_url"
		curl --fail --silent --show-error --location --output "$tarball" "$tarball_url" \
			|| { echo "error: 下载 release tarball 失败：$tarball_url" >&2; return 1; }
		# 校验 hash
		local actual
		actual="$(shasum -a 256 "$tarball" | awk '{print $1}')"
		if [ "$actual" != "$pkg_hash" ]; then
			echo "error: release tarball hash 不符（期望 $pkg_hash，实测 $actual）" >&2
			return 1
		fi
		mkdir -p "$temp_pkg_dir/daed-src"
		tar -xzf "$tarball" -C "$temp_pkg_dir/daed-src"
		# 按 daed/Makefile 的 Package/daed/install 段复制
		mkdir -p "$temp_pkg_dir/usr/bin"
		cp -fp "$temp_pkg_dir/daed-src/daed-linux-x86_64" "$temp_pkg_dir/usr/bin/daed"
		chmod 0755 "$temp_pkg_dir/usr/bin/daed"
		mkdir -p "$temp_pkg_dir/etc/init.d"
		cp -fp "$pkg_dir/files/daed.init" "$temp_pkg_dir/etc/init.d/daed"
		chmod 0755 "$temp_pkg_dir/etc/init.d/daed"
		mkdir -p "$temp_pkg_dir/etc/config"
		cp -fp "$pkg_dir/files/daed.config" "$temp_pkg_dir/etc/config/daed"
		chmod 0644 "$temp_pkg_dir/etc/config/daed"
		mkdir -p "$temp_pkg_dir/etc/daed"  # 目录占位；wing.db / geo 数据运行时建
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
		find "$temp_pkg_dir" -type f,l -printf '/%P\n' | sort > "$temp_dir/$pkg_name.list"
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
				csum="$(sha256sum "$temp_pkg_dir/$file" | awk '{print $1}')"
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
			--info "arch:$pkg_arch" \
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

		# 复用 homeproxy 的 postinst-pkg：装 luci 应用后清缓存 + 跑 /etc/uci-defaults/luci-<app>
		cat > "$temp_pkg_dir/CONTROL/postinst-pkg" <<-EOF
			[ -n "\${IPKG_INSTROOT}" ] || {
				[ -f /etc/uci-defaults/luci-$app_id ] && . /etc/uci-defaults/luci-$app_id && rm -f /etc/uci-defaults/luci-$app_id
				rm -f /tmp/luci-indexcache
				rm -rf /tmp/luci-modulecache/
				exit 0
			}
		EOF
		chmod 0755 "$temp_pkg_dir/CONTROL/postinst-pkg"

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

	local temp_dir="$(mktemp -d -p "$BASE_DIR")"
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
		find "$i18n_dir" -type f,l -printf '/%P\n' | sort > "$temp_dir/$i18n_name.list"
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
