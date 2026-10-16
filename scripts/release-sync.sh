#!/usr/bin/env bash
# 同步 szwjp/daed 最新 nightly release 到本仓库的 daed/Makefile。
#
# 幂等：已经是同一个 release 时直接退出 0，不做任何改动（可安全每日定时跑）。
#
# 用法：scripts/release-sync.sh
#  1. 调 GitHub API 查 szwjp/daed 最新 v*-nightly-* release
#  2. 拿 release 资产 daed-linux-x86_64.tar.gz 的 sha256
#  3. 改 daed/Makefile 的：
#       PKG_VERSION       = YYYY.MM.DD（取自 tag 的日期；opkg 靠它判断升级）
#       DAED_RELEASE_TAG  = 完整 tag（PKG_SOURCE_URL 用它）
#       PKG_HASH          = tarball 的 sha256
#       DAED_UPSTREAM_VERSION / DAECORE_PIN = 参考信息
#  4. git commit（不 push）
#
# 环境变量 SKIP_COMMIT=1 时只改文件、不 commit（便于本地 dry-run）。

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

DAED_MF="daed/Makefile"
[ -f "$DAED_MF" ] || { echo "::error::找不到 $DAED_MF"; exit 1; }

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

# —— 1. 找最新 release ——
TAG="$(gh api repos/szwjp/daed/releases?per_page=50 \
        --jq '[.[] | select(.tag_name | test("^v.*-nightly-[0-9]{8}$"))][0].tag_name' 2>/dev/null || true)"
if [ -z "$TAG" ] || [ "$TAG" = "null" ]; then
  echo "::error::szwjp/daed 找不到 v*-nightly-YYYYMMDD 形式的 release"
  exit 1
fi
echo "最新 release: $TAG"

# tag → 日期版本：v2.1.1-nightly-20261016 → 2026.10.16
DATEPART="${TAG##*-nightly-}"            # 20261016
if [[ ! "$DATEPART" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})$ ]]; then
  echo "::error::tag $TAG 里的日期部分 '$DATEPART' 不是 YYYYMMDD"
  exit 1
fi
NEW_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
# daed 上游版本：v2.1.1-nightly-... → 2.1.1
UPSTREAM_VER="${TAG#v}"; UPSTREAM_VER="${UPSTREAM_VER%%-nightly-*}"

CUR_TAG="$(get_mk DAED_RELEASE_TAG)"
if [ "$CUR_TAG" = "$TAG" ]; then
  echo "已经是最新（DAED_RELEASE_TAG=$CUR_TAG），无需改动"
  exit 0
fi
echo "  PKG_VERSION:      $(get_mk PKG_VERSION) -> $NEW_VERSION"
echo "  DAED_RELEASE_TAG: $CUR_TAG -> $TAG"

# —— 2. 算资产 sha256 ——
ASSET_URL="https://github.com/szwjp/daed/releases/download/$TAG/daed-linux-x86_64.tar.gz"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
echo "下载以计算 sha256：$ASSET_URL"
curl -sSL --fail -o "$TMP" "$ASSET_URL" || { echo "::error::下载失败：$ASSET_URL"; exit 1; }
HASH="$(sha256_of "$TMP")"
SIZE="$(file_size "$TMP")"
echo "  PKG_HASH=$HASH（$SIZE bytes）"

# —— 3. 写进 Makefile ——
set_mk PKG_VERSION          "$NEW_VERSION"
set_mk PKG_RELEASE          "1"
set_mk DAED_RELEASE_TAG     "$TAG"
set_mk DAED_UPSTREAM_VERSION "$UPSTREAM_VER"
set_mk PKG_HASH             "$HASH"
# dae-core pin 从 release notes 里抓（build-custom 会把 pin 写进 notes）
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

# —— 3b. luci-app-daed 的 PKG_RELEASE 自增 ——
# 本仓 release tag = v<luci PKG_VERSION>-r<luci PKG_RELEASE>。daed 二进制换新时，
# 若 luci 的 PKG_RELEASE 不动，tag 就不变，新 release 会原地覆盖旧的（内容悄悄变），
# 设备侧也无从判断该不该升级。所以每次同步都 +1，产出一个新的 tag。
LUCI_MF="luci-app-daed/Makefile"
LUCI_REL="$(sed -nE 's/^[[:space:]]*PKG_RELEASE:=([0-9]+).*/\1/p' "$LUCI_MF" | head -1)"
if [ -n "$LUCI_REL" ]; then
  LUCI_REL_NEW=$((LUCI_REL + 1))
  sed "${SED_INPLACE[@]}" -E "s|^([[:space:]]*PKG_RELEASE:=)[0-9]+|\1$LUCI_REL_NEW|" "$LUCI_MF"
  echo "  luci-app-daed PKG_RELEASE: $LUCI_REL -> $LUCI_REL_NEW"
fi

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
