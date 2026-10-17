#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
#
# i18n 覆盖率检查：LuCI lua 源码 vs zh_Hans 翻译。
#
# 为什么不用 po/daed.pot：本仓没有 pot 文件，也没有生成 pot 的步骤。
# 旧实现发现模板不存在就直接 exit 0 —— 门禁完全空转（审查 P1-1）。
# 现在以「源码里实际出现的 msgid」为准：
#   1) 扫 luci-app-daed/luasrc/**/*.lua 里的 translate("...") / _("...")
#   2) 与 luci-app-daed/po/zh_Hans/daed.po 的 msgid→msgstr 比对
#   3) 源码有、po 缺失或 msgstr 为空 → 覆盖率不足，按 --fail-below 退出非 0
#   4) po 里有、源码没用到的条目 → 只 warning（历史遗留条目不算错误）
#
# 用法（在仓库任意目录跑都可以，路径默认按本文件位置解析）：
#   python3 tests/i18n_coverage.py                  # 默认 fail-below=100
#   python3 tests/i18n_coverage.py --warn-below 80  # publish 阶段只警告不 fail
#
# 注意：view 模板（.htm）里的 <%:...%> 不在本检查范围内（工具只覆盖 lua 源码）。

import argparse
import glob
import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SRC_DIR = os.path.join(REPO_ROOT, "luci-app-daed", "luasrc")
DEFAULT_PO = os.path.join(REPO_ROOT, "luci-app-daed", "po", "zh_Hans", "daed.po")

# translate("...") 与 LuCI 的 _("...") 是同一个 i18n 入口，两种都算源码 msgid。
# 只认双引号字符串（本仓 lua 源码统一用双引号），允许 \\" 转义。
_MSGID_RE = re.compile(r'(?<![A-Za-z0-9_])(?:translate|_)\s*\(\s*"((?:[^"\\]|\\.)*)"')


def _unescape_lua(s):
    return s.replace('\\"', '"').replace("\\\\", "\\")


def scan_source(src_dir):
    """返回 {msgid: [出现该 msgid 的文件, ...]}。"""
    files = sorted(glob.glob(os.path.join(src_dir, "**", "*.lua"), recursive=True))
    found = {}
    for path in files:
        with open(path, encoding="utf-8") as f:
            text = f.read()
        for m in _MSGID_RE.finditer(text):
            msgid = _unescape_lua(m.group(1))
            found.setdefault(msgid, []).append(os.path.relpath(path, REPO_ROOT))
    return found


def _unquote(s):
    s = s.strip()
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        return s[1:-1]
    return s


def _field(block, field):
    """从 po 条目块里拼出某个字段（含多行续行）的值。"""
    out = []
    active = False
    prefix = field + " "
    for line in block:
        s = line.strip()
        if s.startswith(prefix):
            active = True
            out.append(_unquote(s[len(field):]))
        elif active and s.startswith('"'):
            out.append(_unquote(s))
        elif active:
            break
    return "".join(out)


def parse_po(path):
    """返回 {msgid: msgstr}；文件不存在返回 None。空 msgid 的 header 不计入。"""
    if not os.path.isfile(path):
        return None
    entries = {}
    block = []

    def flush():
        if not block:
            return
        msgid = _field(block, "msgid")
        msgstr = _field(block, "msgstr")
        if msgid:
            entries[msgid] = msgstr

    with open(path, encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if s == "":
                flush()
                block = []
                continue
            if s.startswith("#"):  # 注释 / 已废弃条目（#~ msgid）
                continue
            block.append(line)
    flush()
    return entries


def _short(p):
    p = os.path.abspath(p)
    try:
        rel = os.path.relpath(p, REPO_ROOT)
    except ValueError:
        return p
    return p if rel.startswith("..") else rel


def main():
    p = argparse.ArgumentParser(description="LuCI lua 源码 vs zh_Hans po 的 i18n 覆盖率")
    p.add_argument("--fail-below", type=int, default=100,
                   help="覆盖率低于此值则 exit 1（默认 100）")
    p.add_argument("--warn-below", type=int, default=None,
                   help="覆盖率低于此值则只打 warning（用于 publish 阶段）")
    p.add_argument("--src-dir", default=DEFAULT_SRC_DIR,
                   help="要扫描的 luasrc 目录（默认 luci-app-daed/luasrc）")
    p.add_argument("--po", default=DEFAULT_PO,
                   help="目标语言 po 文件（默认 luci-app-daed/po/zh_Hans/daed.po）")
    args = p.parse_args()

    src = scan_source(args.src_dir)
    if not src:
        # 扫不到任何 msgid 不能按 100% 放行，否则又退化成空转门禁
        print(f"::error::{_short(args.src_dir)} 里没扫描到任何 translate()/_() 的 msgid")
        return 1

    po = parse_po(args.po)
    if po is None:
        print(f"::error::找不到 po 文件 {_short(args.po)}")
        return 1

    missing = sorted(m for m in src if not po.get(m))
    total = len(src)
    translated = total - len(missing)
    pct = translated * 100.0 / total

    print(f"源码 msgid: {total} 条（{_short(args.src_dir)}/**/*.lua）")
    print(f"po 条目:    {len(po)} 条（{_short(args.po)}）")
    print(f"i18n 覆盖率: {translated}/{total} = {pct:.1f}%")
    if missing:
        for m in missing[:10]:
            print(f"  缺失 msgid: {m[:100]}（{src[m][0]}）")
        if len(missing) > 10:
            print(f"  ...另有 {len(missing) - 10} 条")

    # po 里比源码多出来的条目：只提示，不算失败（历史遗留条目保留无害）
    extra = sorted(set(po) - set(src))
    if extra:
        print(f"::warning::po 有 {len(extra)} 条源码未使用的条目（只提示、不算失败）："
              + "；".join(x[:60] for x in extra[:5])
              + ("…" if len(extra) > 5 else ""))

    if args.warn_below is not None and pct < args.warn_below:
        print(f"::warning::i18n 覆盖率 {pct:.1f}% < 警告阈值 {args.warn_below}%")
        return 0
    if pct < args.fail_below:
        print(f"::error::i18n 覆盖率 {pct:.1f}% < 失败阈值 {args.fail_below}%")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
