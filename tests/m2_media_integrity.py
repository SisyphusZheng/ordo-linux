#!/usr/bin/env python3
"""P1-01：交付介质的完整性断言。

回归的是“手工拼装”的四类事故：
  1. 6.8 GB rootfs 分片在解包前不核哈希（分片被改写也照铺进新池）；
  2. EFI/BOOT/BOOTAA64.EFI 写完不读回，NVRAM 又失败时机器无引导；
  3. modules.dep 索引了树里已经不存在的 .ko；
  4. ESP 上留着手工备份与无入口的代目录却没人发现。

这些断言全部在临时目录里跑，不碰 /Volumes、不挂载、不写盘。
"""
import hashlib
import io
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

REPO = Path(__file__).resolve().parents[1]
PLATFORM = REPO / "config/platform/m2"
sys.path.insert(0, str(REPO / "dev/m2"))
import build  # noqa: E402

GATE = "(cd \"$PAYLOAD\" && sha256sum -c -) <<'ORDO_ROOTFS_HASHES'"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def manifest_contract():
    rows = dict(reversed(line.split("  ", 1)) for line in (PLATFORM / "payload.sha256").read_text().splitlines())
    shards = [name for name in rows if name.startswith("rootfs.tar.gz.part")]
    assert len(shards) == 4, shards
    for layout in (False, True):
        digests = build.payload_manifest(layout)
        missing = set(shards) - set(digests)
        assert not missing, f"{'USB' if layout else 'live'} 布局缺少分片哈希：{missing}"


def gate_contract():
    engine = (PLATFORM / "install-external.sh").read_text()
    assert GATE in engine, "rootfs 分片哈希门禁缺失"
    start = engine.index(GATE)
    end = engine.index("\nORDO_ROOTFS_HASHES\n", start) + len("\nORDO_ROOTFS_HASHES\n")
    block = engine[start:end]
    # 必须在任何破坏性写入之前：wipefs 一旦跑过，坏分片已经无法挽回
    for destructive in ("wipefs -a", "zpool create", "tar -xz"):
        assert start < engine.index(destructive), destructive
    assert "@ROOTFS_HASHES@" in block

    shards = {f"rootfs.tar.gz.part0{index}": f"shard-{index}".encode() for index in range(4)}
    with tempfile.TemporaryDirectory(prefix="m2-hash-") as raw:
        payload = Path(raw)
        for name, data in shards.items():
            (payload / name).write_bytes(data)
        lines = "\n".join(f"{sha(data)}  {name}" for name, data in shards.items())
        script = ('die() { printf "%s\\n" "$*" >&2; exit 1; }\n'
                  + block.replace("@ROOTFS_HASHES@", lines) + "\nexit 0\n")
        env = {"PAYLOAD": str(payload), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
        ok = subprocess.run(["sh", "-c", script], env=env, capture_output=True)
        assert ok.returncode == 0, ok.stderr.decode()

        # 分片被改写（长度不变）也必须被抓住
        (payload / "rootfs.tar.gz.part02").write_bytes(b"shard-9")
        bad = subprocess.run(["sh", "-c", script], env=env, capture_output=True)
        assert bad.returncode == 1, bad
        assert "rootfs 分片校验失败" in bad.stderr.decode()


def boot_fallback_contract():
    engine = (PLATFORM / "install-external.sh").read_text()
    install = engine.index('mv -f "$BOOT_MOUNT/EFI/BOOT/ORDO.NEW" "$BOOT_MOUNT/EFI/BOOT/BOOTAA64.EFI"')
    readback = engine.index('cmp -s "$BOOT_MOUNT/EFI/BOOT/BOOTAA64.EFI"', install)
    assert readback > install, "写默认引导后必须读回校验"
    assert engine.index("sync", readback) > readback


def display_index_contract():
    """install-display.sh 必须按实际成员重建 modules.dep。"""
    with tempfile.TemporaryDirectory(prefix="m2-display-") as raw:
        tmp = Path(raw)
        tree = tmp / "modules"
        (tree / "extra").mkdir(parents=True)
        (tree / "extra/zfs.ko").write_bytes(b"zfs")
        for module in ("keep", "builtin"):
            folder = tree / "kernel/drivers" / module
            folder.mkdir(parents=True)
            (folder / f"{module}.ko").write_bytes(module.encode())
        (tree / "modules.builtin").write_text("kernel/drivers/builtin/builtin.ko\n")
        index = tree / "modules.dep"
        index.write_text("\n".join([
            "kernel/drivers/keep/keep.ko: ",
            "kernel/drivers/builtin/builtin.ko: ",
            "kernel/drivers/gone/gone.ko: ",
        ]) + "\n")
        overlay = tmp / "modules.tar.gz"
        with tarfile.open(overlay, "w:gz") as archive:
            data = b"kernel/drivers/keep/keep.ko: \n"
            member = tarfile.TarInfo("modules.dep")
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))
        (tree / "modules.dep").write_text("\n".join([
            "kernel/drivers/keep/keep.ko: ",
            "kernel/drivers/builtin/builtin.ko: ",
            "kernel/drivers/gone/gone.ko: ",
        ]) + "\n")
        result = subprocess.run(["sh", str(PLATFORM / "install-display.sh"), tree, overlay],
                                capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        assert index.read_text() == "kernel/drivers/keep/keep.ko: \n", index.read_text()
        assert "移除 2 条失效路径" in result.stderr


def media_check_contract():
    def run(esp):
        return subprocess.run([sys.executable, "-B", str(REPO / "dev/m2/media-check.py"), str(esp)],
                              capture_output=True, text=True)

    with tempfile.TemporaryDirectory(prefix="m2-media-") as raw:
        esp = Path(raw) / "esp"
        generation = "a" * 24
        (esp / "EFI/BOOT").mkdir(parents=True)
        (esp / "EFI/BOOT/BOOTAA64.EFI").write_bytes(b"efi")
        (esp / "extlinux").mkdir()
        (esp / "extlinux/extlinux.conf").write_text(
            "LABEL ordo\n"
            f"  KERNEL /ordo-kernel/ordo-{generation}/vmlinuz\n"
            f"  INITRD /ordo-kernel/ordo-{generation}/initramfs.img\n")
        module = esp / "ordo-kernel" / f"ordo-{generation}"
        (module / "kernel").mkdir(parents=True)
        (module / "vmlinuz").write_bytes(b"kernel")
        (module / "initramfs.img").write_bytes(b"initrd")
        (module / "kernel/ok.ko").write_bytes(b"ok")
        (module / "modules.dep").write_text("kernel/ok.ko: \n")
        assert run(esp).returncode == 0, run(esp).stderr

        (module / "modules.dep").write_text("kernel/ok.ko: \nkernel/dead.ko: \n")
        result = run(esp)
        assert result.returncode == 1 and "不存在的模块" in result.stderr
        (module / "modules.dep").write_text("kernel/ok.ko: \n")

        (esp / "EFI/Ordo").mkdir()
        (esp / "EFI/Ordo/Previous.EFI.before-native").write_bytes(b"old")
        result = run(esp)
        assert result.returncode == 1 and "无入口的手工备份" in result.stderr
        (esp / "EFI/Ordo/Previous.EFI.before-native").unlink()

        (esp / "ordo-kernel" / ("ordo-" + "b" * 24)).mkdir()
        result = run(esp)
        assert result.returncode == 1 and "没有 extlinux 入口" in result.stderr
        (esp / "ordo-kernel" / ("ordo-" + "b" * 24)).rmdir()

        (esp / "EFI/BOOT/BOOTAA64.EFI").unlink()
        result = run(esp)
        assert result.returncode == 1 and "BOOTAA64" in result.stderr

        assert run(Path(raw) / "nope").returncode == 2


manifest_contract()
gate_contract()
boot_fallback_contract()
display_index_contract()
media_check_contract()
print("P1-01 media integrity: ok")
