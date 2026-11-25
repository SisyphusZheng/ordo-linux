"""Exercise pinned firmware extraction and macOS target selection without real devices."""
import hashlib
import io
from pathlib import Path
import sys
import tarfile
import tempfile
from unittest.mock import patch
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "dev/m2"))
from build import PLATFORM, payload_manifest, regulatory_firmware
from prepare import identify, portable_files, publish


def write_tar(path, files):
    with tarfile.open(path, mode="w") as archive:
        for name, data in files.items():
            entry = tarfile.TarInfo(name)
            entry.size = len(data)
            archive.addfile(entry, io.BytesIO(data))


with tempfile.TemporaryDirectory() as directory:
    base = Path(directory)
    platform = base / "platform"
    platform.mkdir()
    assert "kernel/hostid" in payload_manifest() and "kernel/hostid" not in payload_manifest(True)
    manifest = base / "payload.sha256"
    manifest.write_text("".join(f"{digest}  {name}\n" for name, digest in payload_manifest(True).items()))
    pin = hashlib.sha256(manifest.read_bytes()).hexdigest()
    assert payload_manifest(True, manifest, pin) == payload_manifest(True)
    before = manifest.read_bytes()
    manifest.write_bytes(before + b"0" * 64 + b"  ../escape\n")
    for expected, error in [(pin, "SHA-256"), (hashlib.sha256(manifest.read_bytes()).hexdigest(), "required files")]:
        try:
            payload_manifest(True, manifest, expected)
        except ValueError as exc:
            assert error in str(exc)
        else:
            raise AssertionError("Unexpectedly accepted a modified payload manifest")
    payload, destination = base / "payload", base / "destination"
    payload.mkdir()
    source = payload / "asset"
    source.write_bytes(b"candidate")
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    copies = portable_files(payload, destination, {"asset": digest})
    source.write_bytes(b"changed")
    try:
        publish(*copies[0])
    except OSError as error:
        assert "readback" in str(error)
    else:
        raise AssertionError("Published a payload that did not match its trusted hash")
    assert not (destination / "asset").exists()
    source.write_bytes(b"candidate")
    publish(*copies[0])
    assert portable_files(payload, destination, {"asset": digest}) == []
    (destination / "asset").write_bytes(b"unrelated")
    try:
        portable_files(payload, destination, {"asset": digest})
    except ValueError as error:
        assert "Conflicting file" in str(error)
    else:
        raise AssertionError("Candidate overwrote an unrelated file")
    image = base / "image.tar"
    files = {"regulatory.db": b"db", "regulatory.db.p7s": b"signature"}
    write_tar(image, {f"image/lib/firmware/{name}": data for name, data in files.items()})
    package = base / "wireless.gpkg.tar"
    write_tar(package, {"wireless-regdb/image.tar.zst": image.read_bytes()})
    digest = hashlib.sha256(package.read_bytes()).hexdigest()
    (platform / "regdb.sha256").write_text(f"{digest}  {package.name}\n")
    with patch("build.PLATFORM", platform), patch("build.subprocess.check_output", side_effect=lambda cmd, input: input):
        assert regulatory_firmware(base) == files
        package.write_bytes(b"corrupt")
        try:
            regulatory_firmware(base)
        except ValueError as error:
            assert "Invalid wireless regulatory package" in str(error)
        else:
            raise AssertionError("Corrupt package was accepted")

    boot = base / "alternate boot mount"
    root = base / "alternate root mount"
    ids = (uuid.uuid4(), uuid.uuid4())
    whole = "disk21"
    parts = {
        boot: dict(ParentWholeDisk=whole, FilesystemType="msdos", VolumeName="ORDOPAYLOAD",
                   MountPoint=str(boot), DiskUUID=str(ids[0])),
        root: dict(ParentWholeDisk=whole, FilesystemType="exfat", VolumeName="ORDOZFS",
                   MountPoint=str(root), DiskUUID=str(ids[1]), Size=60000000000),
        whole: dict(BusProtocol="USB", Internal=False, VirtualOrPhysical="Physical",
                    Content="GUID_partition_scheme", MediaName="Different USB disk", Size=64000000000),
    }
    assert int((PLATFORM / "minimum-root-bytes").read_text()) <= parts[root]["Size"]
    with patch("prepare.info", side_effect=parts.__getitem__):
        assert identify(boot, root) == ids
        for part, key, bad in [
            (root, "ParentWholeDisk", "disk99"),
            (root, "Size", 16000000000),
            (root, "DiskUUID", str(ids[0])),
            (whole, "Internal", True),
            (whole, "BusProtocol", "PCI-Express"),
            (whole, "VirtualOrPhysical", "Virtual"),
            (boot, "MountPoint", str(root)),
        ]:
            original = parts[part][key]
            parts[part][key] = bad
            try:
                identify(boot, root)
            except ValueError:
                pass
            else:
                raise AssertionError(f"Unsafe device passed validation: {key}={bad}")
            parts[part][key] = original
        loader = boot / "EFI/BOOT/BOOTAA64.EFI"
        loader.parent.mkdir(parents=True)
        loader.touch()
        try:
            identify(boot, root)
        except ValueError as error:
            assert "already contains an installed bootloader" in str(error)
        else:
            raise AssertionError("An already installed disk passed validation")
