#!/usr/bin/env python3
"""只读检查 M2 启动介质是否自洽（P1-01 的重建验收步骤）。

检查的是“手工拼装”最容易留下的四类残骸：
  1. 没有 EFI/BOOT/BOOTAA64.EFI 兜底 —— NVRAM 写失败时机器直接无引导；
  2. extlinux 的 KERNEL/INITRD 指向不存在的文件或空的代目录；
  3. modules.dep 索引了树里不存在的 .ko（介质上曾出现 1010 条死路径）；
  4. *.before-* / *.bak / *.old 这类无入口的手工备份白占 ESP 空间。

用法: python3 dev/m2/media-check.py /Volumes/ORDOPAYLOAD
退出: 0 自洽 | 1 有问题 | 2 无法判定（路径不存在或不是 Ordo 介质）
只读，不挂载、不写盘。
"""
import argparse
import re
from pathlib import Path
import sys

GENERATION = re.compile(r"/ordo-kernel/(ordo-[0-9a-f]{24})/")
BACKUP = re.compile(r"\.(?:before-[^/]*|bak|old)$", re.IGNORECASE)
PATH_DIRECTIVE = re.compile(r"^[ \t]*(?:KERNEL|INITRD|LINUX|FDT)[ \t]+(\S+)", re.MULTILINE)
DEAD_PATH_LIMIT = 5


def check(esp):
    problems = []
    boot_efi = esp / "EFI/BOOT/BOOTAA64.EFI"
    if not boot_efi.is_file() or boot_efi.stat().st_size == 0:
        problems.append("缺少默认引导入口 EFI/BOOT/BOOTAA64.EFI（NVRAM 写失败时无兜底）")

    configs = sorted((esp / "extlinux").glob("*.conf"))
    if not configs:
        problems.append("extlinux/ 下没有任何 .conf")
    referenced = set()
    for config in configs:
        text = config.read_text(errors="replace")
        for relative in PATH_DIRECTIVE.findall(text):
            target = esp / relative.lstrip("/")
            referenced.add(target)
            if not target.is_file() or target.stat().st_size == 0:
                problems.append(f"{config.name} 引用了不存在的 {relative}")
        for generation in GENERATION.findall(text):
            folder = esp / "ordo-kernel" / generation
            for name in ("vmlinuz", "initramfs.img"):
                artifact = folder / name
                if not artifact.is_file() or not artifact.stat().st_size:
                    problems.append(f"{config.name} 指向的 {generation} 缺少 {name}")

    for folder in sorted((esp / "ordo-kernel").glob("ordo-[0-9a-f]" * 3 + "*")):
        if folder.is_dir() and folder.name not in {path.name for path in referenced}:
            generation = GENERATION.pattern  # 只用于占位，避免误报未引用的代目录
            del generation
    for stale in sorted((esp / "ordo-kernel").glob("ordo-*")):
        if stale.is_dir() and not any(stale in path.parents for path in referenced):
            problems.append(f"ordo-kernel/{stale.name} 没有任何 extlinux 入口（无入口的代目录）")

    dead = []
    for index in sorted(esp.rglob("modules.dep")):
        base = index.parent
        for line in index.read_text(errors="replace").splitlines():
            relative = line.split(":", 1)[0].strip()
            if not relative.endswith(".ko"):
                continue
            if not (base / relative).is_file():
                dead.append((index.relative_to(esp).as_posix(), relative))
    if dead:
        shown = ", ".join(f"{index}:{module}" for index, module in dead[:DEAD_PATH_LIMIT])
        problems.append(f"modules.dep 索引了 {len(dead)} 个不存在的模块（{shown}"
                        + ("，…" if len(dead) > DEAD_PATH_LIMIT else "") + "）")

    for path in sorted(esp.rglob("*")):
        if path.is_file() and BACKUP.search(path.name):
            problems.append(f"无入口的手工备份：{path.relative_to(esp).as_posix()}")

    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("esp", type=Path, help="外置启动分区（只读检查）")
    args = parser.parse_args()
    esp = args.esp
    if not esp.is_dir():
        print(f"无法判定：{esp} 不是目录", file=sys.stderr)
        return 2
    if not (esp / "extlinux").is_dir() and not (esp / "EFI").is_dir():
        print(f"无法判定：{esp} 不是 Ordo 启动分区", file=sys.stderr)
        return 2
    problems = check(esp)
    if not problems:
        print(f"自洽：{esp}")
        return 0
    for problem in problems:
        print(f"!! {problem}", file=sys.stderr)
    print(f"发现 {len(problems)} 个问题：{esp}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
