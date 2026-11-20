#!/usr/bin/env python3
"""Writes deterministic mixed Chinese/English Markdown test files: 100k, 1m, 10m, 100m.

usage: bench/gen_corpus.py OUT_DIR
"""
import os, random, sys

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
random.seed(7)
zh = "长期价值投资的核心在于理解企业的护城河与资本回报率，市场短期是投票机，长期是称重机。"
en = "Markdown editors should open instantly, render faithfully, and never get in the way of thinking. "

def block(i):
    k = i % 7
    if k == 0: return "## 第 %d 节 Section %d\n" % (i, i)
    if k == 1: return zh * random.randint(2, 6) + "**重点**，*强调*，`code`，[链接](https://example.com/%d).\n" % i
    if k == 2: return "".join("- 列表项 %d：%s\n" % (j, en[:40]) for j in range(4))
    if k == 3: return "```rust\nfn main() {\n    println!(\"hello %d\");\n}\n```\n" % i
    if k == 4: return "| 列 A | 列 B | 列 C |\n|---|---|---|\n| 1 | 二 | three |\n| 4 | 五 | six |\n"
    if k == 5: return "> " + en * 2 + "\n"
    return en * random.randint(2, 5) + "\n"

for name, size in [("100k", 100_000), ("1m", 1_000_000), ("10m", 10_000_000), ("100m", 100_000_000)]:
    parts, n, i = [], 0, 0
    while n < size:
        b = block(i) + "\n"; parts.append(b); n += len(b.encode()); i += 1
    with open(os.path.join(out, name + ".md"), "w") as f:
        f.write("# 测试文档\n\n" + "".join(parts))
