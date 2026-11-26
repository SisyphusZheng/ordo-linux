#!/usr/bin/env python3
"""P1-03：固件「源文件名 → 驱动请求名」映射必须一处定义、四处共用。

回归的是三个真实故障：
  1. 只把 Apple 固件包里的源文件名放进 initramfs —— brcmfmac 按板型后缀请求，一条都命中不了；
  2. build / boot-sync / verify 各写一份名字清单 —— 改一处就漏两处；
  3. 别名各存一份几 MB 的固件 —— initramfs 体积翻倍。
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "dev/m2"))
import build  # noqa: E402

PLATFORM = REPO / "config/platform/m2"
BASE = "brcm/brcmfmac4387c2-pcie.apple,hokkaido"
# serial.log:289-294 里内核实际按这个顺序请求（全部 failed with error -2）
SUFFIXES = ["-TPHN-u-4.7-X2", "-TPHN-u-4.7", "-TPHN-u", "-TPHN", "-X2", ""]


def newc_entries(blob):
    """解析 archive() 生成的 newc，返回 {name: (mode, data)}。"""
    index, entries = 0, {}
    while index + 110 <= len(blob):
        header = blob[index:index + 110]
        assert header[:6] == b"070701", header[:6]
        mode = int(header[14:22], 16)
        size = int(header[54:62], 16)
        name_size = int(header[94:102], 16)
        name = blob[index + 110:index + 110 + name_size].rstrip(b"\0")
        start = index + 110 + name_size
        start += (-start) % 4
        entries[name] = (mode, blob[start:start + size])
        start += size
        index = start + (-start) % 4
    return entries


def mapping_contract():
    mapping = build.firmware_map()
    for extension in (".bin", ".txt", ".clm_blob", ".txcap_blob"):
        source = BASE + extension
        assert mapping[source] == [BASE + suffix + extension for suffix in SUFFIXES], source
    for source, targets in mapping.items():
        assert len(set(targets)) == len(targets), f"重复请求名：{source}"
        assert targets[0].rsplit("/", 1)[0] == source.rsplit("/", 1)[0], source
        # 「必须另有请求名」只约束 Wi-Fi（brcmfmac）：内核按板型后缀链请求，
        # 源名不在链上，映射缺失时整条链路 -2。蓝牙（brcmbt）由 hci_bcm4377
        # 直接请求源名，target == source 本身就是合法映射，故不在此断言范围内。
        if source.startswith("brcm/brcmfmac"):
            assert any(target != source for target in targets), f"{source} 没有请求名映射"
    # 蓝牙沿用源文件名：请求名与源名一致也是合法映射，但必须显式登记
    assert "brcm/brcmbt4387c2-apple,hokkaido-u.bin" in mapping
    return mapping


def archive_contract():
    entries = newc_entries(build.archive({
        "usr/lib/firmware/brcm/real.bin": b"firmware",
        "usr/lib/firmware/brcm/alias.bin": build.Symlink("real.bin"),
    }))
    assert entries[b"usr/lib/firmware/brcm/real.bin"] == (0o100755, b"firmware")
    mode, data = entries[b"usr/lib/firmware/brcm/alias.bin"]
    assert mode == 0o120777 and data == b"real.bin", (oct(mode), data)


def wireless_firmware_contract(mapping):
    """build.py 只按映射取文件：真实副本 + 别名链接。"""
    with tempfile.TemporaryDirectory(prefix="fw-") as raw:
        tmp = Path(raw)
        vendor = tmp / "firmware.cpio"
        names = list(mapping)
        with (vendor).open("wb") as out:
            subprocess.run(["bsdtar", "-cf", str(vendor), "--format=newc", "-C", str(tmp), "vendorfw"],
                           check=False, stdout=out) if False else None
        (tmp / "vendorfw/brcm").mkdir(parents=True)
        for source in names:
            (tmp / "vendorfw" / source).write_bytes(b"data:" + source.encode())
        subprocess.run(["bsdtar", "-cf", str(vendor), "--format=newc", "-C", str(tmp), "vendorfw"], check=True)
        files, links = build.wireless_firmware(vendor)
        for source, targets in mapping.items():
            assert files[targets[0]] == b"data:" + source.encode(), source
            for alias in targets[1:]:
                assert links[alias] == targets[0], alias
        assert set(files) & set(links) == set()


def boot_sync_contract(mapping):
    """boot-sync.sh 用同一张表：请求名副本 + 别名符号链接 + 清单行。"""
    with tempfile.TemporaryDirectory(prefix="boot-fw-") as raw:
        tmp = Path(raw)
        root = tmp / "be"
        firmware = root / "lib/firmware"
        for source in mapping:
            path = firmware / "vendorfw" / source
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"fw:" + source.encode())
        # Apple 固件包解包在 vendorfw/ 下：boot-sync 对 apple/* 也走 vendorfw 前缀。
        (firmware / "vendorfw/apple").mkdir(parents=True, exist_ok=True)
        (firmware / "vendorfw/apple/tpmtfw-j413.bin").write_bytes(b"touch")
        (firmware / "regulatory.db").write_bytes(b"db")
        (firmware / "regulatory.db.p7s").write_bytes(b"sig")
        bins = tmp / "bin"
        bins.mkdir()
        # BSD install 没有 -D；这里换成等价的两步，逻辑仍然由被测脚本执行
        stub = bins / "install"
        stub.write_text('#!/bin/sh\nmkdir -p "${3%/*}" || exit 1\ncp "$2" "$3"\n')
        stub.chmod(0o755)
        dest = tmp / "dest"
        script = f'. "{PLATFORM}/boot-sync.sh"; m2_boot_firmware "{dest}"'
        out = subprocess.check_output(["sh", "-c", script], text=True, env={
            "PATH": f"{bins}:{os.environ['PATH']}", "ORDO_ROOT": str(REPO),
            "M2_BOOT_ROOT": str(root),
        })
        rows = dict(reversed(row.split("  ", 1)) for row in out.splitlines())
        for source, targets in mapping.items():
            primary = targets[0]
            assert (dest / primary).read_bytes() == b"fw:" + source.encode(), primary
            assert rows[f"usr/lib/firmware/{primary}"] != ""
            for alias in targets[1:]:
                link = dest / alias
                assert link.is_symlink(), f"{alias} 必须是符号链接（不能复制一份固件）"
                assert os.readlink(link) == primary.rsplit("/", 1)[-1], alias
                assert rows[f"usr/lib/firmware/{alias}"] == f"symlink:{primary.rsplit('/', 1)[-1]}"
        # 无板型后缀的源名正是内核后缀链的最后一环，所以它本身也是请求名：
        # 允许出现在 dest，但只能是别名符号链接，不能再落第二份固件副本。
        source_alias = dest / list(mapping)[0]
        assert source_alias.is_symlink(), "源文件名只能作为符号链接出现（不能是固件副本）"
        # boot-sync.py 必须认得 symlink 行，否则升级内核时会把别名判成缺失
        source = (PLATFORM / "boot-sync.py").read_text()
        assert 'startswith("symlink:")' in source and "symlinks[name]" in source


def verify_contract(mapping):
    """verify-hardware.sh 按请求名核对，缺一个就红。"""
    text = (PLATFORM / "verify-hardware.sh").read_text()
    start = text.index("firmware_ready() {")
    body = text[start:text.index("\nwireless() {", start)]
    with tempfile.TemporaryDirectory(prefix="verify-fw-") as raw:
        tmp = Path(raw)
        mapfile = tmp / "wireless-firmware"
        mapfile.write_text((PLATFORM / "wireless-firmware").read_text())
        lib = tmp / "lib/firmware"
        for source, targets in mapping.items():
            for wanted in targets:
                path = lib / "vendorfw" / wanted
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"fw")
        # 脚本里的候选路径不带引号（for 列表），按裸路径替换到临时映射表。
        body = body.replace("/opt/ordo/config/platform/m2/wireless-firmware", str(mapfile))
        body = body.replace("/etc/ordo/wireless-firmware", str(mapfile))
        body = body.replace('"/lib/firmware/', f'"{lib}/')
        script = f"set -u\n{body}\nfirmware_ready"
        assert subprocess.run(["sh", "-c", script]).returncode == 0
        (lib / "vendorfw" / mapping["brcm/brcmfmac4387c2-pcie.apple,hokkaido.bin"][2]).unlink()
        assert subprocess.run(["sh", "-c", script], capture_output=True).returncode == 1


def consumers_share_one_table():
    mapping = build.firmware_map()
    assert len(mapping) > 0
    for consumer in ("dev/m2/build.py", "config/platform/m2/boot-sync.sh",
                     "config/platform/m2/verify-hardware.sh"):
        text = (REPO / consumer).read_text()
        assert "wireless-firmware" in text, consumer
    # install-external.sh 也必须按表补齐 vendorfw，而不是各自维护名字
    install = (PLATFORM / "install-external.sh").read_text()
    assert "link_vendorfw()" in install and "wireless-firmware" in install
    target = install.index("link_vendorfw\n")
    assert install.index('tar -xzf "$BOOT_MOUNT/desktop-@BUNDLE_SHA@.tar.gz" -C "$TARGET/opt/ordo"') < target


mapping = mapping_contract()
archive_contract()
wireless_firmware_contract(mapping)
boot_sync_contract(mapping)
verify_contract(mapping)
consumers_share_one_table()
print("P1-03 firmware mapping: ok")
