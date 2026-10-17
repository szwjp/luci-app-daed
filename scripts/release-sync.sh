#!/usr/bin/env bash
# 同步 szwjp/daed 最新 nightly release 到本仓库的 daed/Makefile。
#
# 幂等：已经是同一个 release 时直接退出 0，不做任何改动（可安全每 2 小时定时跑）。
#
# 用法：scripts/release-sync.sh
#  1. 调 GitHub API 列 szwjp/daed 的 release，按 published_at 取最新一条
#     （过滤 draft/prerelease；tag 必须是 v*-nightly-YYYYMMDD-<fork sha7>-<dae sha7>。
#      不能取 API 返回的第 0 条：GitHub 按 created_at 排序，同一天建多条时
#      created_at 与 published_at 顺序可能不一致，API 顺序不可靠）
#  2. 拿 release 资产 daed-linux-x86_64.tar.gz 的 sha256
#  3. 改 daed/Makefile 的：
#       PKG_VERSION       = YYYY.MM.DD（取自 tag 的日期；opkg 靠它判断升级）
#       PKG_RELEASE       = 同日期 release 的序号（同日多次发布时 opkg/apk 才认升级）
#       DAED_RELEASE_TAG  = 完整 tag（PKG_SOURCE_URL 用它）
#       PKG_HASH          = tarball 的 sha256
#       DAED_UPSTREAM_VERSION / DAECORE_PIN = 参考信息
#  4. 改 luci-app-daed/Makefile 的 PKG_VERSION / PKG_RELEASE
#       （日期变了复位 1；日期没变 +1，保证本仓 release tag 单调递增）
#  5. git commit（不 push）
#
# 环境变量 SKIP_COMMIT=1 时只改文件、不 commit（便于本地 dry-run）。

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

DAED_MF="daed/Makefile"
LUCI_MF="luci-app-daed/Makefile"
[ -f "$DAED_MF" ] || { echo "::error::找不到 $DAED_MF"; exit 1; }
[ -f "$LUCI_MF" ] || { echo "::error::找不到 $LUCI_MF"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "::error::缺少 jq（用于解析 release 列表）"; exit 1; }

# macOS 用 shasum，Linux 用 sha256sum；stat 同样兼容
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}
file_size() {
  if stat -c%s "$1" >/dev/null 2>&1; then stat -c%s "$1"; else stat -f%z "$1"; fi
}
# GNU sed 与 BSD sed 的 -i 参数不同
if [ "$(uname)" = "Darwin" ]; then SED_INPLACE=(-i ''); else SED_INPLACE=(-i); fi
set_mk() { # $1=变量名 $2=新值
  sed "${SED_INPLACE[@]}" -E "s|^([[:space:]]*$1:=).*|\1$2|" "$DAED_MF"
}
get_mk() { sed -nE "s/^[[:space:]]*$1:=(.*)/\1/p" "$DAED_MF" | head -1 | tr -d ' \r'; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# —— 1. 找最新 release ——
# 跨仓契约（szwjp/daed 侧 2026-10-17 起）：release tag 不可变，格式
#   v<上游版本>-nightly-<YYYYMMDD>-<7 位 fork sha>
# 例：v2.1.1-nightly-20261017-58fc2f0-a1b2c3d
# 同一 commit 重跑幂等（tag 已存在则不再发），同一天不同 commit 是不同 tag。
TAG_RE='^v.*-nightly-[0-9]{8}-[0-9a-f]{7}-[0-9a-f]{7}$'
# per_page=100：同一天的 release 一定是列表里最新的若干条，够用。
RELEASES_JSON="$TMP_DIR/releases.json"
if ! gh api 'repos/szwjp/daed/releases?per_page=100' > "$RELEASES_JSON"; then
  echo "::error::拉取 szwjp/daed release 列表失败（gh api）"
  exit 1
fi

TAG="$(jq -r --arg re "$TAG_RE" '
    [ .[]
      | select(.draft != true and .prerelease != true)
      | select(.tag_name | test($re))
    ]
    | sort_by(.published_at)
    | last
    | .tag_name // empty
  ' "$RELEASES_JSON")"
if [ -z "$TAG" ] || [ "$TAG" = "null" ]; then
  echo "::error::szwjp/daed 找不到 v*-nightly-YYYYMMDD-<fork sha7>-<dae sha7> 形式的正式 release"
  exit 1
fi
TAG_PUBLISHED="$(jq -r --arg t "$TAG" '[.[] | select(.tag_name == $t)][0].published_at // "?"' "$RELEASES_JSON")"
echo "最新 release: $TAG（published_at $TAG_PUBLISHED）"

# tag → 日期版本：v2.1.1-nightly-20261017-58fc2f0-a1b2c3d → 2026.10.17
if [[ ! "$TAG" =~ -nightly-([0-9]{8})-[0-9a-f]{7}-[0-9a-f]{7}$ ]]; then
  echo "::error::tag $TAG 不符合 v*-nightly-YYYYMMDD-<fork sha7>-<dae sha7>"
  exit 1
fi
DATEPART="${BASH_REMATCH[1]}"
NEW_VERSION="${DATEPART:0:4}.${DATEPART:4:2}.${DATEPART:6:2}"
# daed 上游版本：v2.1.1-nightly-... → 2.1.1
UPSTREAM_VER="${TAG#v}"; UPSTREAM_VER="${UPSTREAM_VER%%-nightly-*}"

# daed 包的 PKG_RELEASE = 同一天（正式）release 的序号（含当前这条）。
# 同一天 daed 可能发多个 release（不同 commit → 不同 sha7 tag），序号必须递增，
# opkg/apk 才认得出 2026.10.17-r2 比 2026.10.17-r1 新。
# 只统计非 draft/prerelease：与上面选最新 release 的过滤口径一致，否则一个没发布的
# draft 会抢占序号（等它发布时又和已有版本撞号）。daed 侧目前不会产生 draft/prerelease。
DAED_REL="$(jq -r --arg d "-nightly-${DATEPART}-" '
  [ .[]
    | select(.draft != true and .prerelease != true)
    | select(.tag_name | contains($d))
  ] | length
' "$RELEASES_JSON")"
if [[ ! "$DAED_REL" =~ ^[0-9]+$ ]] || [ "$DAED_REL" -lt 1 ]; then
  echo "::notice::统计同日 release 序号失败（得到 '$DAED_REL'），回退为 1"
  DAED_REL=1
fi

CUR_TAG="$(get_mk DAED_RELEASE_TAG)"
if [ "$CUR_TAG" = "$TAG" ]; then
  echo "已经是最新（DAED_RELEASE_TAG=$CUR_TAG），无需改动"
  exit 0
fi
echo "  PKG_VERSION:       $(get_mk PKG_VERSION) -> $NEW_VERSION"
echo "  PKG_RELEASE:       $(get_mk PKG_RELEASE) -> $DAED_REL（同日第 $DAED_REL 个 release）"
echo "  DAED_RELEASE_TAG:  $CUR_TAG -> $TAG"

# —— 2. 算资产 sha256 ——
ASSET_URL="https://github.com/szwjp/daed/releases/download/$TAG/daed-linux-x86_64.tar.gz"
TARBALL="$TMP_DIR/daed-linux-x86_64.tar.gz"
echo "下载以计算 sha256：$ASSET_URL"
curl -sSL --fail -o "$TARBALL" "$ASSET_URL" || { echo "::error::下载失败：$ASSET_URL"; exit 1; }
HASH="$(sha256_of "$TARBALL")"
SIZE="$(file_size "$TARBALL")"
echo "  PKG_HASH=$HASH（$SIZE bytes）"

# —— 3. 写进 daed/Makefile ——
set_mk PKG_VERSION          "$NEW_VERSION"
set_mk PKG_RELEASE          "$DAED_REL"
set_mk DAED_RELEASE_TAG     "$TAG"
set_mk DAED_UPSTREAM_VERSION "$UPSTREAM_VER"
set_mk PKG_HASH             "$HASH"
# dae-core pin 从 release notes 里抓（daed 侧 build-custom 会把 pin 写进 notes）
PIN="$(gh api "repos/szwjp/daed/releases/tags/$TAG" --jq '.body' 2>/dev/null \
       | sed -nE 's/.*dae-core pin: `([0-9a-f]{40})`.*/\1/p' | head -1 || true)"
if [ -n "$PIN" ]; then
  set_mk DAECORE_PIN "$PIN"
  echo "  DAECORE_PIN=$PIN"
else
  echo "  ::notice::release notes 里没找到 dae-core pin，DAECORE_PIN 保持原值"
fi

echo
echo "=== daed/Makefile 关键字段 ==="
for v in PKG_VERSION PKG_RELEASE DAED_RELEASE_TAG PKG_HASH DAED_UPSTREAM_VERSION DAECORE_PIN; do
  printf '  %-22s = %s\n' "$v" "$(get_mk "$v")"
done

# —— 3b. luci-app-daed 的版本 ——
# 本仓 release tag = v<luci PKG_VERSION>-r<luci PKG_RELEASE>。两个包同仓同发，
# 所以 luci 的 PKG_VERSION 跟着 daed 的日期走：
#   - 日期变了 → PKG_VERSION 设成新日期，PKG_RELEASE 复位为 1
#   - 日期没变（同日重发/仅 luci 有改动）→ PKG_RELEASE +1
# 两者都会产生一个「新且更大」的版本，apk/opkg 才认得出要升级。
LUCI_VER="$(sed -nE 's/^[[:space:]]*PKG_VERSION:=(.*)/\1/p' "$LUCI_MF" | head -1 | tr -d ' \r')"
LUCI_REL="$(sed -nE 's/^[[:space:]]*PKG_RELEASE:=([0-9]+).*/\1/p' "$LUCI_MF" | head -1)"
if [ "$LUCI_VER" = "$NEW_VERSION" ]; then
  LUCI_REL_NEW=$(( ${LUCI_REL:-0} + 1 ))
  echo "  luci-app-daed PKG_VERSION 已是 $NEW_VERSION，PKG_RELEASE: ${LUCI_REL:-?} -> $LUCI_REL_NEW"
else
  LUCI_REL_NEW=1
  sed "${SED_INPLACE[@]}" -E "s|^([[:space:]]*PKG_VERSION:=).*|\1$NEW_VERSION|" "$LUCI_MF"
  echo "  luci-app-daed PKG_VERSION: $LUCI_VER -> $NEW_VERSION（PKG_RELEASE 复位为 1）"
fi
sed "${SED_INPLACE[@]}" -E "s|^([[:space:]]*PKG_RELEASE:=)[0-9]+|\1$LUCI_REL_NEW|" "$LUCI_MF"

if [ "${SKIP_COMMIT:-0}" = "1" ]; then
  echo
  echo "SKIP_COMMIT=1，跳过 commit"
  exit 0
fi

# —— 4. commit（不 push）——
echo
if git diff --quiet -- "$DAED_MF" "$LUCI_MF"; then
  echo "文件无变化，不 commit"
  exit 0
fi
git add "$DAED_MF" "$LUCI_MF"
git -c user.name=szwjp -c user.email=szwjp@users.noreply.github.com \
  commit -q -m "release(sync): daed $NEW_VERSION ($TAG, hash ${HASH:0:8})"
git --no-pager log -1 --oneline
echo
echo "已 commit，未 push。检查后： git push origin main"
