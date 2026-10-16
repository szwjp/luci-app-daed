include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-daed

# 版本策略（与 scripts/release-sync.sh 配合，不要手改）：
#   PKG_VERSION = daed 上游版本号（2.1.1）
#   PKG_RELEASE 每次同步 +1 → 本仓 release tag = v2.1.1-rNN，逐次递增
#
# ⚠️ 已知取舍：设备上（ImmortalWrt 25.12）官方 luci-app-daed 的版本是
# 26.236.50544~cb5d434。apk 按数值比较版本，实测（apk version -t）：
#     2.1.1-r1      vs 26.236.50544~cb5d434  →  <   我们更旧
#     2026.10.16-r1 vs 26.236.50544~cb5d434  →  >   我们更新
# 所以 2.1.1 会被 apk 判成「降级」：本地文件仍可 apk add（输出 Downgrading），
# 但之后任何一次 apk upgrade 都可能被 feed 里的官方包替换回去，我们的 LuCI 页消失。
#
# 想稳压官方包的版本比较，就把 PKG_VERSION 改成日期（如 2026.10.16）；
# 想保留 2.1.1，建议设备上先 `apk del luci-app-daed luci-i18n-daed-zh-cn`，
# 并避免让 feed 覆盖（或者干脆换个包名，例如 luci-app-daed-szwjp）。
PKG_VERSION:=2.1.1
PKG_RELEASE:=2

LUCI_TITLE:=LuCI for daed (szwjp/daed build)
# +daed：daed 二进制包（本仓同仓 daed/ 子包提供，会替换官方 daed 包）
# +zoneinfo-asia：daed 日志时区
# +luci-compat：本 LuCI app 是 Lua CBI 实现，需要 luci-compat
#
# 刻意不依赖 daed-geoip / daed-geosite：那两个官方包提供 /etc/daed/geo*.dat，
# 而本 fork 的部署方式是用设备上自跑的 geo-update 任务维护 geo 数据。
# 设备上若已装这两个包，它们依赖 daed，替换 daed 后依赖依然满足，不会被卸载。
LUCI_DEPENDS:=+daed +zoneinfo-asia +luci-compat
LUCI_PKGARCH:=all

# LuCI 控制器 / CBI 模板 / view 是只读产物，不放 conffiles。
# 用户运行时改的 UCI（daed.config.*）由 daed 包的 conffiles 负责。
define Package/$(PKG_NAME)/conffiles
endef

include $(TOPDIR)/feeds/luci/luci.mk
# call BuildPackage - OpenWrt buildroot signature
