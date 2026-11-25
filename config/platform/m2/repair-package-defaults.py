#!/usr/bin/env python3
"""Restore exact quickpkg placeholders from the matching package defaults."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile

PLACEHOLDER = b"# empty file because --include-config=n when `quickpkg` was used\n"
PACKAGES = {
    "zfs-2.4.4": ("sys-fs", "zfs", None),
    "upower-1.91.3": ("sys-power", "upower", (
        "usr/libexec/upowerd", "f86d3acd4f746b3a02ade64502c65b4d89d62844bbc91d8717f091e508a20683")),
    "power-profiles-daemon-0.30-r1": ("sys-power", "power-profiles-daemon", (
        "usr/libexec/power-profiles-daemon", "76f050311c7cf58959ad74f70dd12af9f771542d0b03254cdd8483e904c2cdd7")),
}
ZFS_SERVICES = (
    "etc/init.d/zfs-import",
    "etc/init.d/zfs-load-key",
    "etc/init.d/zfs-mount",
    "etc/init.d/zfs-share",
    "etc/init.d/zfs-zed",
)
POWER_SERVICE = "etc/init.d/power-profiles-daemon"
FUNCTIONS = "etc/zfs/zfs-functions"
ZFS_CONFIG = ("etc/conf.d/zfs", FUNCTIONS, "etc/zfs/zed.d/zed-functions.sh")


def matching_version(root, version, category, name, fallback):
    database = root / "var/db/pkg" / category
    versions = {path.name for path in database.glob(f"{name}-[0-9]*") if path.is_dir()}
    if versions:
        return versions == {version}
    if fallback is None:
        return False
    relative, expected = fallback
    with (root / relative).open("rb") as binary:
        return hashlib.file_digest(binary, "sha256").hexdigest() == expected


def read_regular(path, limit=None):
    # Never follow a file or directory link into a different config tree.
    if path.parent.resolve() != path.parent or not stat.S_ISREG(path.lstat().st_mode):
        return None
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as source:
        return source.read(limit)


def check_shell(path, data, service):
    if not data or data == PLACEHOLDER:
        raise ValueError(f"Missing effective package configuration: {path}")
    if service and (not re.match(rb"\A#! ?/(?:usr/bin|sbin)/openrc-run(?:\s|$)", data)
                    or not re.search(rb"^(?:[ \t]*(?:do_)?start[ \t]*\(|[ \t]*command=)", data, re.M)):
        raise ValueError(f"Invalid OpenRC service: {path}")
    if subprocess.run(["sh", "-n"], input=data).returncode:
        raise ValueError(f"Invalid shell syntax: {path}")


def replace(path, data, mode, root):
    directory = path.parent
    while directory != root:
        info = directory.lstat()
        if info.st_uid != os.geteuid() or info.st_mode & 0o022 or not stat.S_ISDIR(info.st_mode):
            raise ValueError(f"Unsafe package configuration directory: {directory}")
        directory = directory.parent
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as output:
        pending = Path(output.name)
        try:
            output.write(data)
            output.flush()
            os.fchown(output.fileno(), 0, 0)
            os.fchmod(output.fileno(), mode)
            if read_regular(path, len(PLACEHOLDER) + 1) != PLACEHOLDER:
                raise ValueError(f"Package configuration changed while restoring: {path}")
            os.replace(pending, path)
        finally:
            pending.unlink(missing_ok=True)


def repair(root, defaults, check=False, zfs_only=False):
    updates = {}
    for version, package in PACKAGES.items():
        if zfs_only and package[1] != "zfs":
            continue
        directory = defaults / version
        for source in sorted(path for path in (directory / "etc").rglob("*") if path.is_file()):
            relative = source.relative_to(directory).as_posix()
            target = root / relative
            try:
                existing = read_regular(target, len(PLACEHOLDER) + 1)
            except FileNotFoundError:
                continue
            if existing != PLACEHOLDER:
                continue
            if check:
                raise ValueError(f"quickpkg placeholder: {target}")
            if not matching_version(root, version, *package):
                raise ValueError(f"Installed package does not match {version}: {target}")
            updates[relative] = (source.read_bytes(), stat.S_IMODE(source.stat().st_mode))

    services = ZFS_SERVICES if zfs_only else (*ZFS_SERVICES, POWER_SERVICE)
    for relative in (*services, *ZFS_CONFIG):
        path = root / relative
        service = relative in services
        if relative in updates:
            data, mode = updates[relative]
        else:
            data = read_regular(path)
            mode = stat.S_IMODE(path.lstat().st_mode)
        if service and not mode & 0o111:
            raise ValueError(f"OpenRC service is not executable: {path}")
        check_shell(path, data, service)
        if relative == FUNCTIONS:
            for function in (b"check_boolean", b"check_module_loaded", b"zfs_action"):
                if not re.search(rb"^" + function + rb"[ \t]*\(", data, re.M):
                    raise ValueError(f"Missing ZFS service function {function.decode()}: {path}")

    for relative, (data, mode) in updates.items():
        replace(root / relative, data, mode, root)
    return tuple(updates)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("/"))
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--zfs-only", action="store_true",
                        help="check or restore only the ZFS package configuration")
    args = parser.parse_args()
    try:
        if not args.check and os.geteuid() != 0:
            raise ValueError("Package configuration restoration requires root")
        defaults = Path(__file__).resolve().with_name("package-defaults")
        updated = repair(args.root.resolve(), defaults, args.check, args.zfs_only)
        print(f"Ordo: verified package configuration, restored {len(updated)} quickpkg placeholders")
    except (ValueError, OSError) as error:
        parser.exit(1, f"Ordo: {error}\n")
