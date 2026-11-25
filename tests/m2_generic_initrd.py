import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "dev/m2"))
from build import archive
from portable_boot import generic_archive


class BootArchiveTest(unittest.TestCase):
    def test_repeated_identity_removed_from_each_member(self):
        first = archive({"etc/hostid": b"1234", "init": b"init!"})
        second = archive({"./etc/hostid": b"5678", "etc/zfs/zpool.cache": b"private pool"})
        result = generic_archive(first + bytes(32) + second)
        self.assertEqual(result, generic_archive(result))
        self.assertEqual(result.count(b"TRAILER!!!"), 2)
        self.assertIn(b"init!", result)
        for field in (b"hostid", b"zpool.cache", b"private pool", b"5678", b"1234"):
            self.assertNotIn(field, result)

    def test_personalized_firmware_fails_closed(self):
        with self.assertRaises(ValueError):
            generic_archive(archive({"usr/lib/firmware/vendorfw/apple/file.bin": b"data"}))

    def test_truncated_or_unsafe_member_rejected(self):
        for blob in (archive({"a": b"A"})[:-40], archive({"../outside": b"A"})):
            with self.assertRaises(ValueError):
                generic_archive(blob)


if __name__ == "__main__":
    unittest.main()
