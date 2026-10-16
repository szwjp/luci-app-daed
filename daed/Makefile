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
PKG_HASH:=skip

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
/etc/daed/wing.db
/etc/config/daed
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

# —— 安装：binary + init + UCI + geo 数据 ——
define Package/daed/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/daed-linux-x86_64 $(1)/usr/bin/daed

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/daed.init $(1)/etc/init.d/daed

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/daed.config $(1)/etc/config/daed

	# Geo 数据：放在 /etc/daed/，与 daed 默认读取路径一致。
	# 用户也可以用自己系统的 geo-update 任务覆盖此处。
	$(INSTALL_DIR) $(1)/etc/daed
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/geoip.dat  $(1)/etc/daed/geoip.dat
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/geosite.dat $(1)/etc/daed/geosite.dat
endef

$(eval $(call BuildPackage,daed))
