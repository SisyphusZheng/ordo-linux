from pathlib import Path
import importlib.util
import tempfile
from unittest.mock import patch

platform = Path("config/platform/m2")
defaults = platform / "package-defaults"
spec = importlib.util.spec_from_file_location("repair_defaults", platform / "repair-package-defaults.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def fixture(root):
    replacements = {}
    for version, (category, _, _) in module.PACKAGES.items():
        (root / "var/db/pkg" / category / version).mkdir(parents=True)
        for source in (defaults / version / "etc").rglob("*"):
            if not source.is_file():
                continue
            relative = source.relative_to(defaults / version)
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(module.PLACEHOLDER)
            target.chmod(source.stat().st_mode & 0o777)
            replacements[relative.as_posix()] = source
    return replacements


with tempfile.TemporaryDirectory() as directory:
    root = Path(directory).resolve()
    expected = fixture(root)
    assert len(expected) == 17
    config = root / "etc/conf.d/zfs"
    local = b"ZFS_MOUNT='yes'\n# A local administrator setting\n"
    config.write_bytes(local)
    # A superficially similar comment must survive, even if the size differs by one byte.
    doc = root / "etc/UPower/UPower.conf.d/README.md"
    doc.write_bytes(module.PLACEHOLDER + b"\n")
    upower = root / "etc/UPower/UPower.conf"
    upower.unlink()
    outside = root / "outside"
    outside.write_bytes(module.PLACEHOLDER)
    upower.symlink_to(outside)
    try:
        module.repair(root, defaults, check=True)
    except ValueError as error:
        assert "quickpkg placeholder" in str(error)
    else:
        raise AssertionError("check accepted a placeholder")

    # The helper runs as root in the installed chroot. Model only the UID change here.
    with patch.object(module.os, "fchown"):
        updated = module.repair(root, defaults)
    assert set(updated) == expected.keys() - {
        "etc/conf.d/zfs", "etc/UPower/UPower.conf.d/README.md", "etc/UPower/UPower.conf"}
    for relative in updated:
        assert (root / relative).read_bytes() == expected[relative].read_bytes()
    assert config.read_bytes() == local
    assert doc.read_bytes() == module.PLACEHOLDER + b"\n"
    assert upower.is_symlink() and outside.read_bytes() == module.PLACEHOLDER
    assert module.repair(root, defaults) == ()
    assert module.repair(root, defaults, check=True) == ()

    service = root / "etc/init.d/zfs-mount"
    disabled = b"#!/sbin/openrc-run\n# No start action\n"
    service.write_bytes(disabled)
    try:
        module.repair(root, defaults)
    except ValueError as error:
        assert "Invalid OpenRC service" in str(error)
    else:
        raise AssertionError("empty service passed verification")
    assert service.read_bytes() == disabled

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory).resolve()
    expected = fixture(root)
    (root / "etc/init.d/power-profiles-daemon").unlink()
    zfs_defaults = defaults / "zfs-2.4.4"
    zfs_files = {path.relative_to(zfs_defaults).as_posix()
                 for path in (zfs_defaults / "etc").rglob("*") if path.is_file()}
    with patch.object(module.os, "fchown"):
        updated = module.repair(root, defaults, zfs_only=True)
    assert set(updated) == zfs_files
    for relative in zfs_files:
        assert (root / relative).read_bytes() == expected[relative].read_bytes()
    assert module.repair(root, defaults, check=True, zfs_only=True) == ()
    assert (root / "etc/UPower/UPower.conf").read_bytes() == module.PLACEHOLDER

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory).resolve()
    expected = fixture(root)
    old = root / "var/db/pkg/sys-fs/zfs-2.4.4"
    old.rename(old.with_name("zfs-2.4.5"))
    try:
        module.repair(root, defaults)
    except ValueError as error:
        assert "does not match zfs-2.4.4" in str(error)
    else:
        raise AssertionError("older defaults accepted for a different ZFS version")
    for relative in expected:
        assert (root / relative).read_bytes() == module.PLACEHOLDER
