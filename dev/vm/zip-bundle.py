#!/usr/bin/env python3
"""Package a UTM bundle for Finder and verify its archived disk."""
import argparse
import hashlib
from pathlib import Path
import re
from tempfile import TemporaryDirectory
from zipfile import ZIP_STORED, ZipFile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--qcow2-sha256", required=True)
    args = parser.parse_args()
    if args.bundle.suffix != ".utm" or args.output.suffix != ".zip":
        parser.error("expected a .utm bundle and a .zip destination")
    if not re.fullmatch(r"[0-9a-f]{64}", args.qcow2_sha256):
        parser.error("disk hash must be a lowercase SHA-256 digest")

    configuration = args.bundle / "config.plist"
    disk = args.bundle / "Data/Ordo.qcow2"
    for path in (configuration, disk):
        if not path.is_file() or path.is_symlink():
            parser.error(f"missing regular bundle file {path}")

    with TemporaryDirectory(dir=args.output.parent) as directory:
        staged = Path(directory) / args.output.name
        config_member = f"{args.bundle.name}/config.plist"
        disk_member = f"{args.bundle.name}/Data/{disk.name}"
        with ZipFile(staged, "x", compression=ZIP_STORED) as archive:
            archive.write(configuration, config_member)
            archive.write(disk, disk_member)
        with ZipFile(staged) as archive, archive.open(disk_member) as member:
            if archive.read(config_member) != configuration.read_bytes():
                parser.error("archived UTM configuration differs")
            actual = hashlib.file_digest(member, "sha256").hexdigest()
            if actual != args.qcow2_sha256:
                parser.error(f"archived disk SHA-256 differs: {actual}")
        args.output.hardlink_to(staged)
    print(f"Verified archived disk SHA-256 {actual}")


if __name__ == "__main__":
    main()
