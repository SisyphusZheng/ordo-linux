#!/usr/bin/env python3
"""P2-11（M2 侧）：内核版本与 ebuild 名不得写死在安装器和构建器里。

旧状态：install-external.sh 三处写死 7.0.9-asahi-2 与 luciole-0.1.0.ebuild，
dev/m2/build.py 另有两处；升级 Luciole 或换内核要同时改多个文件且必然漏。
现在唯一来源是 config/platform/m2/payload.sha256（内核）与 overlay 里实际存在的 ebuild。
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
PLATFORM = REPO / "config/platform/m2"
sys.path.insert(0, str(REPO / "dev/m2"))
import build  # noqa: E402

PINNED = "7.0.9-asahi-2"


def installer_is_parameterized():
    engine = (PLATFORM / "install-external.sh").read_text()
    assert PINNED not in engine, "安装器仍有写死的内核版本"
    assert "luciole-0.1.0.ebuild" not in engine, "安装器仍有写死的 ebuild 名"
    assert "KERNEL_RELEASE='@KERNEL_RELEASE@'" in engine
    for derived in ('"kernel/vmlinuz-$KERNEL_RELEASE"', '"$TARGET/lib/modules/$KERNEL_RELEASE"',
                    'vmlinuz-$KERNEL_RELEASE'):
        assert derived in engine, derived
    assert '"$luciole"/*.ebuild' in engine


def build_derives_release():
    source = (REPO / "dev/m2/build.py").read_text()
    assert PINNED not in source, "build.py 仍有写死的内核版本"
    assert build.legacy_release() == PINNED

    with tempfile.TemporaryDirectory(prefix="m2-release-") as raw:
        platform = Path(raw)
        (platform / "payload.sha256").write_text(
            f"{'a' * 64}  kernel/vmlinuz-6.0-asahi-1\n"
            f"{'b' * 64}  kernel/vmlinuz-7.0-asahi-1\n")
        with patch.object(build, "PLATFORM", platform):
            try:
                build.legacy_release()
            except ValueError as error:
                assert "exactly one kernel" in str(error)
            else:
                raise AssertionError("两个内核候选时必须拒绝猜")
        (platform / "payload.sha256").write_text(
            f"{'a' * 64}  kernel/vmlinuz-8.1-asahi-3\n"
            f"{'b' * 64}  kernel/vmlinuz-asahi.EFI\n")
        with patch.object(build, "PLATFORM", platform):
            assert build.legacy_release() == "8.1-asahi-3"


def build_derives_ebuild():
    with tempfile.TemporaryDirectory(prefix="m2-ebuild-") as raw:
        repo = Path(raw)
        folder = repo / "overlay/gui-apps/luciole"
        folder.mkdir(parents=True)
        (folder / "luciole-9.9.9.ebuild").write_text("EAPI=8\n")
        with patch.object(build, "REPO", repo):
            assert build.luciole_ebuild() == "luciole-9.9.9.ebuild"
        (folder / "luciole-10.0.0.ebuild").write_text("EAPI=8\n")
        with patch.object(build, "REPO", repo):
            try:
                build.luciole_ebuild()
            except ValueError as error:
                assert "exactly one ebuild" in str(error)
            else:
                raise AssertionError("多个 ebuild 时必须拒绝猜")
    assert (REPO / "overlay/gui-apps/luciole" / build.luciole_ebuild()).is_file()


def shipped_payload_matches_pin():
    """载荷清单是唯一来源：介质上的内核文件名必须与它一致。"""
    payload = (PLATFORM / "payload.sha256").read_text().splitlines()
    kernels = [line.split("  ", 1)[1] for line in payload
               if line.split("  ", 1)[1].startswith("kernel/vmlinuz-")
               and not line.endswith(".EFI")]
    assert kernels == [f"kernel/vmlinuz-{PINNED}"], kernels
    assert build.payload_manifest(False)["kernel/vmlinuz-" + PINNED]


def dev_tools_derive_release():
    """dev/m2 的重建工具也不得再写死内核版本（P2-11 M2 侧）。"""
    display = (REPO / "dev/m2/display/rebuild.sh").read_text()
    assert PINNED not in display, "display/rebuild.sh 仍写死内核版本"
    assert "payload.sha256" in display and "ORDO_PAYLOAD_MANIFEST" in display
    power = (REPO / "dev/m2/power/rebuild.sh").read_text()
    assert PINNED not in power, "power/rebuild.sh 仍写死内核版本"
    assert "include/config/kernel.release" in power

    # 两个内核 pin 时必须拒绝猜（而不是挑一个继续跑）。
    with tempfile.TemporaryDirectory(prefix="m2-display-") as raw:
        tmp = Path(raw)
        kernel = tmp / "kernel"
        (kernel / "arch/arm64/boot").mkdir(parents=True)
        (kernel / "arch/arm64/boot/Image").write_bytes(b"image")
        base = tmp / "modules.tar.gz"
        base.write_bytes(b"modules")
        manifest = tmp / "manifest"
        manifest.write_text(
            f"{'a' * 64}  kernel/vmlinuz-6.0-asahi-1\n"
            f"{'b' * 64}  kernel/vmlinuz-7.0-asahi-1\n")
        result = subprocess.run(
            ["sh", str(REPO / "dev/m2/display/rebuild.sh"),
             str(kernel), str(base), str(tmp / "out.tar.gz")],
            env={**os.environ, "ORDO_PAYLOAD_MANIFEST": str(manifest)},
            capture_output=True, text=True)
        assert result.returncode == 1, result
        assert "唯一内核" in result.stderr, result.stderr

    # VM 装配器同样不得钉死 ebuild 名：升级只换 overlay 里的文件名（A5）。
    vm = (REPO / "dev/vm/configure-root.sh").read_text()
    assert "luciole-0.1.0.ebuild" not in vm, "VM 装配器仍写死 ebuild 名"
    assert "*.ebuild" in vm, "VM 装配器必须按 glob 取 ebuild"

    # vermagic 版本从调用者的内核树读取；没有 kernel.release 必须报错，不能猜。
    with tempfile.TemporaryDirectory(prefix="m2-power-") as raw:
        tmp = Path(raw)
        kernel = tmp / "kernel"
        kernel.mkdir()
        result = subprocess.run(
            ["sh", str(REPO / "dev/m2/power/rebuild.sh"), str(kernel), str(tmp / "out.ko")],
            capture_output=True, text=True)
        assert result.returncode == 1, result
        assert "kernel.release" in result.stderr, result.stderr


if __name__ == "__main__":
    installer_is_parameterized()
    build_derives_release()
    build_derives_ebuild()
    shipped_payload_matches_pin()
    dev_tools_derive_release()
    print("P2-11 m2 parameterization: ok")
