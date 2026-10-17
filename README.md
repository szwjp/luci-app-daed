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
├── luci-app-daed/           LuCI 应用包（lua/po/root/Makefile）
├── daed/                    daed 二进制包（Makefile + files/）
├── scripts/release-sync.sh  同步工具（CI 每 2 小时跑，也可手动跑）
├── tests/i18n_coverage.py   i18n 门禁（luasrc 源码 vs zh_Hans po）
└── .github/
    ├── build-pkg.sh         组 apk/ipk 的打包脚本
    └── workflows/           arch-test / build / release-sync
```

`luci-app-daed/luasrc/` 与 `luci-app-daed/po/` 直接复用 QiuSimons 仓 `kix` 分支的对应目录。
`daed/files/` 里的 `daed.init` 是 procd init，`daed.config` 是 UCI 默认段。

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

代码/产物层面（已核实）：

- [x] 仓库结构完整（2 个 OpenWrt 包 + LuCI lua/po/root + 3 个 workflow + 构建脚本）
- [x] LuCI lua 源（controller/cbi/view/po）与 QiuSimons `kix` 分支一致
- [x] `daed/Makefile` 路径 A 形态：`Build/Prepare` 解包 + `Build/Compile` no-op
- [x] szwjp/daed 的 `release` job 跑通并产出 release（最后一条是旧格式
      `v2.1.1-nightly-20261016`；新格式 `v<上游版本>-nightly-YYYYMMDD-<fork sha7>-<dae sha7>`
      由 daed 侧改造后启用）
- [x] 本仓 `build.yml` 端到端跑通：一次产出 6 个资产
      （daed apk+ipk、luci-app-daed apk+ipk、i18n apk+ipk）
- [x] 下载真实 ipk 校验内容：LuCI 文件落在 `/usr/lib/lua/luci/...`、
      daed 二进制 59,613,346 bytes（ELF x86-64）
- [x] i18n 门禁改为「luasrc 源码 vs po」实比对（`--fail-below 100` 可红可绿），
      不再依赖不存在的 `po/daed.pot`；`bash -n build-pkg.sh` 也已真生效
- [x] conffiles 回填逻辑已修正：只有包内确实带 `/etc/config/<app>` 时才声明该 conffile

待验证（未做或本轮未复核）：

- [ ] `luci-app-daed` 的下次构建产物里不再出现 `/etc/config/daed` conffile（产物未重建）
- [ ] 本仓 `arch-test` 在 CI 上全绿：当前 `daed/Makefile` 还是旧格式 tag，要等 daed
      侧发一条新格式 release 并同步一次后才可能绿
- [ ] 自动链路实跑一整轮：daed 发新 release → release-sync 同步 → 自动 dispatch build
      → 发本仓 release（代码已就位，尚未在远端跑过完整周期）
- [ ] 设备（ImmortalWrt 25.12.2 / apk-tools 3.0.5）上 `apk add --simulate` 预演（本轮未复核）
- [ ] 设备上真正 `apk add` 安装
- [ ] 安装后确认 LuCI 菜单与 Header 的「内核 vX」显示

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
| `/etc/init.d/daed` | procd init | 是 conffile，改过则保留 |
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

## License

AGPL-3.0-only（daed 部分）+ MIT（LuCI 部分）。
