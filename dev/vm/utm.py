#!/usr/bin/env python3
"""Write an importable Apple Silicon UTM QEMU bundle configuration."""
import argparse
from pathlib import Path
import plistlib
import secrets
import uuid


DISK_NAME = "Ordo.qcow2"


def configuration(version):
    mac = "02:" + ":".join(f"{byte:02x}" for byte in secrets.token_bytes(5))
    return {
        "ConfigurationVersion": 4,
        "Backend": "QEMU",
        "Information": {
            "Name": f"Ordo Linux {version} (ARM64)",
            "UUID": str(uuid.uuid4()),
            "IconCustom": False,
        },
        "System": {
            "Architecture": "aarch64",
            "Target": "virt",
            "CPU": "default",
            "CPUCount": 4,
            "CPUFlagsAdd": [],
            "CPUFlagsRemove": [],
            "ForceMulticore": False,
            "MemorySize": 4096,
            "JITCacheSize": 0,
        },
        "QEMU": {
            "DebugLog": False,
            "UEFIBoot": True,
            "Hypervisor": True,
            "RNGDevice": True,
            "BalloonDevice": False,
            "TPMDevice": False,
            "RTCLocalTime": False,
            "PS2Controller": False,
            "AdditionalArguments": [],
        },
        "Input": {"UsbBusSupport": "3.0", "UsbSharing": False, "MaximumUsbShare": 0},
        "Sharing": {
            "DirectoryShareMode": "None",
            "DirectoryShareReadOnly": True,
            "ClipboardSharing": False,
        },
        "Display": [
            {
                "Hardware": "virtio-ramfb-gl",
                "DynamicResolution": False,
                "UpscalingFilter": "Linear",
                "DownscalingFilter": "Linear",
                "NativeResolution": False,
            }
        ],
        "Drive": [
            {
                "Identifier": str(uuid.uuid4()),
                "ImageName": DISK_NAME,
                "ImageType": "Disk",
                "Interface": "VirtIO",
                "InterfaceVersion": 1,
                "ReadOnly": False,
            }
        ],
        "Network": [
            {
                "Mode": "Emulated",
                "Hardware": "virtio-net-pci",
                "MacAddress": mac,
                "IsolateFromHost": False,
                "PortForward": [],
            }
        ],
        "Serial": [],
        "Sound": [{"Hardware": "intel-hda"}],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    if args.bundle.suffix != ".utm":
        parser.error("bundle name must end in .utm")
    disk = args.bundle / "Data" / DISK_NAME
    if not disk.is_file() or disk.is_symlink():
        parser.error(f"bundle is missing its local drive {disk}")
    with (args.bundle / "config.plist").open("xb") as out:
        plistlib.dump(configuration(args.version), out, sort_keys=False)


if __name__ == "__main__":
    main()
