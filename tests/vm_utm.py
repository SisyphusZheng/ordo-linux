"""Offline regressions for the VM manifest and first-boot identity."""
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
import uuid
from zipfile import ZIP_STORED, ZipFile


ROOT = Path(__file__).resolve().parents[1]
UTM = ROOT / "dev/vm/utm.py"
ZIP_BUNDLE = ROOT / "dev/vm/zip-bundle.py"
FIRSTBOOT = ROOT / "config/platform/utm/firstboot.sh"
CONFIGURE_ROOT = ROOT / "dev/vm/configure-root.sh"
BUILD_DISK = ROOT / "dev/vm/build-disk.sh"


class TestUtm(unittest.TestCase):
    def test_image_configuration_gets_an_installed_system_path(self):
        prelude = CONFIGURE_ROOT.read_text().split("\nrepo=", 1)[0]
        env = {**os.environ, "PATH": "/bin"}
        result = subprocess.check_output(
            ["/bin/sh", "-c", prelude + '\nprintf "%s\\n" "$PATH"'],
            env=env,
            text=True,
        )
        self.assertIn("/usr/local/bin", result.strip().split(":"))
        self.assertIn("/usr/sbin", result.strip().split(":"))

    def test_image_installs_the_pinned_luciole_recipe_and_manifest(self):
        script = CONFIGURE_ROOT.read_text()
        start = script.index('local_repo=$(portageq get_repo_path / local)')
        end = script.index('groupadd -f plugdev', start)
        with tempfile.TemporaryDirectory() as tmp:
            local_repo = Path(tmp) / "local"
            luciole = local_repo / "gui-apps/luciole"
            luciole.mkdir(parents=True)
            _ebuild = next((ROOT / "overlay/gui-apps/luciole").glob("*.ebuild")).name
            (luciole / _ebuild).write_text('LUCIOLE_COMMIT="main"\n')
            prelude = 'set -eu\nportageq() { [ "$*" = "get_repo_path / local" ] && printf "%s\\n" "$local"; }\n'
            subprocess.run(
                ["/bin/sh", "-c", prelude + script[start:end]],
                env={**os.environ, "repo": str(ROOT), "local": str(local_repo)},
                check=True,
            )
            for name in ("Manifest", _ebuild):
                self.assertEqual(
                    (ROOT / "overlay/gui-apps/luciole" / name).read_bytes(),
                    (luciole / name).read_bytes(),
                )

    def test_dracut_gets_file_descriptors_inside_a_private_dev_mount(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "dev").mkdir()
            script = BUILD_DISK.read_text()
            start = script.index('mount -t tmpfs -o nosuid,mode=755 tmpfs "$root/dev"')
            end = script.index('mount -t tmpfs -o nosuid,nodev,mode=755 tmpfs "$root/run"')
            mounts = root / "mounts"
            prelude = 'set -e\nmount() { printf "%s\\n" "$*" >> "$log"; }\n'
            subprocess.run(
                ["bash", "-c", prelude + script[start:end]],
                env={**os.environ, "root": str(root), "log": str(mounts)},
                check=True,
            )
            calls = mounts.read_text().splitlines()
            self.assertEqual(f"-t tmpfs -o nosuid,mode=755 tmpfs {root}/dev", calls[0])
            self.assertIn(f"--bind /dev/zfs {root}/dev/zfs", calls)
            self.assertEqual("/proc/self/fd", os.readlink(root / "dev/fd"))
            self.assertEqual("fd/1", os.readlink(root / "dev/stdout"))

    def test_bundle_contains_only_local_drive_and_no_host_integrations(self):
        with tempfile.TemporaryDirectory() as tmp:
            vm = Path(tmp) / "Ordo Linux 0.1.0 (ARM64).utm"
            nested = vm / "Data"
            nested.mkdir(parents=True)
            args = [sys.executable, str(UTM), str(vm), "--version", "0.1.0"]
            self.assertNotEqual(0, subprocess.run(args, capture_output=True).returncode)
            disk = nested / "Ordo.qcow2"
            disk.touch()
            subprocess.run(args, check=True)
            self.assertEqual({"config.plist", "Data"}, {f.name for f in vm.iterdir()})
            self.assertEqual({"Ordo.qcow2"}, {f.name for f in nested.iterdir()})
            with (vm / "config.plist").open("rb") as f:
                config = plistlib.load(f)
            self.assertEqual(4, config["ConfigurationVersion"])
            self.assertEqual("QEMU", config["Backend"])
            self.assertEqual("aarch64", config["System"]["Architecture"])
            # P1-07：virtio-ramfb 没有 virgl（cap sets: 0），虚拟机只能落到 pixman。
            self.assertEqual("virtio-ramfb-gl", config["Display"][0]["Hardware"])
            uuid.UUID(config["Information"]["UUID"])
            uuid.UUID(config["Drive"][0]["Identifier"])
            self.assertEqual(disk.name, config["Drive"][0]["ImageName"])
            self.assertTrue(config["QEMU"]["UEFIBoot"])
            self.assertEqual([], config["Network"][0]["PortForward"])
            self.assertEqual([], config["QEMU"]["AdditionalArguments"])
            self.assertEqual("None", config["Sharing"]["DirectoryShareMode"])
            self.assertFalse(config["Sharing"]["ClipboardSharing"])
            self.assertFalse(config["Input"]["UsbSharing"])
            self.assertNotEqual(0, subprocess.run(args, capture_output=True).returncode)

    def test_finder_zip_keeps_the_verified_qcow_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            vm = folder / "Ordo.utm"
            cfg = vm / "config.plist"
            disk = vm / "Data/Ordo.qcow2"
            disk.parent.mkdir(parents=True)
            cfg.write_bytes(b"UTM test configuration")
            disk.write_bytes(b"QCOW2 disk fixture")
            output = folder / "Ordo.utm.zip"
            args = [sys.executable, str(ZIP_BUNDLE), str(vm), str(output), "--qcow2-sha256"]
            result = subprocess.run(args + ["0" * 64], capture_output=True)
            self.assertNotEqual(0, result.returncode)
            self.assertFalse(output.exists())
            self.assertFalse((folder / "UTM-SHA256SUMS").exists())
            digest = hashlib.sha256(disk.read_bytes()).hexdigest()
            subprocess.run(args + [digest], check=True)
            zip_digest = hashlib.sha256(output.read_bytes()).hexdigest()
            self.assertEqual(
                f"{zip_digest}  {output.name}\n",
                (folder / "UTM-SHA256SUMS").read_text(),
            )
            with ZipFile(output) as archive:
                self.assertEqual(
                    {"Ordo.utm/config.plist", "Ordo.utm/Data/Ordo.qcow2"},
                    set(archive.namelist()),
                )
                self.assertEqual(ZIP_STORED, archive.getinfo("Ordo.utm/Data/Ordo.qcow2").compress_type)
                self.assertEqual(disk.read_bytes(), archive.read("Ordo.utm/Data/Ordo.qcow2"))

    def test_firstboot_leaves_a_new_identity_and_requires_local_password(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp)
            identity = fake / "machine-id"
            tty = fake / "tty1"
            tty.touch()
            status = fake / "status"
            status.write_text("L\n")
            program = fake / "firstboot"
            program.write_text(
                FIRSTBOOT.read_text()
                .replace("/etc/.machine-id.XXXXXX", str(fake / ".machine-id.XXXXXX"))
                .replace("/etc/machine-id", str(identity))
                .replace("/dev/tty1", str(tty))
            )
            commands = {
                "dbus-uuidgen": 'printf "%s\\n" "$TEST_ID"',
                "chvt": '[ "$#" = 1 ] && [ "$1" = 1 ]',
                "setsid": '[ "$1 $2 $3 $4" = "--ctty --wait passwd ordo" ] && exec passwd ordo',
                "passwd": (
                    'if [ "$1" = -S ]; then printf "ordo %s\\n" "$(cat "$TEST_STATUS")"; '
                    'elif [ ! -e "$TEST_RETRY" ]; then touch "$TEST_RETRY"; exit 1; '
                    'else printf "P\\n" > "$TEST_STATUS"; fi'
                ),
            }
            for name, body in commands.items():
                path = fake / name
                path.write_text("#!/bin/sh\n" + body + "\n")
                path.chmod(0o755)
            env = {
                **os.environ,
                "PATH": str(fake) + os.pathsep + os.environ["PATH"],
                "TEST_ID": uuid.uuid4().hex,
                "TEST_STATUS": str(status),
                "TEST_RETRY": str(fake / "retried"),
            }
            subprocess.run(["sh", str(program)], env=env, check=True)
            original_id = identity.read_text()
            self.assertEqual(env["TEST_ID"], original_id.strip())
            self.assertEqual("P\n", status.read_text())
            self.assertIn("Try again", tty.read_text())
            tty.write_text("")
            env["TEST_ID"] = uuid.uuid4().hex
            subprocess.run(["sh", str(program)], env=env, check=True)
            self.assertEqual(original_id, identity.read_text())
            self.assertEqual("", tty.read_text())


if __name__ == "__main__":
    unittest.main()
