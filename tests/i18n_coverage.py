#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
#
# 极简 i18n 覆盖率检查：
#   po/zh_Hans/daed.po 与 po 模板 (po/daed.pot) 的 msgid 集合对比。
#   100% = zh-Hans 把所有模板里出现的 msgid 全部翻译了。
#   低于阈值时按 --fail-below 退出非 0；按 --warn-below 只打 warning。
#
# 与 homeproxy 的版本思路相同，但它依赖 sing-box 路径；本仓不依赖 sing-box。
#
# 用法：
#   tests/i18n-coverage.py                 默认 fail-below=100
#   tests/i18n-coverage.py --warn-below 80  publish 阶段用，只警告不 fail

import argparse
import os
import re
import sys


def parse_po(path):
    """返回集合 (msgid, ...)。跳过空 msgid（header）。"""
    if not os.path.isfile(path):
        return None
    out = set()
    with open(path, encoding="utf-8") as f:
        cur = []
        in_msgid = False
        for line in f:
            if line.startswith("msgid "):
                cur.append(_strip(line[len("msgid "):]))
                in_msgid = True
            elif line.startswith("msgstr "):
                # 单行 msgid + msgstr 形式
                s = _strip(line[len("msgstr "):])
                msgid = "".join(cur)
                if msgid:
                    out.add(msgid)
                cur = []
                in_msgid = False
            elif in_msgid and line.startswith('"'):
                cur.append(_strip(line))
            elif in_msgid and line.strip() == "":
                # msgid 段结束
                msgid = "".join(cur)
                if msgid:
                    out.add(msgid)
                cur = []
                in_msgid = False
    return out


def _strip(s):
    s = s.rstrip("\n").rstrip()
    if s.startswith('"') and s.endswith('"'):
        s = s[1:-1]
    return s


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--fail-below", type=int, default=100,
                   help="覆盖率低于此值则 exit 1（默认 100）")
    p.add_argument("--warn-below", type=int, default=None,
                   help="覆盖率低于此值则只打 warning（用于 publish 阶段）")
    p.add_argument("--pot", default="po/daed.pot",
                   help="msgid 模板文件（默认 po/daed.pot；不存在则跳过）")
    p.add_argument("--po", default="po/zh_Hans/daed.po",
                   help="目标语言 po 文件")
    args = p.parse_args()

    pot = parse_po(args.pot)
    if pot is None:
        print(f"::notice::{args.pot} 不存在，跳过 i18n 覆盖检查（首次提交无模板属正常）")
        return 0
    po = parse_po(args.po) or set()

    missing = pot - po
    if not pot:
        pct = 100.0
    else:
        pct = (len(pot - missing) * 100.0) / len(pot)

    print(f"i18n 覆盖率: {len(pot)-len(missing)}/{len(pot)} = {pct:.1f}%")
    if missing:
        # 最多列 5 个，避免刷屏
        for m in list(missing)[:5]:
            print(f"  缺失 msgid: {m[:80]}")
        if len(missing) > 5:
            print(f"  ...另有 {len(missing)-5} 条")

    if args.warn_below is not None and pct < args.warn_below:
        print(f"::warning::i18n 覆盖率 {pct:.1f}% < 警告阈值 {args.warn_below}%")
        return 0
    if pct < args.fail_below:
        print(f"::error::i18n 覆盖率 {pct:.1f}% < 失败阈值 {args.fail_below}%")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
