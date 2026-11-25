"""Interactive macOS entry point for the Mac14,2 external-disk candidate."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from contextlib import contextmanager

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "m2"))
from build import touch_firmware, wireless_firmware
from prepare import info, identify

DISKUTIL = "/usr/sbin/diskutil"
MINIMUM_DISK = 64_000_000_000
ASAHI = "https://asahilinux.org/fedora/"
MODEL = "Mac14,2"


def run_plist(*command):
    return plistlib.loads(subprocess.check_output(command))


def disks(location):
    return run_plist(DISKUTIL, "list", "-plist", location, "physical")["AllDisksAndPartitions"]


def media_ids():
    nodes = run_plist("/usr/sbin/ioreg", "-a", "-r", "-c", "IOMedia")
    return {node["BSD Name"]: node["IORegistryEntryID"] for node in nodes
            if node.get("Whole") and "BSD Name" in node and "IORegistryEntryID" in node}


def external_identity(data, identifier):
    if (not re.fullmatch(r"disk[0-9]+", data.get("DeviceIdentifier", ""))
            or data.get("WholeDisk") is not True or data.get("Internal") is not False
            or data.get("VirtualOrPhysical") != "Physical" or data.get("BusProtocol") != "USB"
            or data.get("Writable") is not True or data.get("Size", 0) < MINIMUM_DISK
            or not identifier):
        return None
    return (data["DeviceIdentifier"], identifier, data["Size"], data.get("MediaName", ""))


def candidate_disks(bundle):
    ids = media_ids()
    choices = {}
    for disk in disks("external"):
        name = disk["DeviceIdentifier"]
        identity = external_identity(info(name), ids.get(name))
        if not identity:
            continue
        parts = disk.get("Partitions", [])
        # APFS can contain the currently running OS, a boot store or a user's backup.
        if any(p.get("Content", "").startswith("Apple") for p in parts) or disk.get("Content", "").startswith("Apple"):
            continue
        mounts = [Path(p["MountPoint"]) for p in [disk, *parts] if p.get("MountPoint")]
        if any(bundle.is_relative_to(mount) for mount in mounts):
            continue
        choices[name] = identity
    return choices


def select_disk(bundle):
    choices = candidate_disks(bundle)
    if not choices:
        raise ValueError("请接入至少 64 GB 的 USB 目标盘。安装器会排除含 Apple 分区或存放本安装包的盘。")
    for name, (_, token, size, model) in choices.items():
        print(f"  {name}   {model}   {size / 1e9:.1f} GB   本次连接编号 {token}")
    chosen = input("输入目标盘名称，如 disk4，或按回车退出：").strip()
    if chosen not in choices:
        raise ValueError("未选择目标盘。")
    return choices[chosen]


def raw_firmware(part, parent, directory):
    dev = part["DeviceIdentifier"]
    data = info(dev)
    if (not re.fullmatch(r"disk[0-9]+s[0-9]+", dev)
            or data.get("DeviceIdentifier") != dev or data.get("Internal") is not True
            or data.get("Content") != "EFI" or data.get("ParentWholeDisk") != parent
            or data.get("WholeDisk") is not False or not data.get("DiskUUID")
            or not 0 < data.get("Size", 0) <= 2 * 1024**3):
        raise ValueError("内部引导分区的标识、类型或容量异常。")
    # Read just the validated partition. The privileged program only emits bytes.
    image = directory / (dev + ".img")
    vendor = directory / (dev + ".cpio")
    try:
        with image.open("xb") as out:
            subprocess.run(["/usr/bin/sudo", "/bin/dd", "if=/dev/r" + dev, "bs=1m"],
                           stdout=out, check=True)
        if image.stat().st_size != data["Size"] or info(dev).get("DiskUUID") != data["DiskUUID"]:
            raise ValueError("读取本机引导分区时设备发生变化。")
        if subprocess.run(["mdir", "-i", image, "::/m1n1/boot.bin"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
            return None
        if subprocess.run(["mcopy", "-i", image, "::/vendorfw/firmware.cpio", vendor],
                          stderr=subprocess.DEVNULL).returncode:
            return None
        return vendor
    finally:
        image.unlink(missing_ok=True)


@contextmanager
def machine_firmware():
    with tempfile.TemporaryDirectory(prefix="ordo-firmware-") as directory:
        with _find_firmware(Path(directory)) as vendor:
            yield vendor


@contextmanager
def _find_firmware(directory):
    mounted_here = []
    found = []
    try:
        for disk in disks("internal"):
            for part in disk.get("Partitions", []):
                if part.get("Content") != "EFI":
                    continue
                dev = part["DeviceIdentifier"]
                mount = info(dev).get("MountPoint")
                if not mount:
                    command = [DISKUTIL, "mount", "readOnly", dev]
                    if subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
                        result = subprocess.run(["/usr/bin/sudo", *command])
                    else:
                        result = None
                    if result is None or result.returncode == 0:
                        mounted_here.append(dev)
                        mount = info(dev).get("MountPoint")
                if mount:
                    path = Path(mount)
                    vendor = path / "vendorfw/firmware.cpio" if (path / "m1n1/boot.bin").is_file() else None
                else:
                    vendor = raw_firmware(part, disk["DeviceIdentifier"], directory)
                if vendor and vendor.is_file():
                    try:
                        touch_firmware(vendor)
                        wireless_firmware(vendor)
                    except (ValueError, subprocess.CalledProcessError):
                        continue
                    found.append(vendor)
        if not found and not any(part.get("Content") == "EFI" for disk in disks("internal")
                                 for part in disk.get("Partitions", [])):
            print("请先为本机建立引导入口。Asahi 官方安装器会在内置盘创建专属启动卷。")
            print("选择 UEFI environment only，按提示在恢复环境认证，然后回到 macOS 再次打开本安装包。")
            if input("输入 UEFI 打开官方安装器，或按回车退出：").strip() == "UEFI":
                with tempfile.TemporaryDirectory() as tmp:
                    bootstrap = Path(tmp) / "asahi.sh"
                    subprocess.run(["/usr/bin/curl", "-fLsS", "--proto", "=https", "--proto-redir", "=https",
                                    "https://alx.sh", "-o", bootstrap], check=True)
                    expected = (Path(__file__).resolve().parents[2] / "config/release/asahi-bootstrap.sha256").read_text().strip()
                    if hashlib.sha256(bootstrap.read_bytes()).hexdigest() != expected:
                        raise ValueError("上游安装入口已更新，请按随包指南核对最新版本。")
                    subprocess.run(["/bin/sh", bootstrap], check=True)
                raise SystemExit("请完成本机引导设置，再从 macOS 重新打开安装包。")
        if len(found) != 1:
            raise ValueError(f"找到 {len(found)} 个与此候选版固件匹配的 Asahi EFI 入口。请查看随包的安装指南，完成本机 UEFI environment only 设置后回到 macOS。{ASAHI}")
        yield found[0]
    finally:
        for device in reversed(mounted_here):
            subprocess.run([DISKUTIL, "unmount", device], check=False)


def volumes(disk):
    layout, = run_plist(DISKUTIL, "list", "-plist", disk)["AllDisksAndPartitions"]
    result = {}
    for part in layout.get("Partitions", []):
        data = info(part["DeviceIdentifier"])
        if data.get("ParentWholeDisk") != disk:
            raise ValueError("磁盘分区所属设备发生变化。")
        if data.get("VolumeName") in ("ORDOPAYLOAD", "ORDOZFS") and data.get("MountPoint"):
            result[data["VolumeName"]] = Path(data["MountPoint"])
    return result


def same_disk(bundle, identity):
    if candidate_disks(bundle).get(identity[0]) != identity:
        raise ValueError("USB 连接或磁盘身份发生变化，请重新启动安装器。")


def target_volumes(bundle, identity):
    name, token, size, model = identity
    current = volumes(name)
    if len(current) == 2:
        identify(current["ORDOPAYLOAD"], current["ORDOZFS"])
        return current
    if current:
        raise ValueError("检测到已有 Ordo 分区，请保留现有系统，改用空白目标盘。")
    print(f"即将清空外接盘 {name}（{model}，{size / 1e9:.1f} GB）上的所有分区和数据。")
    confirmation = f"ERASE {name} {token}"
    if input(f"确定使用这块盘，请完整输入 {confirmation}：").strip() != confirmation:
        raise ValueError("已取消清盘。")
    same_disk(bundle, identity)
    subprocess.run([DISKUTIL, "partitionDisk", "-noEFI", name, "GPT", "%EFI%", "%noformat%",
                    "20G", "ExFAT", "ORDOZFS", "R"], check=True)
    same_disk(bundle, identity)
    layout, = run_plist(DISKUTIL, "list", "-plist", name)["AllDisksAndPartitions"]
    boot, system = layout["Partitions"]
    if (boot.get("Content") != "EFI" or system.get("VolumeName") != "ORDOZFS"
            or not re.fullmatch(re.escape(name) + r"s[0-9]+", boot["DeviceIdentifier"])):
        raise ValueError("分区结果与预期不符，已停止。")
    diskpart = boot["DeviceIdentifier"]
    esp = info(diskpart)
    if esp.get("ParentWholeDisk") != name or esp.get("Content") != "EFI" or not esp.get("DiskUUID"):
        raise ValueError("引导分区身份核验失败。")
    if esp.get("MountPoint"):
        subprocess.run([DISKUTIL, "unmount", diskpart], check=True)
    raw = "/dev/r" + diskpart
    same_disk(bundle, identity)
    if info(diskpart).get("DiskUUID") != esp["DiskUUID"]:
        raise ValueError("引导分区标识发生变化。")
    formatter = ["/sbin/newfs_msdos", "-F", "32", "-v", "ORDOPAYLOAD", raw]
    subprocess.run(formatter if os.access(raw, os.W_OK) else ["/usr/bin/sudo", *formatter], check=True)
    subprocess.run([DISKUTIL, "mount", diskpart], check=True)
    current = volumes(name)
    if len(current) != 2:
        raise ValueError("新建的两个 Ordo 分区未就绪。")
    identify(current["ORDOPAYLOAD"], current["ORDOZFS"])
    return current


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="仅检查机型、介质与发行文件")
    args = parser.parse_args()
    bundle = Path(__file__).resolve().parents[3]
    assets = bundle / "assets"
    pins = json.loads((assets / "pins.json").read_text())
    model = subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.model"], text=True).strip()
    if model != MODEL:
        raise ValueError(f"此安装包面向 {MODEL}，检测到 {model}。")
    for name, path in (("live", "live/initramfs-live.img"), ("payload", "payload.sha256"), ("native", "native/native.sha256")):
        with (assets / path).open("rb") as f:
            if hashlib.file_digest(f, "sha256").hexdigest() != pins[name]:
                raise ValueError(f"发行文件校验失败：{path}")
    if args.check:
        print(f"机型 {model}，发行清单通过。可选择的外接盘：{', '.join(candidate_disks(bundle)) or '无'}")
        return
    for name in ("aarch64-elf-objcopy", "zstd", "mdir", "mcopy", "bsdtar", "openssl"):
        if not shutil.which(name):
            raise ValueError(f"安装包缺少工具 {name}")
    with machine_firmware() as vendor:
        identity = select_disk(bundle)
        same_disk(bundle, identity)
        dest = target_volumes(bundle, identity)
        subprocess.run([sys.executable, str(Path(__file__).resolve().parents[1] / "m2/prepare.py"),
                        "--usb-payload", "--boot-volume", str(dest["ORDOPAYLOAD"]),
                        "--root-volume", str(dest["ORDOZFS"]), "--vendor-cpio", str(vendor),
                        "--base", str(assets / "live/initramfs-live.img"), "--base-sha256", pins["live"],
                        "--payload-manifest", str(assets / "payload.sha256"),
                        "--payload-manifest-sha256", pins["payload"], "--inner", str(assets / "payload"),
                        "--native-manifest", str(assets / "native/native.sha256"),
                        "--native-manifest-sha256", pins["native"], "--binhost", str(assets / "binhost")], check=True)
    print("外接盘已准备好。保持插盘，关机并长按电源键，选择这台 Mac 的 Asahi / Ordo 启动入口。")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, EOFError) as error:
        sys.exit(str(error))
