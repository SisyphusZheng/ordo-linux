"""Check immutable native staging without requiring a compiled Asahi tree."""
import hashlib
from io import BytesIO
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, "dev/m2")
from build import archive
from native_payload import NativePayload, REQUIRED_PACKAGES, REQUIRED_USE, published_native


@unittest.skipUnless(subprocess.run(["sh", "-c", "command -v zstd"], capture_output=True).returncode == 0,
                     "zstd is needed for native payload fixtures")
class NativePayloadTest(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        self.release = "7.0.9-asahi-2-ordo-agx"
        self.kernel = f"stage/boot/vmlinuz-{self.release}"
        self.initramfs = f"stage/boot/initramfs-{self.release}.img"
        self.modules = f"stage/lib/modules/{self.release}/"
        self.zfs = f"usr/lib/modules/{self.release}/extra/zfs.ko"
        self.drivers = ["apple-dart", "appledrm", "brcmfmac", "hci_bcm4377", "usb-storage"]
        self.modular = ["apple-dart", "appledrm", "brcmfmac", "hci_bcm4377", "asahi", "iova"]
        paths = {name: f"kernel/drivers/{name}.ko" for name in self.modular}
        index = "extra/zfs.ko:\n" + "".join(f"{path}: " +
                 (paths["iova"] if name == "apple-dart" else "") + "\n" for name, path in paths.items())
        self.files = {
            self.kernel: b"MZ" + bytes(54) + b"ARMd" + f"Linux version {self.release} (fixture)".encode(),
            self.initramfs: self.initrd(),
            self.modules + "modules.dep": index.encode(),
            self.modules + "modules.builtin": b"kernel/drivers/usb/storage/usb-storage.ko\n",
            self.modules + "extra/zfs.ko": b"test ZFS",
            **{self.modules + path: b"fixture driver" for path in paths.values()},
        }
        self.revision = "a" * 40
        repo = BytesIO()
        with tarfile.open(fileobj=repo, mode="w:gz", format=tarfile.PAX_FORMAT,
                          pax_headers={"comment": self.revision}) as packed:
            for name, data in {"profiles/repo_name": b"asahi\n", "metadata/layout.conf": b"masters = gentoo\n"}.items():
                member = tarfile.TarInfo(name)
                member.size = len(data)
                packed.addfile(member, BytesIO(data))
        self.files["asahi-repo.tar.gz"] = repo.getvalue()
        self.index()
        self.output = self.root / "out"
        (self.output / "live").mkdir(parents=True)

    def initrd(self, omit=None, **extras):
        module_path = f"usr/lib/modules/{self.release}/"
        files = {
            f"kernel/drivers/{name}.ko": b"fixture driver" for name in self.modular
        } | {"modules.dep.bin": b"fixture index", "modules.alias.bin": b"fixture aliases"}
        files.pop(omit, None)
        data = archive({self.zfs: b"test ZFS", **{module_path + name: content for name, content in files.items()}, **extras})
        return subprocess.check_output(["zstd", "-qc"], input=data)

    def index(self, missing=None):
        records = []
        for package in sorted(REQUIRED_PACKAGES - {missing}):
            name = package.split("/")[1]
            path = f"{package}/{name}-1-2.gpkg.tar"
            self.files[f"binpkgs/{path}"] = f"mock {name}".encode()
            flags = " ".join(sorted(REQUIRED_USE.get(package, set())))
            records.append(f"CPV: {package}-1\nPATH: {path}\nUSE: {flags}")
        self.files["binpkgs/Packages"] = "\n\n".join(records).encode()

    def make_spec(self):
        rows = []
        for name, content in sorted(self.files.items()):
            file = self.root / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(content)
            rows.append(f"{hashlib.sha256(content).hexdigest()}  {name}\n")
        manifest = self.root / "native.sha256"
        manifest.write_text("".join(rows))
        return NativePayload(manifest, hashlib.sha256(manifest.read_bytes()).hexdigest())

    def test_reproducible_pinned_native_capsule(self):
        spec = self.make_spec()
        release, kernel, digest, initrd, bundle = spec.build(self.output, self.revision, self.drivers)
        self.assertEqual(release, self.release)
        self.assertEqual(kernel.read_bytes(), self.files[self.kernel])
        self.assertEqual(digest, hashlib.sha256(kernel.read_bytes()).hexdigest())
        self.assertEqual(initrd, self.files[self.initramfs])
        with tarfile.open(self.output / f"native-{bundle}.tar.gz") as packed:
            self.assertEqual(packed.extractfile(f"modules/{release}/extra/zfs.ko").read(), b"test ZFS")
            self.assertIn(b"=media-libs/mesa-1\n", packed.extractfile("package-atoms").read())
        self.assertEqual(spec.build(self.output, self.revision, self.drivers)[-1], bundle)

    def test_refuse_altered_manifest_and_staged_binary(self):
        spec = self.make_spec()
        with self.assertRaisesRegex(ValueError, "manifest SHA-256"):
            NativePayload(spec.manifest, "0" * 64).build(self.output, self.revision, self.drivers)
        with self.assertRaisesRegex(ValueError, "repository revision"):
            spec.build(self.output, "b" * 40, self.drivers)
        (self.root / self.modules / "extra/zfs.ko").write_bytes(b"bad kernel module")
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            spec.build(self.output, self.revision, self.drivers)

    def test_preserve_additional_pinned_offline_dependencies(self):
        dependencies = {
            "dev-python/pyparsing/pyparsing-3.3.3-1.gpkg.tar": "dev-python/pyparsing-3.3.3",
            "sys-kernel/asahi-sources/asahi-sources-7.0.9_p2-1.gpkg.tar": "sys-kernel/asahi-sources-7.0.9_p2",
            "app-alternatives/bc/bc-0-1.gpkg.tar": "app-alternatives/bc-0",
            "sys-devel/bc/bc-1.08.2-1.gpkg.tar": "sys-devel/bc-1.08.2",
        }
        for path, cpv in dependencies.items():
            self.files[f"binpkgs/{path}"] = f"package {cpv}".encode()
            self.files["binpkgs/Packages"] += f"\n\nCPV: {cpv}\nPATH: {path}\nUSE: ".encode()
        bundle = self.make_spec().build(self.output, self.revision, self.drivers)[-1]
        with tarfile.open(self.output / f"native-{bundle}.tar.gz") as packed:
            index = packed.extractfile("binpkgs/Packages").read()
            for path, cpv in dependencies.items():
                self.assertIn(f"CPV: {cpv}\nPATH: {path}".encode(), index)
                self.assertEqual(packed.extractfile(f"binpkgs/{path}").read(), f"package {cpv}".encode())

    def test_refuse_incomplete_and_target_bound_native_payload(self):
        self.index(missing="media-libs/mesa")
        with self.assertRaisesRegex(ValueError, "Missing native binary packages"):
            self.make_spec().build(self.output, self.revision, self.drivers)
        self.index()
        self.files["binpkgs/Packages"] = self.files["binpkgs/Packages"].replace(b"video_cards_asahi ", b"")
        with self.assertRaisesRegex(ValueError, "video_cards_asahi"):
            self.make_spec().build(self.output, self.revision, self.drivers)
        self.index()
        self.files[self.initramfs] = self.initrd(**{"var/lib/dracut/hooks/pre-mount/20-ordo-usb.sh": b"stale"})
        with self.assertRaisesRegex(ValueError, "portable"):
            self.make_spec().build(self.output, self.revision, self.drivers)

    def test_require_dart_transitive_dependencies_and_module_indices(self):
        for path in ("kernel/drivers/apple-dart.ko", "kernel/drivers/iova.ko", "modules.alias.bin"):
            with self.subTest(path=path), self.assertRaisesRegex(ValueError, path):
                self.files[self.initramfs] = self.initrd(omit=path)
                self.make_spec().build(self.output, self.revision, self.drivers)


class NativeDiscoveryTest(unittest.TestCase):
    def test_publication_uses_only_tracked_pin_and_rejects_incomplete_media(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / "ORDOINNER/native"
            tracked = root / "config/native-release.sha256"
            self.assertIsNone(published_native([source], tracked))
            source.mkdir(parents=True)
            with self.assertRaisesRegex(ValueError, "no published release pin"):
                published_native([source], tracked)
            data = f"{'a' * 64}  stage/boot/vmlinuz-7.0.9-asahi-2-ordo-agx\n".encode()
            manifest = source / "native.sha256"
            digest = hashlib.sha256(data).hexdigest()
            tracked.parent.mkdir()
            tracked.write_text(digest + "\n")
            with self.assertRaises(FileNotFoundError):
                published_native([source], tracked)
            manifest.write_bytes(data)
            self.assertEqual(published_native([source], tracked), NativePayload(manifest, digest))
            cache = root / ".local/m2-native-release"
            cache.mkdir(parents=True)
            cached = cache / "native.sha256"
            cached.write_bytes(data)
            self.assertEqual(published_native([cache, source], tracked), NativePayload(cached, digest))
            manifest.write_bytes(data.replace(b"7.0.9", b"7.0.8"))
            (source / "native-release.sha256").write_text(hashlib.sha256(manifest.read_bytes()).hexdigest() + "\n")
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                published_native([cache, source], tracked)
            with self.assertRaisesRegex(ValueError, "published native release is missing"):
                published_native([root / "missing"], tracked)


if __name__ == "__main__":
    unittest.main()
