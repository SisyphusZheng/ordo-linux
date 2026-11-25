from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "dev/release"))
import macos_install as app


class DeviceTest(unittest.TestCase):
    def setUp(self):
        self.device = dict(DeviceIdentifier="disk71", Size=128_000_000_000, MediaName="USB",
                           WholeDisk=True, Internal=False, VirtualOrPhysical="Physical", BusProtocol="USB", Writable=True)

    def test_target_requires_a_physical_external_whole_usb_disk(self):
        self.assertIsNotNone(app.external_identity(self.device, 1234))
        for key, value in (("Internal", True), ("VirtualOrPhysical", "Virtual"), ("BusProtocol", "PCI"),
                           ("WholeDisk", False), ("Size", 1024), ("Writable", False), ("DeviceIdentifier", "/dev/disk1")):
            with self.subTest(key=key):
                self.assertIsNone(app.external_identity(dict(self.device, **{key: value}), 1234))

    @patch.object(app, "info")
    @patch.object(app.subprocess, "run")
    def test_raw_firmware_never_reads_external_or_wrong_partition(self, run, info):
        part = {"DeviceIdentifier": "disk0s4"}
        base = dict(part, Internal=True, ParentWholeDisk="disk0", Content="EFI", WholeDisk=False,
                    Size=500170752, DiskUUID="fixture")
        for changes in ({"Internal": False}, {"ParentWholeDisk": "disk1"}, {"Content": "Apple_APFS"},
                        {"Size": 10**12}, {"WholeDisk": True}, {"DiskUUID": ""}):
            info.return_value = dict(base, **changes)
            with self.assertRaises(ValueError):
                app.raw_firmware(part, "disk0", Path("/unused"))
        run.assert_not_called()

    @patch.object(app, "candidate_disks")
    def test_replug_aborts_even_on_same_identifier_and_model(self, candidates):
        old = app.external_identity(self.device, 1234)
        candidates.return_value = {"disk71": app.external_identity(self.device, 5678)}
        with self.assertRaises(ValueError):
            app.same_disk(Path("/candidate"), old)

    @patch.object(app, "info")
    @patch.object(app, "media_ids")
    @patch.object(app, "disks")
    def test_deny_apfs_and_active_installer(self, disks, identifiers, info):
        identifiers.return_value = {"disk71": 17}
        info.return_value = self.device
        for part in ({"Content": "Apple_APFS"}, {"Content": "Microsoft Basic Data", "MountPoint": "/Volumes/Kit"}):
            disks.return_value = [{"DeviceIdentifier": "disk71", "Partitions": [part]}]
            self.assertEqual(app.candidate_disks(Path("/Volumes/Kit/Ordo")), {})


if __name__ == "__main__":
    unittest.main()
