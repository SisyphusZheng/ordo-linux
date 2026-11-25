#!/usr/bin/env python3
"""Restore the ownership of verifiable entries from the macOS-staged M2 archive."""
from pathlib import Path
import hashlib
import os
import stat
import sys
import tempfile


def repair_entry(path, kind, mode, expected, size, current):
    if kind == "D" and stat.S_ISDIR(current.st_mode) and stat.S_IMODE(current.st_mode) == mode:
        os.chown(path, 0, 0, follow_symlinks=False)
        return
    if kind == "L" and stat.S_ISLNK(current.st_mode) and os.readlink(path) == expected:
        os.chown(path, 0, 0, follow_symlinks=False)
        return
    if kind not in ("F", "A") or not stat.S_ISREG(current.st_mode) or current.st_nlink != 1:
        raise ValueError("type or link count changed")
    if stat.S_IMODE(current.st_mode) != mode or current.st_size != size:
        raise ValueError("mode or size changed")
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as source:
        data = source.read(size + 1)
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError("content changed")
    if kind == "A":
        path.unlink()
        return
    # Keep the original inode untrusted until a checked copy replaces the path.
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as output:
        pending = Path(output.name)
        try:
            output.write(data)
            output.flush()
            os.fchmod(output.fileno(), mode)
            os.fchown(output.fileno(), 0, 0)
            os.replace(pending, path)
        finally:
            pending.unlink(missing_ok=True)


def repair(root, manifest):
    repaired = 0
    issues = []
    trusted = {root: root}
    for line in manifest.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        kind, mode, expected, size, relative = line.split("\t")
        rel = Path(relative)
        if rel.is_absolute() or ".." in rel.parts or not rel.parts:
            raise ValueError(f"Invalid package path: {relative}")
        declared = root / rel
        parent = trusted.get(declared.parent)
        if parent is None:
            continue
        path = parent / declared.name
        try:
            current = path.lstat()
        except FileNotFoundError:
            continue
        if (current.st_uid, current.st_gid) == (501, 0):
            try:
                repair_entry(path, kind, int(mode, 8), expected, int(size), current)
            except (OSError, ValueError) as error:
                issues.append(f"{relative}: {error}")
                continue
            repaired += 1
        if kind != "D":
            continue
        current = path.lstat()
        if stat.S_ISDIR(current.st_mode) and current.st_uid == 0 and not current.st_mode & 0o022:
            trusted[declared] = path
        elif rel == Path("usr/sbin") and (current.st_uid, current.st_gid) == (0, 0):
            # Merged /usr uses this exact alias. Other links in the package paths
            # remain outside the trusted directory map.
            if stat.S_ISLNK(current.st_mode) and os.readlink(path) == "bin" and path.parent / "bin" in trusted:
                trusted[declared] = path.parent / "bin"
    return repaired, issues


if __name__ == "__main__":
    manifest = Path(__file__).resolve().with_name("barefiles-ownership.tsv")
    count, problems = repair(Path("/"), manifest)
    print(f"Ordo: verified and repaired {count} legacy M2 package entries")
    for problem in problems:
        print(f"Ordo: {problem}", file=sys.stderr)
    sys.exit(2 if problems else 0)
