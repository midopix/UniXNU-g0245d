#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""发布前自检：确认仓库内无设备序列号、个人绝对路径、示例 chip-id 或大二进制。

本脚本故意不含任何真实敏感值——靠模式匹配，因此可以安全放进公开仓。

退出码 0 = 可发布；非 0 = 有问题（打印清单）。
用法：python3 scripts/linux/check-public-safety.py [root]
"""
import os
import re
import sys

# 形如 S + 12 位数字的设备序列号（本设备真实值已由此模式覆盖）
SERIAL_RE = re.compile(r"\bS[0-9]{12}\b")
# 个人 home 下的绝对路径（/home/<用户名>/ 形式）
HOME_PATH_RE = re.compile(r"/home/[a-z][a-z0-9_-]+/[A-Za-z]")
# 18 位纯数字 chip-id
CHIP_RE = re.compile(r"\b[0-9]{16}\b")
TEXT_EXT = {".sh", ".py", ".md", ".toml", ".txt", ".c", ".h", ".s",
            ".json", ".yaml", ".yml", ".patch", ".service", ".example",
            ".cfg", ".ini"}
SKIP_DIRS = {".git", ".cache", "out", "node_modules", "feeds"}


def check(root):
    issues = []
    for dp, dns, fns in os.walk(root):
        dns[:] = [d for d in dns if d not in SKIP_DIRS]
        for fn in fns:
            p = os.path.join(dp, fn)
            rel = os.path.relpath(p, root)
            ext = os.path.splitext(fn)[1].lower()
            # 1) 大二进制检查（>2MB 且非文本）
            try:
                if os.path.getsize(p) > 2 * 1024 * 1024 and ext not in TEXT_EXT:
                    issues.append((rel, "大二进制文件（固件/Apple 材料不应进仓）"))
            except OSError:
                continue
            if ext not in TEXT_EXT and fn not in {"Makefile", "series", "env.sh"}:
                continue
            try:
                text = open(p, encoding="utf-8", errors="ignore").read()
            except Exception:
                continue
            if SERIAL_RE.search(text):
                issues.append((rel, "疑似设备序列号 S+12位数字"))
            if HOME_PATH_RE.search(text):
                issues.append((rel, "个人绝对路径 /home/<user>/..."))
            # chip-id: 只在本仓示例值形态下报，避免误伤正常数字
            for m in CHIP_RE.finditer(text):
                issues.append((rel, f"16位数字串疑似chip-id: {m.group()[:4]}…"))
    return issues


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    issues = check(root)
    if not issues:
        print("✓ 发布安全检查通过：无序列号 / 个人路径 / chip-id / 大二进制")
        return 0
    print(f"✗ 发现 {len(issues)} 处问题：")
    for p, why in issues[:50]:
        print(f"  - {p}: {why}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
