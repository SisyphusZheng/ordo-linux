#!/usr/bin/env python3
"""Refresh boot files on an already partitioned M2 USB installer."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid

from build import PLATFORM, REPO, build, payload_args, selected_payload
from native_payload import NativePayload, native_args, published_native


def info(volume):
    return plistlib.loads(subprocess.check_output(["diskutil", "info", "-plist", str(volume)]))


def identify(boot, system):
    a, b = info(boot), info(system)
    parent = a.get("ParentWholeDisk")
    if not (
        parent and parent == b.get("ParentWholeDisk")
        and a.get("FilesystemType") == "msdos" and a.get("VolumeName") == "ORDOPAYLOAD"
        and b.get("FilesystemType") == "exfat" and b.get("VolumeName") == "ORDOZFS"
        and a.get("MountPoint") == str(boot) and b.get("MountPoint") == str(system)
        and b.get("Size", 0) >= int((PLATFORM / "minimum-root-bytes").read_text())
    ):
        raise ValueError("Expected mounted ORDOPAYLOAD and ORDOZFS partitions on the same disk")
    disk = info(parent)
    if not (
        disk.get("BusProtocol") == "USB" and disk.get("Internal") is False
        and disk.get("VirtualOrPhysical") == "Physical" and disk.get("Content") == "GUID_partition_scheme"
    ):
        raise ValueError("Expected a physical external GPT USB disk")
    ids = uuid.UUID(a["DiskUUID"]), uuid.UUID(b["DiskUUID"])
    if ids[0] == ids[1] or not all(item.int for item in ids):
        raise ValueError("Expected two distinct, nonzero GPT partition UUIDs")
    if (boot / "EFI/BOOT/BOOTAA64.EFI").exists():
        raise ValueError("Target already contains an installed bootloader")
    return ids


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def publish(source, target, expected=None):
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as output:
        pending = Path(output.name)
    try:
        shutil.copyfile(source, pending)
        with pending.open("rb") as f:
            os.fsync(f.fileno())
            if hashlib.file_digest(f, "sha256").hexdigest() != (expected or digest(source)):
                raise OSError(f"Failed readback: {target}")
        os.replace(pending, target)
    finally:
        pending.unlink(missing_ok=True)


def portable_files(payload, boot, digests):
    files = []
    for relative, expected in digests.items():
        source, target = payload / relative, boot / relative
        if target.exists():
            if not target.is_file() or digest(target) != expected:
                raise ValueError(f"Conflicting file on USB boot volume: {target}")
        else:
            files.append((source, target, expected))
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, required=True)
    parser.add_argument("--boot-volume", type=Path, default=Path("/Volumes/ORDOPAYLOAD"))
    parser.add_argument("--root-volume", type=Path, default=Path("/Volumes/ORDOZFS"))
    parser.add_argument("--inner", type=Path, help="Legacy ORDOINNER mount or local payload directory")
    parser.add_argument("--usb-payload", action="store_true",
                        help="Publish the full payload on the external USB boot volume")
    payload_args(parser)
    parser.add_argument("--binhost", type=Path, help="Defaults to binhost on the boot volume")
    parser.add_argument("--save-live-logs", action="store_true", help="Allow diagnostic logs on the mounted ORDOINNER partition")
    parser.add_argument("--vendor-cpio", type=Path)
    native_args(parser)
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--native-source", type=Path, help="Use a specific published native asset directory")
    selection.add_argument("--legacy", action="store_true", help="Explicitly prepare the original installation payload")
    args = parser.parse_args()
    if args.usb_payload:
        if not (args.inner and args.vendor_cpio and args.binhost and args.payload_manifest and args.base_sha256):
            parser.error("--usb-payload requires --inner, --vendor-cpio, --binhost and release checksums")
        if args.save_live_logs:
            parser.error("--save-live-logs requires the ORDOINNER layout")
        if subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip() != "Mac14,2":
            parser.error("--usb-payload supports MacBook Air M2 (Mac14,2)")
    args.inner = args.inner or Path("/Volumes/ORDOINNER")
    try:
        digests = selected_payload(parser, args)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    native = NativePayload.from_args(parser, args)
    if native and (args.legacy or args.native_source):
        parser.error("Explicit native manifest options cannot be combined with --legacy or --native-source")
    if not args.legacy and not native:
        locations = ([args.native_source] if args.native_source else [
            REPO / ".local/m2-native-release", args.boot_volume / "ordo-native", args.inner / "native"])
        try:
            native = published_native(locations, PLATFORM / "native-release.sha256")
        except (OSError, ValueError) as error:
            parser.error(str(error))
        if args.native_source and not native:
            parser.error(f"No published native assets at {args.native_source}")
    if args.usb_payload and not native:
        parser.error("--usb-payload requires pinned native kernel and packages")
    boot, system = args.boot_volume.resolve(), args.root_volume.resolve()
    ids = identify(boot, system)
    if args.usb_payload:
        model = info(info(boot)["ParentWholeDisk"])
        print(f"External USB: {model.get('MediaName', 'USB')} ({model.get('Size', 0)} bytes)")
        print(f"Boot volume: {boot} ({ids[0]})\nSystem volume: {system} ({ids[1]})")
        answer = input(f"Verify your backup and confirm USB preparation with PREPARE {str(ids[1])[-4:]}: ")
        if answer != f"PREPARE {str(ids[1])[-4:]}":
            parser.error("USB preparation canceled")
    with tempfile.TemporaryDirectory() as folder:
        stage = Path(folder)
        inner = args.inner
        log_id = uuid.UUID(info(inner)["DiskUUID"]) if args.save_live_logs else None
        build(args.base, inner, stage, *ids, log_id=log_id, vendor_cpio=args.vendor_cpio,
              binhost=args.binhost or boot / "binhost", native=native, usb_payload=args.usb_payload,
              payload_digests=digests, base_sha256=args.base_sha256)
        if identify(boot, system) != ids:
            raise ValueError("Target changed while building")
        # The Live initrd references content-addressed files on the boot volume.
        # Publish those files before replacing any entry point that uses them.
        entries = {"initramfs-live-manual.img", "initramfs-external.img", "initramfs-512.img",
                   "ordo-manual.conf", "extlinux.conf", "BOOTAA64.EFI"}
        files = sorted(file for file in stage.rglob("*") if file.is_file())
        ordered = [file for file in files if file.name not in entries]
        ordered.extend(file for file in files if file.name in entries and file.name not in ("extlinux.conf", "BOOTAA64.EFI"))
        ordered.append(stage / "extlinux/extlinux.conf")
        if args.usb_payload:
            ordered.append(stage / "EFI/BOOT/BOOTAA64.EFI")
        copies = portable_files(inner, boot, digests) if args.usb_payload else []
        copies += [(file, boot / file.relative_to(stage), None) for file in ordered]
        required = sum(source.stat().st_size + 1024 * 1024 for source, _, _ in copies)
        if args.usb_payload and shutil.disk_usage(boot).free < required:
            raise ValueError("USB boot volume has insufficient free space")
        for source, target, expected in copies:
            if identify(boot, system) != ids:
                raise ValueError("Target changed while publishing")
            publish(source, target, expected)
    print(f"USB prepared. Confirm in Live with INSTALL {str(ids[1])[-4:]}")


if __name__ == "__main__":
    main()
