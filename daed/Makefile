# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2026 szwjp <szwjp@users.noreply.github.com>

# 这个包是路径 A 的核心：二进制的源码是 szwjp/daed GitHub Release，
# OpenWrt SDK 几乎不做编译动作，只是把 binary / init / config / geo 数据
# 装进 ipk。daed 自身的三层依赖（dae + dae-wing + 前端）由 szwjp/daed
# 的 Actions 在 GitHub side 跑好，sha 由那侧的 build-custom.yml 断言
# "Assert dae-core pin matches dae main" 守住。
#
# 升级流程：szwjp/daed 推送 → 跑 build-custom.yml 产新 release →
# 修本 Makefile 的 PKG_VERSION 与 PKG_HASH（或者用 scripts/release
# 自动更新）→ 在你的 OpenWrt 源里 opkg upgrade。
#
# 与 QiuSimons/luci-app-daed 的 daed/Makefile 关键差异：
#   - 没有 Build/Prepare 里的 git clone dae + dae-wing + pnpm build
#   - PKG_SOURCE_URL 指向 szwjp/daed release，不是 daeuniverse/daed
#   - 不依赖 vmlinux-btf 与 5 个 DNS/eBPF patchset（运行时由 init 选 BTF 来源）

include $(TOPDIR)/rules.mk

# —— 版本号 ——
# 跟随 szwjp/daed release 的 tag。tag 形如 v2.1.1-nightly-20261016。
# 改这里 + PKG_HASH + luci-app-daed/Makefile 即可发布新包。
PKG_NAME:=daed
PKG_VERSION:=2.1.1
PKG_RELEASE:=1

# 源文件来自 szwjp/daed GitHub Release；asset 名固定，hash 在 release 页面拿。
PKG_SOURCE:=daed-linux-x86_64.tar.gz
PKG_SOURCE_URL:=https://github.com/szwjp/daed/releases/download/v$(PKG_VERSION)-nightly
PKG_HASH:=d107e6b6d5eed6ea5576be5cfb6e6280a444c7876b5c6bb5f2fe48222e2af2b5

PKG_LICENSE:=AGPL-3.0-only MIT
PKG_LICENSE_FILES:=LICENSE
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
  DEPENDS:=+ca-bundle +kmod-sched-core +kmod-sched-bpf \
           +kmod-veth +v2ray-geoip +v2ray-geosite \
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
