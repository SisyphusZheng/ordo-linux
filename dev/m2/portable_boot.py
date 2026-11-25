"""Prepare generic initramfs archives and assemble the ARM64 recovery EFI."""
import argparse
from pathlib import Path, PurePosixPath
import stat
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "config/platform/m2"))
from uki import Uki

LOCAL_FILES = frozenset({
    "etc/hostid", "etc/machine-id", "etc/zfs/zpool.cache", "etc/shadow",
    "etc/gshadow", "etc/fstab", "etc/crypttab", "etc/hostname",
    "etc/resolv.conf", "var/lib/dbus/machine-id", "root/.bashrc", "root/.profile",
})


def generic_archive(blob):
    """Process every concatenated newc archive, including duplicate members."""
    index = 0
    out = bytearray()
    ended = False
    while index < len(blob):
        if blob[index] == 0:
            if not ended:
                raise ValueError("Unexpected padding inside newc archive")
            while index < len(blob) and blob[index] == 0:
                index += 1
            continue
        start = index
        if blob[index:index+6] != b"070701" or index + 110 > len(blob):
            raise ValueError("Expected an uncompressed newc archive")
        fields = [int(blob[index+i:index+i+8], 16) for i in range(6, 110, 8)]
        mode, size, namesize = fields[1], fields[6], fields[11]
        name_end = index + 110 + namesize
        if namesize < 1 or blob[name_end-1:name_end] != b"\0":
            raise ValueError("Invalid initramfs filename")
        name = blob[index+110:name_end-1].decode()
        path = PurePosixPath(name)
        if path.is_absolute() or ".." in path.parts or "\0" in name:
            raise ValueError(f"Unsafe initramfs filename: {name}")
        name = path.as_posix()
        data_start = (name_end + 3) & ~3
        index = (data_start + size + 3) & ~3
        if index > len(blob):
            raise ValueError("Truncated initramfs entry")
        ended = name == "TRAILER!!!"
        if name in LOCAL_FILES:
            continue
        if not stat.S_ISDIR(mode):
            if (name.startswith(("home/", "root/", "etc/ssh/", "etc/cmdline.d/", "etc/NetworkManager/system-connections/"))
                    or name.endswith((".key", ".p12")) or "/vendorfw/" in name):
                raise ValueError(f"Unexpected machine data in boot archive: {name}")
            if name.startswith(("usr/lib/firmware/", "lib/firmware/")) and name.split("firmware/", 1)[1] not in ("regulatory.db", "regulatory.db.p7s"):
                raise ValueError(f"Unexpected firmware in generic boot archive: {name}")
        out.extend(blob[start:index])
    if not ended:
        raise ValueError("Missing final newc trailer")
    return bytes(out)


def sanitize(source, destination):
    data = subprocess.check_output(["zstd", "-dc", source])
    generic = generic_archive(data)
    packed = subprocess.check_output(["zstd", "-q", "-3", "-c"], input=generic)
    destination.write_bytes(packed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    initrd = actions.add_parser("generic")
    initrd.add_argument("source", type=Path)
    initrd.add_argument("destination", type=Path)
    recovery = actions.add_parser("recovery")
    for field in ("stub", "kernel", "initrd", "destination"):
        recovery.add_argument(field, type=Path)
    args = parser.parse_args()
    if args.action == "generic":
        sanitize(args.source, args.destination)
        return
    version = (Path(__file__).resolve().parents[2] / "version").read_text().strip()
    sections = {
        ".osrel": f'ID=ordo\nNAME="Ordo Linux"\nVERSION_ID="{version}"\n'.encode(),
        ".cmdline": b"ro loglevel=4 zbm.show",
        ".linux": args.kernel,
        ".initrd": args.initrd,
    }
    with tempfile.TemporaryDirectory() as temporary:
        Uki(args.stub).replace(sections, args.destination, temporary)
    image = Uki(args.destination)
    for name, source in sections.items():
        expected = source.read_bytes() if isinstance(source, Path) else source
        if image.read(name) != expected:
            raise ValueError(f"Recovery EFI section differs from its input: {name}")


if __name__ == "__main__":
    main()
