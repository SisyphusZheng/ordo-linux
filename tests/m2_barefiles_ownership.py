from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import hashlib
import importlib.util
import os
import sys
import tempfile

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("repair_barefiles", "config/platform/m2/repair-barefiles.py")
repair_barefiles = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair_barefiles)

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    package = root / "package"
    package.mkdir(mode=0o755)
    tools = root / "usr/bin"
    tools.mkdir(mode=0o755, parents=True)
    (root / "usr/sbin").symlink_to("bin", target_is_directory=True)
    tool = tools / "i2cdetect"
    tool.write_bytes(b"known tool")
    tool.chmod(0o644)
    (root / "untrusted").symlink_to(package, target_is_directory=True)
    entries = {}
    for name, content in {
        "program": b"trusted package asset",
        "local-change": b"changed",
        "different-owner": b"trusted package asset",
        "unrelated-state": b"runtime battery history",
        "._program": b"AppleDouble metadata",
    }.items():
        path = package / name
        path.write_bytes(content)
        path.chmod(0o644)
        entries[name] = path
    link = package / "package-link"
    link.symlink_to("program")
    original = {path: (501, 0) for path in [package, link, tool, *entries.values()]}
    original[entries["different-owner"]] = (150, 0)
    original[entries["unrelated-state"]] = (0, 0)
    manifest = root / "barefiles-ownership.tsv"

    def regular(path, expected, kind="F"):
        return f"{kind}\t0644\t{hashlib.sha256(expected).hexdigest()}\t{len(expected)}\t{path}"

    manifest.write_text("\n".join([
        "D\t0755\t-\t0\tpackage",
        regular("package/._program", entries["._program"].read_bytes(), "A"),
        regular("package/different-owner", entries["different-owner"].read_bytes()),
        regular("package/local-change", b"trusted"),
        "L\t0777\tprogram\t0\tpackage/package-link",
        regular("package/program", entries["program"].read_bytes()),
        "D\t0755\t-\t0\tuntrusted",
        regular("untrusted/different-owner", entries["different-owner"].read_bytes()),
        "D\t0755\t-\t0\tusr",
        "D\t0755\t-\t0\tusr/bin",
        "D\t0755\t-\t0\tusr/sbin",
        regular("usr/sbin/i2cdetect", tool.read_bytes()),
    ]) + "\n")
    lstat = Path.lstat
    replace = os.replace

    def fake_lstat(path):
        info = lstat(path)
        uid, gid = original.get(path, (0, 0))
        return SimpleNamespace(st_mode=info.st_mode, st_uid=uid, st_gid=gid,
                               st_nlink=info.st_nlink, st_size=info.st_size)

    def fake_chown(path, uid, gid, follow_symlinks):
        assert not follow_symlinks
        original[path] = (uid, gid)

    def fake_replace(source, path):
        replace(source, path)
        original[path] = (0, 0)

    with patch.object(Path, "lstat", fake_lstat), patch.object(os, "chown", fake_chown), \
         patch.object(os, "fchown"), patch.object(os, "replace", fake_replace):
        repaired, issues = repair_barefiles.repair(root, manifest)
        assert repaired == 5 and issues == ["package/local-change: content changed"]
        second, second_issues = repair_barefiles.repair(root, manifest)
        assert second == 0 and second_issues == issues
    assert original[entries["program"]] == (0, 0)
    assert original[entries["different-owner"]] == (150, 0)
    assert entries["unrelated-state"].read_bytes() == b"runtime battery history"
    assert entries["local-change"].read_bytes() == b"changed"
    assert link.is_symlink() and os.readlink(link) == "program"
    assert not entries["._program"].exists()
    assert original[tool] == (0, 0)
