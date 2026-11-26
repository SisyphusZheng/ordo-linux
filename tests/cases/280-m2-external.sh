#!/bin/sh
set -eu
cd "$(dirname "$(readlink -f "$0")")/../.."
PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import gzip, hashlib, io, sys, tarfile, tempfile, tomllib, uuid
from unittest.mock import patch
from pathlib import Path
sys.path.insert(0, "dev/m2")
from build import build, bundle, PLATFORM, archive, luciole_ebuild
from brand_boot import brand, PAYLOAD_OFFSET
from boot_art import LOGO_MAGIC
# Preserve every byte of stage 2, including all device trees and U-Boot.
original = bytes(PAYLOAD_OFFSET) + bytes.fromhex("d00dfeed") + b"test bundle"
try:
    brand(original)
except ValueError:
    pass
else:
    raise AssertionError("Unrecognized m1n1 bundle accepted")
with patch("brand_boot.SOURCE_SHA", hashlib.sha256(original).hexdigest()), patch("brand_boot.m1n1_logo", return_value=LOGO_MAGIC):
    assert brand(original) == original[:PAYLOAD_OFFSET] + LOGO_MAGIC + original[PAYLOAD_OFFSET:]
a = bundle()
assert a == bundle()
with tarfile.open(fileobj=io.BytesIO(gzip.decompress(a))) as t:
    def read(name):
        return t.extractfile(name).read()
    cfg = tomllib.loads((read("config/desktop/greetd/config.toml") + read("config/desktop/greetd/first-boot.toml")).decode())
    assert cfg["initial_session"] == {"user":"ordo", "command":"/usr/local/bin/ordo-umbriel-session"}
    with tarfile.open(fileobj=io.BytesIO(read("dev/m2/display/modules.tar.gz"))) as overlay:
        builtins = overlay.extractfile("modules.builtin").read().splitlines()
        kms = b"kernel/drivers/gpu/drm/drm_kms_helper.ko"
        assert kms in builtins
        deps = overlay.extractfile("modules.dep").read().splitlines()
        apple, = [line for line in deps if line.startswith(b"kernel/drivers/gpu/drm/apple/appledrm.ko:")]
        assert kms not in apple.split() and overlay.getmember("kernel/drivers/gpu/drm/apple/appledrm.ko").size
    env = read("config/desktop/ordo-session-env")
    assert b'WLR_RENDERER_ALLOW_SOFTWARE:-1' in env
    assert cfg["general"]["runfile"] == "/home/.ordo/greetd-first-session"
    for name in ["scripts/ordo-snap","scripts/ordo-config","scripts/sysup",
                 "scripts/ordo-build-manifest","config/desktop/ordo-session-env"]:
        assert t.getmember(name).mode & 0o111
    assert b"zfs_arc_max" in read("config/zfs-arc.start")
    assert read("config/desktop/wallpapers/wallpaper-blackhole.png").startswith(b"\x89PNG")
with tarfile.open(fileobj=io.BytesIO(gzip.decompress(bundle(include_legacy=False)))) as portable:
    world = portable.extractfile("config/platform/m2/world").read().splitlines()
    # B6：M2 没有可用的 ppd 后端，电源档位面板随 D2-2 关闭；world.usb 不得再声明它。
    assert b"sys-apps/i2c-tools" in world
    assert b"sys-power/power-profiles-daemon" not in world
    assert "dev/m2/display/modules.tar.gz" not in portable.getnames()
    luciole = "overlay/gui-apps/luciole"
    for file in ("Manifest", luciole_ebuild()):
        path = f"{luciole}/{file}"
        assert portable.extractfile(path).read() == Path(path).read_bytes()
engine = (PLATFORM / "install-external.sh").read_text()
for entry in ("install-external.sh", "launcher", "preflight"):
    assert "512 GB" not in (PLATFORM / entry).read_text(), entry
assert "root=zfs:AUTO" in engine and "root=ZFS=rpool/root/ordo" not in engine
assert engine.index("sha256sum -c") < engine.index("wipefs -a")
assert "sh /opt/ordo/config/platform/m2/first-desktop.sh" in engine
assert "sh /opt/ordo/scripts/ordo-config apply world" in engine
assert engine.index('for file in "$luciole"/Manifest "$luciole"/*.ebuild') < engine.index('chroot "$TARGET" /bin/sh /opt/ordo/config/platform/m2/install-native.sh')
assert engine.index('install -Dm755 "$greeter/greetd.initd" "$TARGET/etc/init.d/greetd"') < engine.index("sh /opt/ordo/config/platform/m2/first-desktop.sh")
password = engine[engine.index('say "为本机的 ordo 账户设置密码'):engine.index("say \"6/7 内核")]
assert password.index('mount --bind /dev "$TARGET/dev"') < password.index('chroot "$TARGET" passwd ordo')
assert password.index('chroot "$TARGET" passwd ordo') < password.index('umount "$TARGET/dev"')
cpio = archive({"init":b"hello"})
assert cpio.startswith(b"070701") and len(cpio) % 4 == 0
size = int(cpio[54:62], 16)
name_end = 110 + int(cpio[94:102], 16)
assert cpio[110:name_end] == b"init\0"
start = (name_end + 3) & ~3
assert cpio[start:start + size] == b"hello"
assert b"TRAILER!!!\0" in cpio[start+size:]
# Both installer names must receive the same image on every subsequent rebuild.
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    platform = tmp / "platform"
    platform.mkdir()
    for path in PLATFORM.iterdir():
        if path.name != "payload.sha256" and path.is_file():
            (platform / path.name).symlink_to(path.resolve())
    (tmp / "barefiles.tar.gz").write_bytes(b"fixture")
    _shards = "".join(f"{hashlib.sha256(b'fixture').hexdigest()}  rootfs.tar.gz.part0{i}\n" for i in range(4))
    (platform / "payload.sha256").write_text(f"{hashlib.sha256(b'fixture').hexdigest()}  barefiles.tar.gz\n"
                                            f"{hashlib.sha256(b'').hexdigest()}  kernel/vmlinuz-7.0.9-asahi-2\n"
                                            + _shards)
    for _i in range(4):
        (tmp / f"rootfs.tar.gz.part0{_i}").write_bytes(b"fixture")
    base = tmp / "base"
    base.write_bytes(b"fixture")
    (tmp / "kernel").mkdir()
    (tmp / "kernel/vmlinuz-7.0.9-asahi-2").touch()
    with tarfile.open(tmp / "kernel/modules.tar.gz", "w:gz") as mods:
        mod = tarfile.TarInfo("7.0.9-asahi-2/kernel/drivers/hid/dockchannel-hid/dockchannel-hid.ko")
        mod.size = 8
        mods.addfile(mod, io.BytesIO(b"test-hid"))
        for rel in ["kernel/drivers/gpu/drm/drm_kms_helper.ko", "kernel/drivers/mux/mux-apple-display-crossbar.ko", "kernel/drivers/pwm/pwm-apple.ko", "modules.dep.bin", "modules.alias.bin"]:
            member = tarfile.TarInfo("7.0.9-asahi-2/" + rel)
            member.size = 1
            mods.addfile(member, io.BytesIO(b"x"))
    _map = {}
    for _line in (platform / "wireless-firmware").read_text().splitlines():
        _line = _line.split("#", 1)[0]
        if _line.strip():
            _fields = _line.split()
            _map[_fields[0]] = _fields[1:] or [_fields[0]]
    wireless = ({t[0]: src.encode() for src, t in _map.items()},
                {alias: t[0] for t in _map.values() for alias in t[1:]})
    regulatory = {"regulatory.db": b"test-db", "regulatory.db.p7s": b"test-signature"}
    with patch("build.touch_firmware", return_value=b"j413-test-firmware"), patch("build.wireless_firmware", return_value=wireless), patch("build.regulatory_firmware", return_value=regulatory), \
         patch("build.build_system_uki", return_value=b"direct-efi"), patch("build.update_uki", return_value=b"efi") as zbm, patch("build.PLATFORM", platform), patch("build.bundle", return_value=b"bundle"), \
         patch("build.BASE_SHA", hashlib.sha256(b"fixture").hexdigest()), \
         patch("build.subprocess.check_output", side_effect=lambda cmd, input=b"": input):
        for log_id in (None, uuid.uuid4()):
            stage = tmp / str(log_id)
            build(base, tmp, stage, uuid.uuid4(), uuid.uuid4(), log_id)
            img = (stage / "live/initramfs-external.img").read_bytes()
            assert (root_module := (Path("dev/m2/power/macsmc-power.ko").read_bytes())) in img
            assert next((stage / "live").glob("ordo-*.efi")).read_bytes() == b"direct-efi"
            assert 'cp "$BOOT_MOUNT/live/ordo-@DIRECT_SHA@.efi" "$BOOT_MOUNT/EFI/BOOT/ORDO.NEW"' in engine
            assert 'EFI/Ordo/ZFSBootMenu.EFI' in engine
            assert b"usr/lib/firmware/apple/tpmtfw-j413.bin" in img and b"j413-test-firmware" in img
            assert (b"/ordo-boot-report settled" in next((stage/"live").glob("system-*.img")).read_bytes()) == bool(log_id)
            sysimg = next((stage/"live").glob("system-*.img")).read_bytes()
            manual = (stage / "live/initramfs-live-manual.img").read_bytes()
            for name in [*wireless[0], *regulatory]:
                fw = b"usr/lib/firmware/" + name.encode()
                for boot_image in (img, sysimg, manual, zbm.call_args.args[1]):
                    assert fw + b"\0" in boot_image
                for live_image in (img, manual):
                    assert b"/sysroot/" + fw in live_image
            assert b"usr/lib/modules/7.0.9-asahi-2/kernel/drivers/gpu/drm/drm_kms_helper.ko\0" not in sysimg
            for name in [b"test-hid", b"mux-apple-display-crossbar.ko", b"pwm-apple.ko", b"modules.dep.bin", b"modules.alias.bin"]:
                assert name in sysimg
            drivers = b" ".join((platform / "platform-modules").read_bytes().split())
            assert drivers in img and drivers in sysimg
            assert root_module in next((stage / "live").glob("system-*.img")).read_bytes()
            assert img == (stage / "live/initramfs-512.img").read_bytes()
            assert (b"ordo-save-log" in img) == bool(log_id)
            if log_id:
                assert str(log_id).encode() in img
        root_id = uuid.uuid4()
        def native_fixture(stage, _revision, _drivers):
            release = "7.0.9-asahi-2-ordo-agx"
            digest = "a" * 64
            kernel = stage / "live" / f"vmlinuz-{release}-{digest}"
            kernel.write_bytes(b"native kernel")
            return release, kernel, digest, b"portable native initramfs", "b" * 64
        class NativeFixture:
            build = staticmethod(native_fixture)
        stage = tmp / "native"
        build(base, tmp, stage, uuid.uuid4(), root_id, native=NativeFixture())
        native_initrd = next((stage / "live").glob("system-*.img")).read_bytes()
        live_initrd = (stage / "live/initramfs-external.img").read_bytes()
        assert native_initrd.startswith(b"portable native initramfs")
        assert f"/dev/disk/by-partuuid/{root_id}".encode() in native_initrd
        assert b"usbroot" not in native_initrd
        assert root_module not in native_initrd and root_module in live_initrd
        assert b"KERNEL_RELEASE='7.0.9-asahi-2-ordo-agx'" in live_initrd
        assert (b"NATIVE_SHA='" + b"b" * 64 + b"'") in live_initrd
        boot_id = uuid.uuid4()
        stage = tmp / "usb"
        (tmp / "image.squashfs").write_bytes(b"test live")
        live_sha = hashlib.sha256(b"test live").hexdigest()
        with (patch("build.build_recovery_uki", return_value=b"recovery-efi") as usb_zbm,
              patch("build.live_signing_key", return_value=(b"private-fixture", b"public-fixture")),
              patch("build.build_live_uki", return_value=b"live-efi"),
              patch("build.sign_live_efi", return_value=b"live-signature")):
            build(base, tmp, stage, boot_id, root_id, native=NativeFixture(),
                  usb_payload=True, payload_digests={**{f"rootfs.tar.gz.part0{i}": hashlib.sha256(b"fixture").hexdigest()
                                                for i in range(4)}, "image.squashfs": live_sha})
        initial = (stage / "live/initramfs-external.img").read_bytes()
        assert f"payload_boot_id='{boot_id}'".encode() in initial
        assert live_sha.encode() in initial
        assert b"USB_PAYLOAD='1'" in initial
        assert b'cp /etc/hostid /sysroot/ordo-install-hostid' in initial
        assert b"etc/hostid\0" in initial
        assert b"ordo-auto-install\0" in initial and b"public-fixture" in initial
        assert b"private-fixture" not in initial
        assert b"--login-program /ordo-auto-install" in initial
        assert b"etc/hostid\0" in usb_zbm.call_args.args[1]
        assert root_module not in initial and root_module not in usb_zbm.call_args.args[1]
        assert (stage / "live/vmlinuz-asahi").read_bytes() == b"native kernel"
        assert (stage / "EFI/BOOT/BOOTAA64.EFI").read_bytes() == b"live-efi"
        assert (stage / "live/ordo-live.efi.sig").read_bytes() == b"live-signature"
        assert b"etc/hostid\0" in next((stage / "live").glob("system-*.img")).read_bytes()
PY
for script in config/platform/m2/*sh config/platform/m2/launcher config/platform/m2/live-init config/platform/m2/preflight; do
    sh -n "$script"
done
bash -n config/platform/m2/manual-init
python3 tests/m2_external_preflight.py
python3 tests/m2_media_inputs.py
