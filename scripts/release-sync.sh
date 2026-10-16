#!/usr/bin/env bash
# 同步 szwjp/daed 最新 nightly release 到本仓库的 Makefile。
#
# 用法：scripts/release-sync.sh
#  1. 调 GitHub API 查 szwjp/daed 最新 v2.1.1-nightly-* release
#  2. 拿 release 资产 daed-linux-x86_64.tar.gz 的 sha256
#  3. 改 daed/Makefile 的 PKG_VERSION、PKG_HASH
#  4. git commit + 提示你 push
#
# 集成到上游 OpenWrt build 流程时，把这步放进你自己的 CI 即可。

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

TAG="$(gh api repos/szwjp/daed/releases --jq "[.[] | select(.tag_name | startswith(\"v2.1.1-nightly-\"))][0].tag_name")"
if [ -z "$TAG" ] || [ "$TAG" = "null" ]; then
  echo "::error::szwjp/daed 找不到 v2.1.1-nightly-* release"
  exit 1
fi
echo "Latest release: $TAG"

# 从 tag 解析日期版本（v2.1.1-nightly-20261016 -> 2.1.1）
VERSION="${TAG#v}"; VERSION="${VERSION%%-nightly-*}"
echo "PKG_VERSION=$VERSION"

ASSET_URL="https://github.com/szwjp/daed/releases/download/$TAG/daed-linux-x86_64.tar.gz"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
echo "Downloading to compute sha256..."
curl -sSL --fail -o "$TMP" "$ASSET_URL" || { echo "::error::下载 $ASSET_URL 失败"; exit 1; }
HASH="$(sha256sum "$TMP" | awk '{print $1}')"
SIZE="$(stat -c%s "$TMP" 2>/dev/null || stat -f%z "$TMP")"
echo "PKG_HASH=$HASH  size=$SIZE"

# 改 daed/Makefile：PKG_VERSION 与 PKG_HASH
DAED_MF="daed/Makefile"
if [ "$(uname)" = "Darwin" ]; then SED_INPLACE=(-i ''); else SED_INPLACE=(-i); fi

sed "${SED_INPLACE[@]}" -E "s|^[[:space:]]*PKG_VERSION:=[^[:space:]]+|PKG_VERSION:=$VERSION|" "$DAED_MF"
sed "${SED_INPLACE[@]}" -E "s|^[[:space:]]*PKG_HASH:=[^[:space:]]+|PKG_HASH:=$HASH|" "$DAED_MF"

echo
echo "daed/Makefile 改动（diff）："
git --no-pager diff "$DAED_MF"

# luci 包版本：每次 daed 升级同步 +1（避免 opkg 装不上老 ipk）
LUCI_MF="luci-app-daed/Makefile"
LUCI_REL="$(sed -nE 's/^[[:space:]]*PKG_RELEASE:=([0-9]+).*/\1/p' "$LUCI_MF" | head -1)"
LUCI_REL_NEW=$((LUCI_REL + 1))
sed "${SED_INPLACE[@]}" -E "s|^([[:space:]]*PKG_RELEASE:=)[0-9]+|\1$LUCI_REL_NEW|" "$LUCI_MF"

echo
echo "luci-app-daed/Makefile 改动（diff）："
git --no-pager diff "$LUCI_MF"

echo
git add "$DAED_MF" "$LUCI_MF"
git -c user.name=szwjp -c user.email=szwjp@users.noreply.github.com commit -q -m "release(sync): bump to $TAG (hash ${HASH:0:8})"
git --no-pager log -1 --oneline
echo
echo "已 commit，未 push。检查后："
echo "  git push origin main"
