"""Build the removable-media EFI entry from the installed kernel and initramfs."""
from pathlib import Path
import subprocess
import sys
import tempfile

from boot_art import splash

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "config/platform/m2"))
from uki import Uki

CMDLINE = b"root=zfs:AUTO ro console=tty0 loglevel=4 firmware_class.path=/lib/firmware/vendorfw"
OSREL = b'ID=ordo\nNAME="Ordo Linux"\nPRETTY_NAME="Ordo Linux"\n'


def build_system_uki(template, kernel, initrd):
    payloads = {".osrel": OSREL, ".cmdline": CMDLINE, ".splash": splash(), ".linux": kernel, ".initrd": initrd}
    with tempfile.TemporaryDirectory() as folder:
        output = Path(folder) / "ordo.efi"
        Uki(template).replace(payloads, output, folder)
        return output.read_bytes()


def build_live_uki(template, kernel, initrd):
    payloads = {".osrel": b'ID=ordo-live\nNAME="Ordo Linux Installer"\n',
                ".cmdline": b"console=tty0 loglevel=4",
                ".splash": splash(), ".linux": kernel, ".initrd": initrd}
    with tempfile.TemporaryDirectory() as folder:
        output = Path(folder) / "ordo-live.efi"
        Uki(template).replace(payloads, output, folder)
        return output.read_bytes()


def build_recovery_uki(template, overlay):
    image = Uki(template)
    packed = subprocess.check_output(["zstd", "-q", "-3", "-c"], input=overlay)
    with tempfile.TemporaryDirectory() as folder:
        output = Path(folder) / "zbm.efi"
        image.replace({".initrd": image.read(".initrd") + packed}, output, folder)
        return output.read_bytes()
