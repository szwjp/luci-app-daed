include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-daed
PKG_VERSION:=2.1.1
PKG_RELEASE:=1

LUCI_TITLE:=LuCI for daed (szwjp/daed build)
# +daed：daed 二进制包（由本仓同仓 daed/ 子包提供，或已装的上游 daed 兼容）
# +zoneinfo-asia：daed 日志需要时区（默认 UTC，给个 Asia/Shanghai）
# +luci-compat：兼容老版 LuCI（ipk 装的 luci-app-* 几乎都依赖它）
LUCI_DEPENDS:=+daed +zoneinfo-asia +luci-compat
LUCI_PKGARCH:=all

# LuCI 控制器/cbi 模板是构建期生成、运行时只读，不算 conffile。
# 用户运行时改的 UCI（daed.config.*）已经在 daed 包 conffiles 里。
define Package/$(PKG_NAME)/conffiles
endef

include $(TOPDIR)/feeds/luci/luci.mk
# call BuildPackage - OpenWrt buildroot signature
