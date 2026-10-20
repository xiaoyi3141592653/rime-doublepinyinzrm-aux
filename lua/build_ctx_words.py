#!/usr/bin/env python3
"""预编译 context_reorder filter 的词表。

从 double_pinyin_plus.dict.yaml 的 import_tables 链（含 use_preset_vocabulary 引入的
essay.txt）收集 2-8 字词，生成：

  lua/ctx_words.txt  每行 "词\t权重"，按 UTF-8 字节序排序（Lua 端二分查找依赖此序）
  lua/ctx_words.idx  每行 "首字\tlo\thi"，[lo, hi) 为该首字所有行在 txt 中的字节范围（1-based）

词库变更后重新运行: python3 lua/build_ctx_words.py
"""
import io
import os
import re
import sys
import time

RIME_DIR = os.path.expanduser("~/Library/Rime")
SHARED = "/Library/Input Methods/Squirrel.app/Contents/SharedSupport"
ENTRY_DICT = "double_pinyin_plus.dict.yaml"
MIN_LEN, MAX_LEN = 2, 8
OUT_WORDS = os.path.join(RIME_DIR, "lua", "ctx_words.txt")
OUT_IDX = os.path.join(RIME_DIR, "lua", "ctx_words.idx")


def find_dict(name):
    """按 import_tables 中的名字找 .dict.yaml，支持相对路径（cn_dicts/xxx）。"""
    for base in (RIME_DIR, SHARED):
        p = os.path.join(base, name + ".dict.yaml")
        if os.path.exists(p):
            return p
    return None


def parse_entries(path, words):
    """解析词库文件的词条部分，收集 2-8 字词及权重（多库取最大）。"""
    with io.open(path, encoding="utf-8", errors="ignore") as f:
        lines = f.readlines()
    # 有 yaml header（--- ... ）时跳到 '...' 之后；无 header（如 essay.txt）全文件解析
    start = 0
    if lines and lines[0].strip() == "---":
        for i, line in enumerate(lines):
            if line.rstrip("\r\n") == "...":
                start = i + 1
                break
    n = 0
    for line in lines[start:]:
        line = line.rstrip("\r\n")
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        text = parts[0].strip()
        if not text:
            continue
        length = len(text)
        if length < MIN_LEN or length > MAX_LEN:
            continue
        # 权重：末列纯数字则为权重，否则默认 1
        # （base 三列 text/code/weight；tencent 两列 text/weight；xiaoyi 两列 text/code）
        weight = 1
        last = parts[-1].strip() if parts else ""
        if re.fullmatch(r"\d+", last):
            weight = int(last)
        if text in words:
            if weight > words[text]:
                words[text] = weight
        else:
            words[text] = weight
        n += 1
    return n


def parse_dict(path, words, seen):
    """递归解析词库：header 的 import_tables + use_preset_vocabulary(essay.txt) + 本文件词条。"""
    real = os.path.realpath(path)
    if real in seen:
        return
    seen.add(real)

    imports = []
    use_preset = False
    with io.open(path, encoding="utf-8", errors="ignore") as f:
        in_imports = False
        for line in f:
            stripped = line.rstrip("\r\n")
            if stripped == "...":
                break
            if re.match(r"^\s*import_tables:", stripped):
                in_imports = True
                continue
            if in_imports:
                m = re.match(r"^\s*-\s*(\S+)", stripped)
                if m:
                    imports.append(m.group(1))
                    continue
                in_imports = False
            if re.match(r"^\s*use_preset_vocabulary:\s*true", stripped):
                use_preset = True

    for name in imports:
        p = find_dict(name)
        if p:
            parse_dict(p, words, seen)
        else:
            print(f"  [warn] 找不到 import 的词库: {name}")

    if use_preset:
        for cand in (os.path.join(RIME_DIR, "essay.txt"),
                     os.path.join(SHARED, "essay.txt")):
            if os.path.exists(cand):
                parse_entries(cand, words)
                break

    n = parse_entries(path, words)
    print(f"  {os.path.relpath(path, RIME_DIR)}: {n} 条")


def main():
    t0 = time.time()
    words = {}
    entry = os.path.join(RIME_DIR, ENTRY_DICT)
    if not os.path.exists(entry):
        print(f"[error] 找不到入口词库 {entry}")
        sys.exit(1)
    print(f"解析 {ENTRY_DICT} 及其 import 链...")
    parse_dict(entry, words, set())

    items = sorted(words.items())  # code point 序 == UTF-8 字节序
    print(f"去重后 {MIN_LEN}-{MAX_LEN} 字词共 {len(items)} 个")

    os.makedirs(os.path.dirname(OUT_WORDS), exist_ok=True)
    groups = []  # (首字, lo, hi)
    pos = 1  # 1-based 字节偏移
    cur_first, cur_lo, cur_hi = None, None, None
    with io.open(OUT_WORDS, "w", encoding="utf-8", newline="\n") as f:
        for w, wt in items:
            line = f"{w}\t{wt}\n"
            first = w[0]
            if first != cur_first:
                if cur_first is not None:
                    groups.append((cur_first, cur_lo, cur_hi))
                cur_first, cur_lo = first, pos
            f.write(line)
            pos += len(line.encode("utf-8"))
            cur_hi = pos
    if cur_first is not None:
        groups.append((cur_first, cur_lo, cur_hi))

    with io.open(OUT_IDX, "w", encoding="utf-8", newline="\n") as f:
        for first, lo, hi in groups:
            f.write(f"{first}\t{lo}\t{hi}\n")

    t1 = time.time()
    print(f"生成 {os.path.relpath(OUT_WORDS, RIME_DIR)}"
          f" ({os.path.getsize(OUT_WORDS) / 1048576:.1f} MB)")
    print(f"生成 {os.path.relpath(OUT_IDX, RIME_DIR)}"
          f" ({len(groups)} 个首字组)")
    print(f"耗时 {t1 - t0:.1f}s")


if __name__ == "__main__":
    main()
