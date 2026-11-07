# szwjp/luci-app-daed

> LuCI for daed on OpenWrt / ImmortalWrt. 二进制由 [szwjp/daed](https://github.com/szwjp/daed) 自动构建并上传 Release，
> 本包只做 LuCI 面板 + UCI 集成 + 启动脚本，**不交叉编译**。
>
> 上游现状：daed / dae-wing 仓库已 archived，仍在演进的是 dae 内核；
> 本仓跟随 szwjp/daed 的 fork 构建（dae 内核 + fork 的前端，含自定义 UI）。

| 项 | 取值 |
|---|---|
| 二进制来源 | <https://github.com/szwjp/daed/releases>，tag `v<上游版本>-nightly-<YYYYMMDD>-<fork sha7>-<dae sha7>`（不可变，例 `v2.1.1-nightly-20261017-58fc2f0-a1b2c3d`） |
| 自动同步 | 每 2 小时轮询一次；有新 release 则同步并自动 dispatch 打包，失败由下一轮自动重试 |
| 目标设备 | x86_64（ImmortalWrt，其他架构待加） |
| LuCI 源码 | 复用 [QiuSimons/luci-app-daed](https://github.com/QiuSimons/luci-app-daed) `kix` 分支 |
| 与 QiuSimons 差异 | 二进制从 release 拉而非 SDK 编译；不依赖 vmlinux-btf/5 个 patchset |

## 快速装机

### 方式 1：直接用 Release 里的包（推荐，无需编译）

每次构建都会发布 6 个资产（两种包格式 × 两个包 + 中文语言包）。以当前 release 为例
（tag `v2026.10.16-r01`）：

| 资产 | 用途 |
|---|---|
| `daed-2026.10.16-r1.apk` / `.ipk` | daed 二进制（含 procd init、UCI 模板） |
| `luci-app-daed-2026.10.16-r1.apk` / `.ipk` | LuCI 面板（Lua CBI：设置/仪表板/日志） |
| `luci-i18n-daed-zh-cn-2026.10.16-r1.apk` / `.ipk` | 中文翻译 |

> 版本命名：release tag 用 luci 包的版本 `v<PKG_VERSION>-r<两位 PKG_RELEASE>`（`r1` → `r01`）；
> 资产文件名里的 `-rN` 是**各自包**的 `PKG_RELEASE`。daed 包的 `PKG_RELEASE` 是「同一天第几个
> daed release」，同一天上游发多次时可能比 tag 里的 rNN 大（例如 tag `v2026.10.17-r02` 下
> 的资产可能是 `daed-2026.10.17-r2.apk`）。

**先确认设备用的是哪个包管理器**（OpenWrt 25.12+ 已换成 apk）：

```bash
# 设备上
which apk opkg          # 25.12+ 只有 apk；24.10 及更早是 opkg
cat /etc/os-release | head -3
```

apk 设备（如本项目的 ImmortalWrt 25.12.2 / apk-tools 3.0.5）：

```bash
TAG=v2026.10.16-r01   # 换成最新 tag（形如 v<日期>-rNN，NN 两位等宽）
for f in daed-2026.10.16-r1.apk luci-app-daed-2026.10.16-r1.apk luci-i18n-daed-zh-cn-2026.10.16-r1.apk; do
  curl -fsSLO "https://github.com/szwjp/luci-app-daed/releases/download/$TAG/$f"
done
scp *.apk root@192.168.1.1:/tmp/

ssh root@192.168.1.1
# 本仓的包没有签名，本地文件安装需要 --allow-untrusted
apk add --allow-untrusted /tmp/daed-*.apk /tmp/luci-app-daed-*.apk /tmp/luci-i18n-daed-*.apk

uci set daed.config.enabled='1'; uci commit daed
/etc/init.d/daed enable
/etc/init.d/daed restart
# 浏览器：http://192.168.1.1/cgi-bin/luci/admin/services/daed
# Header 预期显示「内核 vX.X.X」（szwjp/daed 的 coreVersion 定制；未在真机确认）
```

opkg 设备（24.10 及更早）：

```bash
scp *.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 'opkg install /tmp/daed-*.ipk /tmp/luci-app-daed-*.ipk /tmp/luci-i18n-daed-zh-cn-*.ipk'
```

> 升级时 `/etc/config/daed` 与 `/etc/init.d/daed` 是 conffile（改过会提示保留）；
> `wing.db` / `geo-update.env` / `geo*.dat` / `/var/log/daed/daed.log` 不在包内，
> 包管理器不会碰，业务数据天然保留。

### 方式 2：编进自己的固件（OpenWrt SDK）

```bash
git clone https://github.com/szwjp/luci-app-daed package/dae
./scripts/feeds update -i daed && ./scripts/feeds install -a
make menuconfig   # Network → Web Servers/Proxies → luci-app-daed / daed
make package/dae/luci-app-daed/compile V=s
make package/dae/daed/compile V=s
```

本仓带 GitHub Actions，也可以手动推 `v*` tag 触发构建发版（见 `.github/workflows/build.yml`）。
tag 必须与 `luci-app-daed/Makefile` 的 `v<PKG_VERSION>-r<PKG_RELEASE>`（`rN` 规范化为两位）
一致（按规范化后的值比较），否则 build 会拒绝发布。

## 升级

链路是自动的（无需人工触发）：

```
szwjp/daed push（或每日 check-upstream）
  → build-custom.yml 完整构建 + 发不可变 release
       tag = v<上游版本>-nightly-<YYYYMMDD>-<fork sha7>-<dae sha7>，例 v2.1.1-nightly-20261017-58fc2f0-a1b2c3d
       （tag 不可变；dae-core pin 只在该 release 构建成功后才推进，
        所以本仓拿到的 release 一定是能编译的产物）
  → 本仓 release-sync.yml（每 2 小时）跑 scripts/release-sync.sh：
       · 按 published_at 取最新 release（过滤 draft/prerelease；不信任 API 顺序）
       · 更新 daed/Makefile：PKG_VERSION / PKG_RELEASE（同日期第几个 release）/
         DAED_RELEASE_TAG / PKG_HASH / DAECORE_PIN
       · 更新 luci-app-daed 的 PKG_VERSION / PKG_RELEASE → 本仓 release tag v<日期>-rNN
  → 若该 release tag 还不存在，release-sync 自动 dispatch build.yml 打包并发 release
  → 构建连续失败 3 次后熔断：暂停自动 dispatch，修复后手动 dispatch/push 一次即恢复
  保活：HEAD 超过 25 天无提交时自动提交 `.github/keepalive`（防止 60 天无活动被禁用 schedule）
  自检：每轮检查对端 szwjp/daed 的 check-upstream 是否 active 且 30h 内有 schedule 运行，异常开 issue
       · build 失败 → 开 issue 记录 run 链接，2 小时后下一轮自动重试（不用手动重跑）
       · build 成功 → release 已存在，下一轮幂等跳过
  → 设备 apk add / opkg install 新包
```

设备侧升级只要两步：

```bash
# apk 设备
apk add --allow-untrusted /tmp/新下载的包.apk
/etc/init.d/daed restart
```

## 仓库结构

```
luci-app-daed/
├── luci-app-daed/            LuCI 应用包（lua/po/root/Makefile）
│   ├── luasrc/               controller + CBI 模型 + view 模板
│   ├── po/zh_Hans/           中文翻译
│   └── root/usr/share/rpcd/  仅 ACL（没有 init / hotplug）
├── daed/                     daed 二进制包（Makefile + files/）
│   └── files/                daed.init / daed.config / 98-daed(hotplug)
├── scripts/release-sync.sh   同步工具（CI 每 2 小时跑，也可手动跑）
├── tests/i18n_coverage.py    i18n 门禁（.lua + .htm vs zh_Hans po）
└── .github/
    ├── build-pkg.sh          组 apk/ipk 的打包脚本
    └── workflows/            arch-test / build / release-sync
```

`luci-app-daed/luasrc/` 与 `luci-app-daed/po/` 直接复用 QiuSimons 仓 `kix` 分支的对应目录。

**包职责边界**（2026-11 审查后调整）：

- `luci-app-daed` 只装只读的 LuCI 产物：controller / CBI / view / ACL。
- `daed` 负责一切守护进程行为：procd init（含 `DAE_LOCATION_ASSET` 与可选的
  resolv.conf 接管）、UCI 默认段、WAN 重连时的 hotplug 重启。
- 这样卸载"界面包"不会连带改变 daemon 行为，反之只装 `daed` 也有完整运行逻辑。

## 与 QiuSimons 版的取舍

| 维度 | QiuSimons | szwjp（本仓） |
|---|---|---|
| daed 编译 | OpenWrt SDK 全量编译（daed + dae-wing + dae） | 不编译，从 szwjp/daed release 拉预编译二进制 |
| 多 SDK/多架构 | 是（aarch64/x86_64/i386/mips/mipsle） | 否，目前只 x86_64 |
| patchset (5 个 DNS/eBPF 补丁 + vmlinux-btf) | 必装 | 不需要；BTF 走运行时选项（init 阶段选择） |
| 升级 daed 上游 | autoupdate.yml 每 2 小时改 PKG_SOURCE_VERSION | szwjp/daed 自动 bump dae-core pin + wing + daed，发布新 release；本仓每 2 小时探测 |
| 安装时间 | 2-4 小时交叉编译 | 几分钟打包 ipk |
| 内核保鲜 | 2h 内 | ≤2h（同步轮询周期） |

## 不在这次范围

- 跨架构（aarch64/mips…）——设备全 x86_64，加设备再加 package
- patchset 移植——你这台 ImmortalWrt 已用 kernel BTF
- aarch64 btf / 内核 5.10 适配——上游 dae 已支持，但本仓暂未做回归

## 验证清单

静态与产物层面（2026-11-07 复核）：

- [x] 仓库结构：2 个 OpenWrt 包 + LuCI lua/po/root + 3 个 workflow + 构建脚本
- [x] `daed/Makefile` 路径 A：`Build/Prepare` 解包 + `Build/Compile` no-op
- [x] `build-pkg.sh` 本地打 apk 成功（`apk-tools 3.0.7 mkpkg`，ADBd 容器，`adbdump` 可解析）
- [x] `luci-app-daed` 产物不再包含 `/etc/config/daed`、`/etc/init.d`、`/etc/hotplug.d`；
      也不再生成空的 `lib/upgrade/keep.d`
- [x] `daed` 产物包含 `usr/bin/daed`、`etc/init.d/daed`、`etc/config/daed`、
      `etc/hotplug.d/iface/98-daed` 与 conffiles/conffiles_static
- [x] i18n 门禁覆盖 `.lua` 与 `.htm`：22/22 = 100%，无未使用条目
- [x] `bash -n`（build-pkg.sh / release-sync.sh / daed.init / 98-daed）、
      YAML 解析、`py_compile` 全部通过
- [x] Lua 语法（luaparser）：controller + 两个 CBI 模型全部通过

实机验证（192.168.1.139，ImmortalWrt 25.12.2 x86_64 / apk-tools 3.0.5）：

- [x] 全新安装两个包成功，daed 正常启动（`ubus call service list` 可见
      `env.DAE_LOCATION_ASSET=/usr/share/v2ray`，无 sed 改写 init）
- [x] `/etc/init.d/daed` 的 sha256 与 `conffiles_static` 一致；升级后不产生
      `init.d/daed.apk-new`（仅用户改过的 `/etc/config/daed` 产生 `.apk-new`，符合预期）
- [x] 升级 daed 包（r1 → r2）后 pid 变化：postinst 自动重启生效，无需手工 restart；
      日志保留（不再被 stop 删除）
- [x] `hijack_resolv=1` 时 bind mount 生效、`=0` 与 stop 时正确卸载并清理临时文件；
      不再使用硬编码 DNS 兜底
- [x] LuCI 页面 200；`get_log` 返回 `text/plain; charset=utf-8` + nosniff
- [x] `clear_log`：GET → 405；POST 无 token → 403；错误 token → 403；
      正确 token → 200 且日志清零
- [x] 卸载 `luci-app-daed` 后 `daed`、`/etc/init.d/daed`、hotplug、进程均保留
- [x] 卸载 `daed` 后零残留（文件 / rc.d / `/lib/apk/packages` / keep.d / 进程 / ubus）

未覆盖：

- [ ] `po2lmo` 产物：本机无 Lua，未本地构建 i18n 子包；由 CI 构建（po 已通过解析校验）
- [ ] 从旧版本（含 `/etc/init.d/luci_daed`）升级的迁移路径未实机复现
- [ ] 自动链路整轮（daed 新 release → release-sync → dispatch build → 发 release）
- [ ] 真实 CI 上的 arch-test / build 全绿

### 版本策略：两个包都用 daed release 的日期

设备上官方包用的是 `<年>.<构建号>.<修订>` 形式（`daed 1.27.0-r1`、
`luci-app-daed 26.236.50544~cb5d434`），而 apk 按数值段比较版本：

```
apk version -t 2.1.1-r1      26.236.50544~cb5d434  →  <   会被判降级 + feed 覆盖
apk version -t 2026.10.16-r1 26.236.50544~cb5d434  →  >   正常升级
apk version -t 2026.10.16-r1 1.27.0-r1             →  >   正常升级
```

所以本仓两个包的 `PKG_VERSION` 都用 **daed release 的日期**（`2026.10.16`）：

- 首段 ≥ 26，稳压官方 luci-app-daed，`apk upgrade` 不会把我们的包换回去
- 与 daed 二进制包的版本一致，一眼能对上「这个包对应哪天的二进制」
- daed 上游版本号（2.1.1）单独记录在 `daed/Makefile` 的 `DAED_UPSTREAM_VERSION`

`arch-test` 里有一条门禁：两个包的 `PKG_VERSION` 必须是 `YYYY.MM.DD` 且日期一致，
防止有人改回 `1.4` / `2.1.1` 这类小于 26.x 的值。

## 设备布局（szwjp/daed 与本仓都对齐到这里）

目标设备：192.168.1.1，ImmortalWrt 25.12.2 x86_64，包管理器为 **apk** 不是 opkg。
下表是包的安装布局与包管理器的预期行为（本轮未登录真机复核）：

| 路径 | 实际归属 | 包管理器升级时会动吗 |
|---|---|---|
| `/usr/bin/daed` | 59.6MB 二进制 | 会（换新版） |
| `/etc/init.d/daed` | procd init（含 env、可选 resolv 接管） | 是 conffile，改过则保留 |
| `/etc/hotplug.d/iface/98-daed` | WAN up/update 时重启 daed | 会（随 daed 包更新） |
| `/etc/config/daed` | UCI 段 | 是 conffile，改过则保留 |
| `/etc/daed/wing.db` | 业务数据 | 不碰 |
| `/etc/daed/geo-update.env` | jwt secret | 不碰 |
| `/etc/daed/geoip.dat` | 路由表 | 不碰（用户自跑 geo-update） |
| `/etc/daed/geosite.dat` | 域名表 | 不碰（用户自跑 geo-update） |
| `/var/log/daed/daed.log` | 日志 | 不碰 |

参考：官方 daed 包还包含 `etc/config/daed`、`etc/init.d/daed`，并依赖
`ca-bundle / kmod-sched-core / kmod-sched-bpf / kmod-veth / kmod-xdp-sockets-diag / libc`；
geo 数据由独立的 `daed-geoip`、`daed-geosite` 两个包提供。
本仓的 daed 包依赖已与官方对齐（含 `kmod-xdp-sockets-diag`）。

## 从旧版本升级（2026-11 行为变更）

- `/etc/init.d/luci_daed` 已删除：DNS 接管与 hotplug 重启并入 `daed` 包。
  升级后 apk 会移除该脚本；若 `/etc/rc.d/S98luci_daed` 残留，可手工 `rm`（只是悬空链接）。
- **升级后 daed 会自动重启**（`Package/daed/postinst`），不需要再手工
  `/etc/init.d/daed restart`。
- 以前 `luci_daed` 会 `sed` 改写 `/etc/init.d/daed` 来注入 `DAE_LOCATION_ASSET`，
  这会污染 conffile 的出厂 hash。现在环境变量直接写在 init 里；曾经被改过的设备
  需要 `rm -f /etc/init.d/daed.apk-new` 或者 `apk fix daed` 恢复跟踪。
- `/tmp/resolv.conf` 接管改为可选（`uci set daed.config.hijack_resolv=1`），默认关闭。
  旧版本无条件接管，升级后如发现 daed 解析异常，请检查该选项。

## License

AGPL-3.0-only（daed 二进制部分）+ MIT（LuCI 部分，见 `LICENSE`）。
