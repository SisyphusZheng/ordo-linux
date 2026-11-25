"""Seal an assembled M2 candidate directory or archive it after signing."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def members(root):
    for path in sorted(root.rglob("*")):
        rel = path.relative_to(root).as_posix()
        if rel in ("SHA256SUMS", "SHA256SUMS.sig"):
            continue
        if "\n" in rel or "\\" in rel or any(part in (".git", ".local", "__pycache__", ".ssh", ".gnupg")
                                                or part.startswith("._") for part in path.relative_to(root).parts):
            raise ValueError(f"Unexpected release path {rel}")
        if path.is_symlink():
            if path.readlink().is_absolute() or not path.resolve(strict=True).is_relative_to(root):
                raise ValueError(f"External dependency in release directory: {rel}")
        if path.is_file():
            yield rel, path
        elif not path.is_dir():
            raise ValueError(f"Special file in release directory: {rel}")


def check(root):
    assets = root / "assets"
    files = {"payload": "payload.sha256", "live": "live/initramfs-live.img", "native": "native/native.sha256"}
    pins = {key: digest(assets / path) for key, path in files.items()}
    required = {"image.squashfs", "kernel/vmlinuz-asahi.EFI"} | {f"rootfs.tar.gz.part{i:02d}" for i in range(4)}
    payload = {}
    for line in (assets / files["payload"]).read_text().splitlines():
        h, name = line.split("  ")
        if not re.fullmatch("[0-9a-f]{64}", h) or name in payload:
            raise ValueError("Invalid payload checksum list")
        payload[name] = h
    if set(payload) != required:
        raise ValueError("Incomplete M2 payload")
    for name, h in payload.items():
        if digest(assets / "payload" / name) != h:
            raise ValueError(f"Payload mismatch: {name}")
    for name in ("Install.command", "runtime/bin/python3", "tools/zstd", "tools/mcopy", "tools/mdir", "tools/aarch64-elf-objcopy",
                 "definition/dev/m2/prepare.py", "definition/dev/release/macos_install.py"):
        if not (root / name).is_file():
            raise ValueError(f"Missing {name}")
    return pins


def sums(root):
    (root / "assets/pins.json").write_text(json.dumps(check(root), indent=2, sort_keys=True) + "\n")
    with tempfile.NamedTemporaryFile("w", dir=root.parent, delete=False) as tmp:
        try:
            for name, path in members(root):
                tmp.write(f"{digest(path)}  {name}\n")
            tmp.flush()
            Path(tmp.name).replace(root / "SHA256SUMS")
        finally:
            Path(tmp.name).unlink(missing_ok=True)


def archive(root, destination):
    if destination.exists() or destination.is_relative_to(root):
        raise ValueError("Choose a new archive path outside the candidate directory")
    sums_path = root / "SHA256SUMS"
    with sums_path.open("rb") as stream:
        subprocess.run(["ssh-keygen", "-Y", "verify", "-f", str(root / "definition/config/release/allowed_signers"),
                        "-I", "ordo-preview", "-n", "ordo-release", "-s", str(root / "SHA256SUMS.sig")],
                       stdin=stream, check=True)
    expected = dict((name, value) for value, name in
                    (line.split("  ", 1) for line in sums_path.read_text().splitlines()))
    if {name: digest(path) for name, path in members(root)} != expected:
        raise ValueError("Signed release directory has changed")
    def metadata(info):
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        return info
    with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as tmp:
        try:
            with tarfile.open(fileobj=tmp, mode="w:gz", compresslevel=1) as tar:
                tar.add(root, arcname=root.name, filter=metadata)
            tmp.flush()
            Path(tmp.name).replace(destination)
        finally:
            Path(tmp.name).unlink(missing_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["checksums", "archive"])
    parser.add_argument("root", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.action == "checksums":
        sums(args.root.resolve())
    elif args.output:
        archive(args.root.resolve(), args.output.resolve())
    else:
        parser.error("archive requires --output")
