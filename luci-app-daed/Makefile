include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-daed

# 版本策略（与 scripts/release-sync.sh 配合，不要手改）：
#   PKG_VERSION = daed release 的日期（与 daed/Makefile 保持同一日期）
#   PKG_RELEASE = 同一天内重发时递增 → 本仓 release tag = v<日期>-rNN
#
# 为什么用日期而不是 2.1.1（daed 上游版本号）：
# 设备上（ImmortalWrt 25.12）官方 luci-app-daed 是 26.236.50544~cb5d434，
# apk 按数值比较版本，实测（apk version -t）：
#     2.1.1-r1       vs 26.236.50544~cb5d434  →  <   判降级
#     2026.10.16-r1  vs 26.236.50544~cb5d434  →  >   判升级
# 用 2.1.1 的话：本地文件仍能装上（apk 只提示 Downgrading），但之后任何一次
# apk upgrade 都可能被 feed 里的官方包替换回去，本 fork 的 LuCI 页会消失。
# 日期版本首段 ≥ 26，稳压官方包，且与 daed 二进制包的版本一致，便于对照。
#
# daed 上游版本号（2.1.1）记录在 daed/Makefile 的 DAED_UPSTREAM_VERSION。
PKG_VERSION:=2026.11.01
PKG_RELEASE:=4

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

PKG_LICENSE:=MIT
PKG_MAINTAINER:=szwjp <szwjp@users.noreply.github.com>

# 本包只装只读产物：controller / CBI 模型 / view 模板 / ACL。
# 没有任何 conffile（/etc/config/daed 由 daed 包声明），所以不写
# Package/<name>/conffiles；写一个空的 define 反而会让 build-pkg.sh
# 的字面解析器误判（它按 `define Package/<pkg>/conffiles` 精确匹配）。

include $(TOPDIR)/feeds/luci/luci.mk
# call BuildPackage - OpenWrt buildroot signature
