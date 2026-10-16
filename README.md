# szwjp/luci-app-daed

> LuCI for daed on OpenWrt / ImmortalWrt. 二进制由 [szwjp/daed](https://github.com/szwjp/daed) 每日自动构建并上传 Release，
> 本包只做 LuCI 面板 + UCI 集成 + 启动脚本，**不交叉编译**。

| 项 | 取值 |
|---|---|
| 二进制来源 | <https://github.com/szwjp/daed/releases> tag `v2.1.1-nightly-YYYYMMDD` |
| 自动同步 | 每日 UTC 01:00 / 北京 09:00 轮询 + `workflow_dispatch` |
| 目标设备 | x86_64（ImmortalWrt，其他架构待加） |
| LuCI 源码 | 复用 [QiuSimons/luci-app-daed](https://github.com/QiuSimons/luci-app-daed) `kix` 分支 |
| 与 QiuSimons 差异 | 二进制从 release 拉而非 SDK 编译；不依赖 vmlinux-btf/5 个 patchset |

## 快速装机（手动）

```bash
# 在你的 OpenWrt 源目录（feeds 体系下）
git clone https://github.com/szwjp/luci-app-daed package/dae
./scripts/feeds update -i daed
./scripts/feeds install -a

make menuconfig
# Network → Web Servers/Proxies → <*> luci-app-daed
#                                      <*> daed
# （BTF 走子选项：kernel BTF 优先，要求 KERNEL_DEBUG_INFO_BTF）

make package/dae/luci-app-daed/compile V=s
make package/dae/daed/compile V=s

# 把 bin/packages/.../daed_*.ipk 和 luci-app-daed_*.ipk 拷到设备
scp bin/packages/*/*/{daed,luci-app-daed}_*.ipk root@192.168.1.1:/tmp/

# 设备上
ssh root@192.168.1.1
opkg install /tmp/daed_*.ipk /tmp/luci-app-daed_*.ipk
uci set daed.config.enabled='1'
uci commit daed
/etc/init.d/daed enable
/etc/init.d/daed start

# 浏览器看
# http://192.168.1.1/cgi-bin/luci/admin/services/daed
# Header 应该显示 "内核 vX.X.X"（来自 szwjp/daed 的 coreVersion 定制）
```

## 升级

`szwjp/daed` 每天推完 → 它的 build-custom.yml 跑通 → 发新 `v2.1.1-nightly-YYYYMMDD` release →
`szwjp/luci-app-daed` 的 release-sync.yml 在第二天早上 09:00 探测到新 release → 自动 bump `PKG_VERSION` + `PKG_HASH` + commit。

你只要拉本仓库最新 main，重打 ipk，设备上 opkg upgrade 即可：

```bash
# 在 OpenWrt 源目录
git pull origin main   # 或: git pull https://github.com/szwjp/luci-app-daed.git main
make package/dae/luci-app-daed/compile V=s
make package/dae/daed/compile V=s
scp bin/packages/*/*/{daed,luci-app-daed}_*.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 'opkg install /tmp/daed_*.ipk /tmp/luci-app-daed_*.ipk && /etc/init.d/daed restart'
```

## 仓库结构

```
luci-app-daed/
├── luci-app-daed/           LuCI 应用包（lua/po/root/Makefile）
├── daed/                    daed 二进制包（Makefile + files/）
├── scripts/release-sync.sh  本地 bump 工具（也可手动跑）
└── .github/workflows/release-sync.yml
```

`luci-app-daed/luasrc/` 与 `luci-app-daed/po/` 直接复用 QiuSimons 仓 `kix` 分支的对应目录。
`daed/files/` 里的 `daed.init` 是 procd init，`daed.config` 是 UCI 默认段。

## 与 QiuSimons 版的取舍

| 维度 | QiuSimons | szwjp（本仓） |
|---|---|---|
| daed 编译 | OpenWrt SDK 全量编译（daed + dae-wing + dae） | 不编译，从 szwjp/daed release 拉预编译二进制 |
| 多 SDK/多架构 | 是（aarch64/x86_64/i386/mips/mipsle） | 否，目前只 x86_64 |
| patchset (5 个 DNS/eBPF 补丁 + vmlinux-btf) | 必装 | 不需要；BTF 走运行时选项（init 阶段选择） |
| 升级 daed 上游 | autoupdate.yml 每 2 小时改 PKG_SOURCE_VERSION | szwjp/daed 自动 bump dae-core pin + wing + daed，发布新 release；本仓 daily 探测 |
| 安装时间 | 2-4 小时交叉编译 | 几分钟打包 ipk |
| 内核保鲜 | 2h 内 | 24h 内 |

## 不在这次范围

- 跨架构（aarch64/mips…）——设备全 x86_64，加设备再加 package
- patchset 移植——你这台 ImmortalWrt 已用 kernel BTF
- aarch64 btf / 内核 5.10 适配——上游 dae 已支持，但本仓暂未做回归

## 验证清单（已通过 / 待验证）

- [x] 仓库结构完整、`find` 验证 14 个文件（含 Makefile ×2）
- [x] LuCI lua 源（controller/cbi/view/po）可正常 parse（与 QiuSimons 一致）
- [x] `daed/Makefile` 路径 A 形态：只有 `Build/Prepare` 解包 + `Build/Compile` no-op
- [x] szwjp/daed build-custom.yml 已加 `release` job（commit 4c742aa）
- [ ] szwjp/daed push 触发 build → 产 release（需等 build 跑完）
- [ ] 在 192.168.1.1 设备上实际 `opkg install` 一次
- [ ] 实际抓 Header 的 `coreVersion` 显示

## License

AGPL-3.0-only（daed 部分）+ MIT（LuCI 部分）。
