"""Upgrade and rollback on a directory standing in for the M2 external ESP."""
import hashlib
import importlib.util
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import sys

PLATFORM = Path("config/platform/m2").resolve()
sys.path[:0] = [str(PLATFORM), "dev/m2"]
spec = importlib.util.spec_from_file_location("boot_sync", PLATFORM / "boot-sync.py")
boot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(boot)
from build import archive
from system_uki import build_recovery_uki
from uki import Uki


def write_uki(path, payloads):
    sections = {".text": b"efi stub", **payloads}
    data = bytearray(1024 + len(sections) * 512)
    data[:2] = b"MZ"
    pe = 128
    optional = pe + 24
    struct.pack_into("<I", data, 60, pe)
    struct.pack_into("<4sHHIIIHH", data, pe, b"PE\0\0", 0xaa64, len(sections), 0, 0, 0, 240, 0x22)
    struct.pack_into("<H", data, optional, 0x20b)
    struct.pack_into("<II", data, optional + 16, 0x1000, 0x1000)
    struct.pack_into("<QII", data, optional + 24, 0, 4096, 512)
    struct.pack_into("<II", data, optional + 56, (1 + len(sections)) * 4096, 1024)
    struct.pack_into("<H", data, optional + 68, 10)
    struct.pack_into("<I", data, optional + 108, 16)
    for n, (label, payload) in enumerate(sections.items()):
        raw = 1024 + n * 512
        struct.pack_into("<8sIIIIIIHHI", data, optional + 240 + n * 40, label.encode(),
                         len(payload), (n + 1) * 4096, 512, raw, 0, 0, 0, 0, 0x40000040)
        data[raw:raw + len(payload)] = payload
    path.write_bytes(data)


def kernel(tag):
    return b"MZ" + bytes(54) + b"ARMd" + tag


class BootSyncTest(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.base = Path(scratch.name)
        self.esp = self.base / "esp"
        for folder in ("EFI/BOOT", "EFI/Ordo", "extlinux", "ordo-kernel"):
            (self.esp / folder).mkdir(parents=True)
        self.default = self.esp / "EFI/BOOT/BOOTAA64.EFI"
        self.zbm = self.esp / "EFI/Ordo/ZFSBootMenu.EFI"
        self.zbm.write_bytes(b"recovery")
        self.old_kernel = kernel(b"old")
        self.old_initrd = b"old image"
        write_uki(self.default, {".cmdline": b"root=zfs:AUTO ro",
                                 ".osrel": b"ID=ordo\n", ".splash": b"Ordo",
                                 ".linux": self.old_kernel, ".initrd": self.old_initrd})
        self.old_uki = self.default.read_bytes()
        self.config = self.esp / "extlinux/extlinux.conf"
        self.old_config = (b"DEFAULT ordo\nLABEL ordo\n"
                           b"  KERNEL /ordo-kernel/vmlinuz\n  INITRD /ordo-kernel/initramfs.img\n"
                           b"  APPEND root=zfs:AUTO ro\nLABEL ordo-manual\n  KERNEL /live/vmlinuz-asahi\n")
        self.config.write_bytes(self.old_config)
        self.system = self.esp / "extlinux/ordo-system.conf"
        self.system.write_bytes(self.old_config)
        (self.esp / "extlinux/ordo-manual.conf").write_bytes(b"manual")
        (self.esp / "ordo-kernel/vmlinuz").write_bytes(self.old_kernel)
        (self.esp / "ordo-kernel/initramfs.img").write_bytes(self.old_initrd)
        self.kernel = self.base / "vmlinuz"
        self.kernel.write_bytes(kernel(b"new"))
        self.initrd = self.base / "initramfs.img"
        self.initrd.write_bytes(b"new image")
        if not (shutil.which("aarch64-elf-objcopy") or shutil.which("aarch64-linux-gnu-objcopy") or
                (shutil.which("objcopy") and b"pei-aarch64-little" in subprocess.check_output(["objcopy", "--info"]))):
            def replace_uki(image, replacement, target, _work):
                values = {name: image.read(name) for name in image.sections if name != ".text"}
                values.update({name: path if isinstance(path, bytes) else path.read_bytes()
                               for name, path in replacement.items()})
                write_uki(target, values)
            patch_uki = patch.object(Uki, "replace", replace_uki)
            patch_uki.start()
            self.addCleanup(patch_uki.stop)

    def test_portable_recovery_retains_boot_payload_and_appends_compressed_firmware(self):
        if not shutil.which("zstd"):
            self.skipTest("zstd is unavailable")
        overlay = archive({"etc/hostid": b"\x01\x02\x03\x04", "usr/lib/firmware/mock": b"firmware"})
        recovery = self.base / "recovery.efi"
        recovery.write_bytes(build_recovery_uki(self.default, overlay))
        uki = Uki(recovery)
        self.assertEqual(uki.read(".linux"), self.old_kernel)
        self.assertEqual(uki.read(".cmdline"), b"root=zfs:AUTO ro")
        initrd = uki.read(".initrd")
        self.assertTrue(initrd.startswith(self.old_initrd))
        self.assertEqual(subprocess.check_output(["zstd", "-dc"], input=initrd[len(self.old_initrd):]), overlay)

    def test_upgrade_and_rollback_keep_paired_boot_entries(self):
        boot.publish(self.esp, self.kernel, self.initrd, None)
        self.assertTrue(Uki(self.default).matches(".linux", self.kernel))
        self.assertTrue(Uki(self.default).matches(".initrd", self.initrd))
        self.assertEqual(Uki(self.default).read(".splash"), b"Ordo")
        self.assertEqual((self.esp / "EFI/Ordo/Previous.EFI").read_bytes(), self.old_uki)
        self.assertEqual((self.esp / "extlinux/ordo-previous.conf").read_bytes(), self.old_config)
        self.assertEqual(self.system.read_bytes(), self.config.read_bytes())
        self.assertIn(b"LABEL ordo-manual\n  KERNEL /live/vmlinuz-asahi\n", self.config.read_bytes())
        self.assertEqual(self.zbm.read_bytes(), b"recovery")
        for line in self.config.read_text().splitlines():
            if "ordo-kernel/" in line:
                path = self.esp / line.split()[1].lstrip("/")
                self.assertEqual(path.read_bytes(),
                                 self.kernel.read_bytes() if "KERNEL " in line else self.initrd.read_bytes())

        upgraded = self.default.read_bytes()
        boot.publish(self.esp, self.kernel, self.initrd, None)
        self.assertEqual(self.default.read_bytes(), upgraded)
        self.assertEqual((self.esp / "EFI/Ordo/Previous.EFI").read_bytes(), self.old_uki)
        self.kernel.write_bytes(self.old_kernel)
        self.initrd.write_bytes(self.old_initrd)
        real_run = subprocess.run
        with patch.object(boot.subprocess, "run", wraps=real_run) as calls:
            def check_call(args, **opts):
                if args[0] == "zpool":
                    self.assertTrue(Uki(self.default).matches(".linux", self.kernel))
                    self.assertTrue(Uki(self.default).matches(".initrd", self.initrd))
                    return subprocess.CompletedProcess(args, 0)
                return real_run(args, **opts)

            calls.side_effect = check_call
            with patch.object(Uki, "replace", side_effect=AssertionError("previous UKI should be reused")):
                boot.publish(self.esp, self.kernel, self.initrd, ("rpool", "rpool/root/ordo", "rpool/root/ordo-rb"))
            calls.assert_any_call(["zpool", "set", "bootfs=rpool/root/ordo-rb", "rpool"], check=True)

        self.assertEqual((self.esp / "EFI/Ordo/Previous.EFI").read_bytes(), upgraded)
        self.assertEqual(self.default.read_bytes(), self.old_uki)
        self.assertEqual(self.config.read_bytes(), self.old_config)

    def test_failed_bootfs_switch_restores_all_active_files(self):
        real_run = subprocess.run
        def run(args, **opts):
            if args[0] == "zpool":
                if "bootfs=rpool/root/ordo-rb" in args:
                    raise subprocess.CalledProcessError(1, args)
                return subprocess.CompletedProcess(args, 0)
            return real_run(args, **opts)

        with patch.object(boot.subprocess, "run", side_effect=run) as calls:
            with self.assertRaises(subprocess.CalledProcessError):
                boot.publish(self.esp, self.kernel, self.initrd, ("rpool", "rpool/root/ordo", "rpool/root/ordo-rb"))
        calls.assert_any_call(["zpool", "set", "bootfs=rpool/root/ordo", "rpool"], check=True)
        self.assertEqual(self.default.read_bytes(), self.old_uki)
        self.assertEqual(self.config.read_bytes(), self.old_config)
        self.assertEqual(self.system.read_bytes(), self.old_config)
        self.assertEqual(self.zbm.read_bytes(), b"recovery")

    def test_failure_during_extlinux_write_restores_default_uki(self):
        replace = boot.replace
        failed = False

        def replace_once(source, target):
            nonlocal failed
            if target == self.config and not failed:
                failed = True
                raise OSError("failed extlinux write")
            replace(source, target)

        with patch.object(boot, "replace", side_effect=replace_once):
            with self.assertRaises(OSError):
                boot.publish(self.esp, self.kernel, self.initrd, None)
        self.assertEqual(self.default.read_bytes(), self.old_uki)
        self.assertEqual(self.config.read_bytes(), self.old_config)
        self.assertEqual(self.system.read_bytes(), self.old_config)

    def test_reject_non_arm_kernel_before_any_boot_files_change(self):
        self.kernel.write_bytes(b"wrong kernel")
        digest = hashlib.sha256(self.default.read_bytes()).hexdigest()
        with self.assertRaises(ValueError):
            boot.publish(self.esp, self.kernel, self.initrd, None)
        self.assertEqual(hashlib.sha256(self.default.read_bytes()).hexdigest(), digest)
        self.assertEqual(self.config.read_bytes(), self.old_config)

    @unittest.skipUnless(shutil.which("zstd"), "zstd required for initramfs fixture")
    def test_initramfs_uses_last_overlay_and_matches_usb_root_and_zfs(self):
        root = "e8bc6950-afc6-45b7-a829-2d943f3ee224"
        release = "7.0.9-asahi-2"
        module = f"usr/lib/modules/{release}/extra/zfs.ko"
        wait = "var/lib/dracut/hooks/pre-mount/20-ordo-usb.sh"
        cpio = archive({module: b"old-zfs"}) + archive({module: b"new-zfs", wait: f"part=/dev/disk/by-partuuid/{root}\n".encode()})
        self.initrd.write_bytes(subprocess.check_output(["zstd", "-qc"], input=cpio))
        def modinfo(args, **_opts):
            self.assertEqual(Path(args[-1]).read_bytes(), b"new-zfs")
            return "2.4.4\n"
        with patch.object(boot.subprocess, "check_output", side_effect=modinfo):
            boot.verify_initramfs(self.initrd, release, root, "2.4.4")
            for bad in ((release, "wrong-partition", "2.4.4"), (release, root, "3.0"),
                        ("7.0.10-asahi", root, "2.4.4")):
                with self.assertRaises(ValueError):
                    boot.verify_initramfs(self.initrd, *bad)


    @unittest.skipUnless(shutil.which("zstd"), "zstd required for initramfs fixture")
    def test_native_initramfs_preserves_exact_firmware_and_early_drivers(self):
        root = "e8bc6950-afc6-45b7-a829-2d943f3ee224"
        release = "7.0.10-asahi-1-ordo-agx"
        module_root = f"usr/lib/modules/{release}/"
        wait = "var/lib/dracut/hooks/pre-mount/20-ordo-usb.sh"
        required_firmware = {
            "usr/lib/firmware/apple/tpmtfw-j413.bin": b"touch",
            "usr/lib/firmware/brcm/brcmfmac4387c2-pcie.apple,hokkaido.bin": b"wifi",
            "usr/lib/firmware/regulatory.db": b"signed data",
            "usr/lib/firmware/regulatory.db.p7s": b"detached signature",
        }
        firmware = self.base / "firmware.sha256"
        firmware.write_text("".join(f"{hashlib.sha256(data).hexdigest()}  {name}\n"
                                    for name, data in required_firmware.items()))
        parts = {
            module_root + "extra/zfs.ko": b"zfs",
            module_root + "kernel/drivers/gpu/drm/apple/appledrm.ko": b"panel",
            module_root + "kernel/drivers/gpu/drm/asahi/asahi.ko": b"GPU",
            module_root + "kernel/drivers/net/wireless/broadcom/brcmfmac.ko": b"Wi-Fi",
            module_root + "kernel/drivers/iommu/apple-dart.ko": b"USB IOMMU",
            module_root + "modules.dep.bin": b"dependency index",
            module_root + "modules.alias.bin": b"alias index",
            wait: f"part=/dev/disk/by-partuuid/{root}\n".encode(),
            **required_firmware,
        }
        self.initrd.write_bytes(subprocess.check_output(["zstd", "-qc"], input=archive(parts)))
        drivers = ("asahi.ko", "appledrm.ko.zst", "brcmfmac.ko", "kernel/drivers/iommu/apple-dart.ko")
        run = subprocess.check_output
        with patch.object(boot.subprocess, "check_output", return_value="2.4.4\n"):
            boot.verify_initramfs(self.initrd, release, root, "2.4.4", firmware, drivers)
            with self.assertRaisesRegex(ValueError, "hci_bcm4377"):
                boot.verify_initramfs(self.initrd, release, root, "2.4.4", firmware, (*drivers, "hci_bcm4377.ko"))
            without_dart = {name: data for name, data in parts.items() if not name.endswith("/apple-dart.ko")}
            self.initrd.write_bytes(run(["zstd", "-qc"], input=archive(without_dart)))
            with self.assertRaisesRegex(ValueError, "apple-dart"):
                boot.verify_initramfs(self.initrd, release, root, "2.4.4", firmware, drivers)
            without_aliases = {name: data for name, data in parts.items() if not name.endswith("/modules.alias.bin")}
            self.initrd.write_bytes(run(["zstd", "-qc"], input=archive(without_aliases)))
            with self.assertRaisesRegex(ValueError, "modules.alias.bin"):
                boot.verify_initramfs(self.initrd, release, root, "2.4.4", firmware, drivers)
            overridden = archive(parts) + archive({"usr/lib/firmware/regulatory.db.p7s": b"wrong signature"})
            self.initrd.write_bytes(run(["zstd", "-qc"], input=overridden))
            with self.assertRaisesRegex(ValueError, "regulatory.db.p7s"):
                boot.verify_initramfs(self.initrd, release, root, "2.4.4", firmware, drivers)


if __name__ == "__main__":
    unittest.main()
