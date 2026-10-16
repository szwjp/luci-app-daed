# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2026 szwjp <szwjp@users.noreply.github.com>

# 这个包是路径 A 的核心：二进制的源码是 szwjp/daed GitHub Release，
# OpenWrt SDK 几乎不做编译动作，只是把 binary / init / config 装进 ipk
# （geo 数据不装，由设备上自跑的 geo-update 任务拉）。
# daed 自身的三层依赖（dae + dae-wing + 前端）由 szwjp/daed 的 Actions
# 在 GitHub side 跑好，sha 由那侧的 build-custom.yml 断言
# "Assert dae-core pin matches dae main" 守住。
#
# 升级流程（全自动，见 .github/workflows/）：
#   szwjp/daed push → build-custom.yml → 发 release（tag v2.1.1-nightly-YYYYMMDD）
#     → 本仓 release-sync.yml 每天 09:00 探测 → scripts/release-sync.sh
#       更新 PKG_VERSION / DAED_RELEASE_TAG / PKG_HASH / DAECORE_PIN
#     → 本仓 build.yml 打包 apk+ipk → 发 release
#     → 设备 opkg upgrade
#
# 本文件里那几个版本字段不要手改：跑 scripts/release-sync.sh 自动同步。
#
# 与 QiuSimons/luci-app-daed 的 daed/Makefile 关键差异：
#   - 没有 Build/Prepare 里的 git clone dae + dae-wing + pnpm build
#   - PKG_SOURCE_URL 指向 szwjp/daed release，不是 daeuniverse/daed
#   - 不依赖 vmlinux-btf 与 5 个 DNS/eBPF patchset（BTF 走运行时）

include $(TOPDIR)/rules.mk

# —— 版本号 ——
# PKG_VERSION 用 szwjp/daed release 的日期（tag 形如 v2.1.1-nightly-20261016）。
# 为什么用日期而不是 2.1.1：opkg 靠版本号判断能否升级，日期每天单调递增，
# 而 2.1.1 永远不变就永远升不上去。QiuSimons 也是这么做的（PKG_VERSION:=2026.08.26）。
#
# 下面这一整块由 scripts/release-sync.sh 自动同步（本地或 GitHub Action 都可跑）。
PKG_NAME:=daed
PKG_VERSION:=2026.10.16
PKG_RELEASE:=1

# szwjp/daed 的完整 release tag —— PKG_SOURCE_URL 用它，不能用 PKG_VERSION 拼，
# 因为 tag 带 daily 后缀（是 v2.1.1-nightly-20261016，不是 v2.1.1-nightly）。
DAED_RELEASE_TAG:=v2.1.1-nightly-20261016
# 参考信息：daed 上游版本 + dae-core pin（便于人工核对这次二进制到底是什么）
DAED_UPSTREAM_VERSION:=2.1.1
DAECORE_PIN:=e3fee8fbc68a65167af13b685ab0b958757e20ee

# 源文件来自 szwjp/daed GitHub Release；asset 名固定，hash 由 release-sync 计算。
# 约定：PKG_SOURCE_URL 是「目录」，PKG_SOURCE 是「文件名」，
# 完整地址 = ${PKG_SOURCE_URL}/${PKG_SOURCE}（OpenWrt 与 build-pkg.sh 都按这个来）。
PKG_SOURCE:=daed-linux-x86_64.tar.gz
PKG_SOURCE_URL:=https://github.com/szwjp/daed/releases/download/$(DAED_RELEASE_TAG)
PKG_HASH:=d107e6b6d5eed6ea5576be5cfb6e6280a444c7876b5c6bb5f2fe48222e2af2b5

PKG_LICENSE:=AGPL-3.0-only MIT
PKG_MAINTAINER:=szwjp <szwjp@users.noreply.github.com>

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)
PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk

# —— 包元信息 ——
define Package/daed/Default
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  URL:=https://github.com/szwjp/daed
endef

define Package/daed
  $(call Package/daed/Default)
  TITLE:=A Modern Dashboard For dae (szwjp/daed build)
  # 依赖对齐 ImmortalWrt 官方 daed 包（设备上 `apk info -a daed` 实测）：
  #   ca-bundle / kmod-sched-core / kmod-sched-bpf / kmod-veth / libc
  #   + kmod-xdp-sockets-diag —— 官方包有这项，本包最初漏了；实测在设备上装
  #     本包会把已装的 kmod-xdp-sockets-diag 当孤儿包 Purging 掉。
  # @KERNEL_XDP_SOCKETS 与 DAED_USE_VMLINUX_BTF:vmlinux-btf 是构建期语法，
  # 只在 OpenWrt 源码构建时有意义；打 ipk/apk 时由 build-pkg.sh 过滤掉。
  DEPENDS:=+ca-bundle +kmod-sched-core +kmod-sched-bpf \
           +kmod-veth +kmod-xdp-sockets-diag \
           +v2ray-geoip +v2ray-geosite \
           +@KERNEL_XDP_SOCKETS \
           +DAED_USE_VMLINUX_BTF:vmlinux-btf
endef

# 运行时选项：BTF 来源。daed 二进制自带 eBPF object（已编好），
# 运行时由 init 选 DAED_USE_KERNEL_BTF / DAED_USE_VMLINUX_BTF。
# 这里没有 SDK 编译阶段，BTF 是 daed 启动时自己选，不进 Makefile 的 DEPENDS。
define Package/daed/config
	choice
		prompt "BTF source for CO-RE"
		default DAED_USE_KERNEL_BTF
		depends on PACKAGE_daed
	config DAED_USE_KERNEL_BTF
		bool "Use kernel BTF (integrated)"
		depends on KERNEL_DEBUG_INFO_BTF
	config DAED_USE_VMLINUX_BTF
		bool "Use vmlinux-btf package"
	endchoice
endef

define Package/daed/description
  daed bundled by szwjp/daed (follows dae/dae-wing main + custom UI).
  Auto-built daily; see https://github.com/szwjp/daed.
  No cross-compile here; binary is pulled from szwjp/daed GitHub Release.
endef

define Package/daed/conffiles
# opkg upgrade 时不擦的：UCI 配置（用户改过 enabled/listen 等）+ init 脚本（procd 行为）
/etc/config/daed
/etc/init.d/daed
endef

# —— 构建：只解包，不编译 ——
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(TAR) -xzf $(DL_DIR)/$(PKG_SOURCE) -C $(PKG_BUILD_DIR)
endef

define Build/Compile
	# 二进制从 tar 直接来；SDK 不重编。
	true
endef

# —— 安装：binary + init + UCI；geo 数据由用户的 geo-update 任务拉 ——
# 路径完全对齐 ImmortalWrt upstream daed 的标准布局，便于维护：
#   /usr/bin/daed                      二进制
#   /etc/init.d/daed                   procd init（conffile）
#   /etc/config/daed                   UCI 段（conffile）
#
# 不在本包中安装：
#   /etc/daed/wing.db                  业务数据（运行时由 daed 创建）
#   /etc/daed/geoip.dat geosite.dat    由用户自跑的 geo-update 任务拉
#   /etc/daed/geo-update.env           jwt secret（由 daed 首次启动生成）
#   /var/log/daed/daed.log             日志（procd 启动时创建）
# 这样 opkg upgrade 不会擦任何运行时数据；用户只需重启 daed 就能换 binary。
define Package/daed/install
	# 1. 二进制
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/daed-linux-x86_64 $(1)/usr/bin/daed

	# 2. procd init。来源：ImmortalWrt 上游 daed 包（2023 Tianling Shen），
	#    与 QiuSimons/luci-app-daed 的 init 在 procd 参数上对齐：含 --logfile、
	#    logfile-maxbackups/maxsize、limits core/nofile、respawn、stderr 1。
	#    **文件由 conffiles 标记**：升级时如果用户没改过 init，会被新版覆盖；
	#    改过则 opkg 提示三路合并。
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/daed.init $(1)/etc/init.d/daed

	# 3. UCI 默认段
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/daed.config $(1)/etc/config/daed

	# 4. /etc/daed 目录占位（无文件）。让 daed 首次启动有处可创建
	#    wing.db、geo-update.env；geo 数据由用户的 update 任务负责。
	$(INSTALL_DIR) $(1)/etc/daed
endef

$(eval $(call BuildPackage,daed))
