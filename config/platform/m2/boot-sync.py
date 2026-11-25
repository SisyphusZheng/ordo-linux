"""Publish the selected ZFS environment's boot files to its external ESP."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import signal
import struct
import subprocess
import sys
import tempfile

from uki import Uki


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def replace(source, destination):
    os.replace(source, destination)
    sync_directory(destination.parent)


def stage(work, name, source):
    target = work / name
    with target.open("wb") as out:
        if isinstance(source, bytes):
            out.write(source)
        else:
            with source.open("rb") as inp:
                shutil.copyfileobj(inp, out)
        out.flush()
        os.fsync(out.fileno())
    return target


def active_entries(esp):
    uki = Uki(esp / "EFI/BOOT/BOOTAA64.EFI")
    if b"root=zfs:AUTO" not in uki.read(".cmdline").split() or b"ID=ordo" not in uki.read(".osrel").splitlines():
        raise ValueError("外置 ESP 的默认 EFI 不是 Ordo 直接启动镜像")
    if any(not (esp / file).stat().st_size for file in (
            "EFI/Ordo/ZFSBootMenu.EFI", "extlinux/ordo-manual.conf", "extlinux/extlinux.conf")):
        raise ValueError("外置 ESP 缺少 ZFSBootMenu 或手动恢复入口")
    return uki, esp / "extlinux/extlinux.conf"


def extlinux_config(config, generation):
    text = config.read_bytes()
    if not re.search(rb"^DEFAULT[ \t]+ordo[ \t]*\r?$", text, re.MULTILINE):
        raise ValueError("extlinux 默认入口不是 ordo")
    before, entry, after = re.split(rb"(^LABEL[ \t]+ordo[ \t]*\r?\n)", text, maxsplit=1, flags=re.MULTILINE)
    stanza, *rest = re.split(rb"(?=^LABEL[ \t])", after, maxsplit=1, flags=re.MULTILINE)
    directory = b"/ordo-kernel/"
    if generation:
        directory += generation.encode() + b"/"
    for directive, filename in ((b"KERNEL", b"vmlinuz"), (b"INITRD", b"initramfs.img")):
        stanza, changes = re.subn(rb"^([ \t]*" + directive + rb"[ \t]+)[^\r\n]+",
                                  rb"\g<1>" + directory + filename,
                                  stanza, flags=re.MULTILINE)
        if changes != 1:
            raise ValueError("extlinux 的 ordo 入口缺少唯一的 KERNEL 或 INITRD")
    return b"".join((before, entry, stanza, *rest))


def files_match(first, second):
    if not second.is_file() or first.stat().st_size != second.stat().st_size:
        return False
    with first.open("rb") as a, second.open("rb") as b:
        while chunk := a.read(1024 * 1024):
            if b.read(len(chunk)) != chunk:
                return False
        return not b.read(1)


def copy_member(source, length, write):
    remaining = length
    while remaining:
        chunk = source.read(min(remaining, 1024 * 1024))
        if not chunk:
            raise ValueError("initramfs 不完整")
        write(chunk)
        remaining -= len(chunk)


def verify_initramfs(image, release, root_uuid, version, firmware=None, drivers=()):
    expected = {}
    if firmware:
        for row in firmware.read_text().splitlines():
            digest, name = row.split("  ", 1)
            expected[name.encode()] = digest
    matching_firmware = set()
    remaining_drivers = {name.encode().split(b".ko", 1)[0] for name in drivers}
    remaining_indices = {b"modules.dep.bin", b"modules.alias.bin"} if remaining_drivers else set()
    release_dir = f"/lib/modules/{release}/".encode()
    with tempfile.TemporaryDirectory() as scratch:
        with subprocess.Popen(["zstd", "-dc", image], stdout=subprocess.PIPE) as process:
            source = process.stdout
            wait_for_usb = False
            zfs_module = None
            while True:
                # Linux accepts zero padding between consecutive newc archives.
                lead = source.read(1)
                if not lead:
                    break
                if lead == b"\0":
                    continue
                header = lead + source.read(109)
                if header[:6] not in (b"070701", b"070702") or len(header) != 110:
                    raise ValueError("initramfs 的 newc 归档无效")
                length = int(header[54:62], 16)
                name_size = int(header[94:102], 16)
                if not 1 <= name_size <= 4096:
                    raise ValueError("initramfs 的 newc 文件名无效")
                name = source.read(name_size).rstrip(b"\0").removeprefix(b"./")
                source.read(-(110 + name_size) % 4)
                if name.endswith(b"/pre-mount/20-ordo-usb.sh") and length < 32768:
                    wait_for_usb = f"/dev/disk/by-partuuid/{root_uuid}".encode() in source.read(length)
                elif release_dir in b"/" + name and re.search(rb"/zfs\.ko(\.[a-z0-9]+)?$", name):
                    # Concatenated overlays can replace an earlier module.
                    zfs_module = Path(scratch) / name.decode().rsplit("/", 1)[-1]
                    with zfs_module.open("wb") as out:
                        copy_member(source, length, out.write)
                elif name in expected:
                    digest = hashlib.sha256()
                    copy_member(source, length, digest.update)
                    if digest.hexdigest() == expected[name]:
                        matching_firmware.add(name)
                    else:
                        matching_firmware.discard(name)
                else:
                    if length and release_dir in b"/" + name:
                        relative = (b"/" + name).split(release_dir, 1)[1]
                        module = relative.split(b".ko", 1)[0]
                        remaining_drivers.discard(module)
                        remaining_drivers.discard(module.rsplit(b"/", 1)[-1])
                        remaining_indices.discard(relative)
                    copy_member(source, length, lambda _chunk: None)
                source.read(-length % 4)
            if process.wait() or not wait_for_usb or not zfs_module:
                raise ValueError("initramfs 缺少已确认的 USB 分区等待脚本或匹配的 ZFS 模块")
        embedded = subprocess.check_output(["modinfo", "-F", "version", zfs_module], text=True).strip()
        if embedded != version:
            raise ValueError(f"initramfs 的 ZFS 模块 {embedded} 与目标系统 {version} 不一致")
    if missing := (expected.keys() - matching_firmware) | remaining_drivers | remaining_indices:
        raise ValueError("initramfs 缺少匹配的 M2 驱动或固件：" +
                         ", ".join(name.decode() for name in sorted(missing)))


def publish(esp, kernel, initrd, bootfs):
    uki, config = active_entries(esp)
    with kernel.open("rb") as source:
        header = source.read(64)
    if header[:2] != b"MZ" or header[56:60] != b"ARMd" or not initrd.stat().st_size:
        raise ValueError("内核或 initramfs 不是有效的 M2 启动产物")
    pieces = {".linux": kernel, ".initrd": initrd}
    artifacts = esp / "ordo-kernel"
    name = ""
    if not (files_match(kernel, artifacts / "vmlinuz") and files_match(initrd, artifacts / "initramfs.img")):
        digests = []
        for file in pieces.values():
            with file.open("rb") as source:
                digests.append(hashlib.file_digest(source, "sha256").hexdigest())
        name = "ordo-" + hashlib.sha256("".join(digests).encode()).hexdigest()[:24]
    entry_config = extlinux_config(config, name)
    generation = artifacts / name
    previous_config = esp / "extlinux/ordo-previous.conf"
    system_config = esp / "extlinux/ordo-system.conf"
    previous_uki = esp / "EFI/Ordo/Previous.EFI"
    old_config = config.read_bytes()
    switch_started = False
    if bootfs:
        pool, old_root, new_root = bootfs
        if not all(root.startswith(pool + "/") for root in (old_root, new_root)):
            raise ValueError("bootfs 必须位于外置系统池内")
    old_generation = re.search(rb"/ordo-kernel/(ordo-[0-9a-f]{24})/", old_config)
    same_uki = all(uki.matches(label, file) for label, file in pieces.items())

    with tempfile.TemporaryDirectory(prefix=".ordo-boot-", dir=esp) as folder:
        work = Path(folder)
        if not generation.exists():
            new_generation = work / "generation"
            new_generation.mkdir()
            stage(new_generation, "vmlinuz", kernel)
            stage(new_generation, "initramfs.img", initrd)
            sync_directory(new_generation)
            replace(new_generation, generation)
        if not (files_match(kernel, generation / "vmlinuz") and
                files_match(initrd, generation / "initramfs.img")):
            raise ValueError(f"外置启动产物校验失败：{generation}")

        changes = []
        if not same_uki:
            reuse_previous = False
            if previous_uki.exists():
                try:
                    previous = Uki(previous_uki)
                    reuse_previous = (previous.read(".cmdline") == uki.read(".cmdline") and
                                      all(previous.matches(label, file) for label, file in pieces.items()))
                except (ValueError, struct.error):
                    # An invalid old backup must not prevent rebuilding the active image.
                    pass
            if reuse_previous:
                stage(work, "new.efi", previous_uki)
            else:
                uki.replace(pieces, work / "new.efi", work)
            candidate = Uki(work / "new.efi")
            if (candidate.read(".cmdline") != uki.read(".cmdline") or
                    not all(candidate.matches(label, file) for label, file in pieces.items())):
                raise ValueError("新 EFI 内嵌的启动产物校验失败")
            with candidate.path.open("rb") as source:
                os.fsync(source.fileno())
            recovery = stage(work, "old.efi", uki.path)
            if not files_match(uki.path, recovery):
                raise ValueError("上一版 EFI 备份校验失败")
            replace(recovery, previous_uki)
            changes.append((candidate.path, uki.path, previous_uki))

        if entry_config != old_config:
            replace(stage(work, "old.conf", old_config), previous_config)
            changes.append((stage(work, "new.conf", entry_config), config, previous_config))
        if system_config.exists() and system_config.read_bytes() != entry_config:
            old_system = esp / "extlinux/ordo-previous-system.conf"
            replace(stage(work, "old-system.conf", system_config), old_system)
            changes.append((stage(work, "new-system.conf", entry_config), system_config, old_system))

        # Keep working copies of the previous entries until all writes and the
        # optional bootfs switch have succeeded.
        applied = []
        try:
            for idx, (new, destination, backup) in enumerate(changes):
                applied.append((destination, backup, idx))
                replace(new, destination)
            if bootfs:
                switch_started = True
                subprocess.run(["zpool", "set", f"bootfs={new_root}", pool], check=True)
        except (OSError, subprocess.SubprocessError, InterruptedError):
            if switch_started:
                try:
                    subprocess.run(["zpool", "set", f"bootfs={old_root}", pool], check=True)
                except (OSError, subprocess.SubprocessError):
                    print(f"无法恢复 bootfs={old_root}，请通过 ZFSBootMenu 恢复", file=sys.stderr)
            for destination, backup, idx in reversed(applied):
                try:
                    replace(stage(work, f"restore-{idx}", backup), destination)
                except OSError as error:
                    print(f"无法恢复 {destination}，其备份位于 {backup}: {error}", file=sys.stderr)
            raise

    keeps = {name}
    if old_generation:
        keeps.add(old_generation.group(1).decode())
    if previous_config.exists():
        keeps.update(value.decode() for value in re.findall(rb"/ordo-kernel/(ordo-[0-9a-f]{24})/",
                                                             previous_config.read_bytes()))
    for old_dir in artifacts.iterdir():
        if re.fullmatch(r"ordo-[0-9a-f]{24}", old_dir.name) and old_dir.name not in keeps:
            try:
                shutil.rmtree(old_dir)
            except OSError as error:
                print(f"无法清理旧启动产物 {old_dir}: {error}", file=sys.stderr)


def interrupted(_signum, _frame):
    raise InterruptedError("启动文件同步中断")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("esp", type=Path, nargs="?")
    parser.add_argument("--check-initrd", nargs=4, metavar=("IMAGE", "RELEASE", "UUID", "ZFS_VERSION"))
    parser.add_argument("--firmware-manifest", type=Path)
    parser.add_argument("--driver", action="append", default=[])
    parser.add_argument("--publish", nargs=2, type=Path, metavar=("KERNEL", "INITRAMFS"))
    parser.add_argument("--bootfs", nargs=3, metavar=("POOL", "OLD", "NEW"))
    args = parser.parse_args()
    for number in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(number, interrupted)
    try:
        if args.check_initrd:
            verify_initramfs(*args.check_initrd, firmware=args.firmware_manifest, drivers=args.driver)
        elif args.publish and args.esp:
            publish(args.esp, *args.publish, bootfs=args.bootfs)
        elif args.esp:
            _, config = active_entries(args.esp)
            extlinux_config(config, "check")
        else:
            parser.error("外置启动分区或 --check-initrd 为必填项")
    except (OSError, ValueError, RuntimeError, struct.error, subprocess.SubprocessError) as error:
        print(f"M2 启动文件同步失败：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
