#!/usr/bin/env python3
"""Build the M2 external installer's boot files in a staging directory."""
import argparse
import gzip
import hashlib
import io
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import uuid

from native_payload import NativePayload, native_args
from power_uki import update_uki
from system_uki import build_live_uki, build_recovery_uki, build_system_uki

REPO = Path(__file__).resolve().parents[2]
PLATFORM = REPO / "config/platform/m2"
BASE_SHA = "2e9c0b1a0e308fcf0447b1b38935457fdad65e8e0081629aed14a8ce1161fec1"


class Symlink(str):
    """A firmware alias stored as a symlink to the real copy (newc S_IFLNK)."""


def archive(files):
    """newc overlay read after the base archive by Linux unpack_to_rootfs."""
    output = bytearray()
    for ino, (name, data) in enumerate([*files.items(), ("TRAILER!!!", b"")], 1):
        link = isinstance(data, Symlink)
        mode = 0o120777 if link else 0o40755 if data is None else 0o100755
        data = str(data).encode() if link else data or b""
        fields = (ino, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(name) + 1, 0)
        output.extend(b"070701" + "".join(f"{field:08x}" for field in fields).encode())
        output.extend(name.encode() + b"\0")
        output.extend(b"\0" * (-len(output) % 4))
        output.extend(data)
        output.extend(b"\0" * (-len(output) % 4))
    return bytes(output)


def bundle(include_legacy=True):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w", format=tarfile.GNU_FORMAT) as tar:
        inputs = sorted(path for path in (REPO / "config/desktop").rglob("*") if path.is_file() and not path.name.startswith("._") and path.name != ".DS_Store")
        # 首启应用清单必须进 /opt/ordo：first-apps.sh 读的是 /opt/ordo/config/apps.d，
        # 没有它 M2 装完就没有浏览器与可视化商店（P1-04）。
        inputs.extend(sorted(path for path in (REPO / "config/apps.d").rglob("*") if path.is_file()))
        inputs.extend(sorted(path for path in (PLATFORM / "package-defaults").rglob("*") if path.is_file()))
        for name in ("config/platform/m2/first-desktop.sh", "config/platform/m2/first-apps.sh",
                     "config/platform/m2/install-display.sh",
                     "config/platform/m2/install-native.sh", "config/platform/m2/install-cli.sh",
                     "config/platform/m2/install-hardware.sh", "config/platform/m2/verify-hardware.sh",
                     "config/platform/m2/speakersafetyd.conf",
                     "config/platform/m2/keyboard-light.sh", "config/platform/m2/world", "config/platform/m2/world.base",
                     "config/platform/m2/package.use",
                     "config/platform/m2/package.accept_keywords", "config/platform/m2/asahi.conf",
                     "config/platform/m2/asahi-revision", "config/platform/m2/kernel.config",
                     "config/platform/m2/repair-barefiles.py", "config/platform/m2/barefiles-ownership.tsv",
                     "config/platform/m2/repair-package-defaults.py", "licenses/GPL-2.0.txt",
                     "config/platform/m2/boot-sync.sh", "config/platform/m2/boot-sync.py", "config/platform/m2/uki.py",
                     "config/platform/m2/early-hardware.sh", "config/platform/m2/wait-usb.sh",
                     "config/platform/m2/platform-modules", "config/platform/m2/wireless-firmware",
                     "config/platform/m2/boot-drivers",
                     "config/dataset", "config/check-build", "config/zfs-arc.start",
                     "config/migrations/1795594673-m2-desktop-environment.sh",
                     "config/migrations/1795601392-m2-package-defaults.sh",
                     "config/migrations/1795627149-remove-gnome-keyring.sh",
                     "config/world", "config/world.sh", "config/world.bare-metal",
                     "config/package.mask/ordo-keyring", "config/package.use/ordo-keyring",
                     "config/package.use/ordo-storage",
                     "config/forbidden-world", "config/oneshot-packages", "version",
                     "scripts/lib.sh", "scripts/ordo-i18n.sh", "scripts/ordo", "scripts/doctor",
                     "scripts/ordo-config", "scripts/ordo-snap", "scripts/ordo-snap-auto",
                     "scripts/ordo-backup", "scripts/ordo-migrate", "scripts/ordo-selfcheck",
                     "scripts/ordo-build-manifest", "scripts/sysup"):
            inputs.append(REPO / name)
        if include_legacy:
            inputs.append(REPO / "dev/m2/display/modules.tar.gz")
        else:
            luciole = REPO / "overlay/gui-apps/luciole"
            inputs.extend([luciole / "Manifest", luciole / luciole_ebuild()])
        inputs.extend(sorted(path for path in (REPO / "overlay/app-crypt/libsecret").rglob("*") if path.is_file()))
        for path in inputs:
            rel = path.relative_to(REPO).as_posix()
            if path.is_symlink():
                raise ValueError(f"Unexpected symlink: {rel}")
            item = tarfile.TarInfo(rel)
            data = path.read_bytes()
            if not include_legacy and path == PLATFORM / "world":
                data += (PLATFORM / "world.usb").read_bytes()
            item.size = len(data)
            item.mode = 0o755 if path.stat().st_mode & 0o111 else 0o644
            tar.addfile(item, io.BytesIO(data))
    return gzip.compress(stream.getvalue(), mtime=0)


def touch_firmware(vendor_cpio):
    blob = subprocess.check_output(["bsdtar", "-xOf", vendor_cpio, "vendorfw/apple/tpmtfw-j413.bin"])
    if hashlib.sha256(blob).hexdigest() != "f06776c81796d4da6cd80efbbb4f773f545c97a6c9ac58a3ea69938e830f6c5d":
        raise ValueError("Unexpected J413 multitouch firmware for the pinned M2 payload")
    return blob


def firmware_map():
    """Parse the shared source -> requested-name table used by all M2 consumers."""
    mapping = {}
    for number, line in enumerate((PLATFORM / "wireless-firmware").read_text().splitlines(), 1):
        line = line.split("#", 1)[0]
        if not line.strip():
            continue
        fields = line.split()
        if len(fields) < 2 or len(set(fields[1:])) != len(fields) - 1:
            raise ValueError(f"Invalid wireless-firmware mapping on line {number}")
        mapping[fields[0]] = fields[1:]
    if not mapping:
        raise ValueError("Empty wireless-firmware mapping")
    return mapping


def wireless_firmware(vendor_cpio):
    """Return ({requested name: data}, {alias: real copy}) from the shared mapping."""
    files, links = {}, {}
    for source, targets in firmware_map().items():
        data = subprocess.check_output(["bsdtar", "-xOf", vendor_cpio, f"vendorfw/{source}"])
        if not data:
            raise ValueError(f"Empty Apple wireless firmware: {source}")
        files[targets[0]] = data
        for alias in targets[1:]:
            links[alias] = targets[0]
    return files, links


def regulatory_firmware(binhost):
    expected, relative = (PLATFORM / "regdb.sha256").read_text().strip().split("  ")
    package = binhost / relative
    with package.open("rb") as source:
        if hashlib.file_digest(source, "sha256").hexdigest() != expected:
            raise ValueError(f"Invalid wireless regulatory package: {package}")
        source.seek(0)
        with tarfile.open(fileobj=source) as pkg:
            image, = (member for member in pkg if member.isfile() and member.name.endswith("/image.tar.zst"))
            compressed = pkg.extractfile(image).read()
    files = {}
    with tarfile.open(fileobj=io.BytesIO(subprocess.check_output(["zstd", "-dc"], input=compressed))) as image:
        for name in ("regulatory.db", "regulatory.db.p7s"):
            member = image.getmember(f"image/lib/firmware/{name}")
            if not member.isfile() or not member.size:
                raise ValueError(f"Invalid wireless regulatory file: {name}")
            files[name] = image.extractfile(member).read()
    return files


def live_signing_key():
    private = subprocess.check_output(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout"])
    public = subprocess.check_output(["openssl", "pkey", "-pubout"], input=private)
    return private, public


def sign_live_efi(key, efi):
    with tempfile.NamedTemporaryFile() as source:
        source.write(key)
        source.flush()
        return subprocess.check_output(["openssl", "dgst", "-sha256", "-sign", source.name, str(efi)])


def payload_args(parser):
    parser.add_argument("--base-sha256", help="Expected SHA-256 of an independently built base initramfs")
    parser.add_argument("--payload-manifest", type=Path, help="Pin an independently built USB payload")
    parser.add_argument("--payload-manifest-sha256", help="Expected SHA-256 of that manifest")


def selected_payload(parser, args):
    if bool(args.payload_manifest) != bool(args.payload_manifest_sha256):
        parser.error("--payload-manifest and --payload-manifest-sha256 must be given together")
    if args.payload_manifest and not args.usb_payload:
        parser.error("--payload-manifest requires --usb-payload")
    if args.base_sha256 and (not args.usb_payload or not re.fullmatch(r"[0-9a-f]{64}", args.base_sha256)):
        parser.error("--base-sha256 requires --usb-payload and a lowercase SHA-256")
    return payload_manifest(args.usb_payload, args.payload_manifest, args.payload_manifest_sha256)


def payload_manifest(usb_payload=False, override=None, expected=None):
    def rows(data):
        entries = {}
        for line in data.decode("ascii").splitlines():
            digest, rel = line.split("  ")
            if not re.fullmatch(r"[0-9a-f]{64}", digest) or rel in entries:
                raise ValueError(f"Invalid payload entry: {rel}")
            entries[rel] = digest
        return entries

    digests = rows((PLATFORM / "payload.sha256").read_bytes())
    if usb_payload:
        digests = {name: digest for name, digest in digests.items()
                   if name == "image.squashfs" or name == "kernel/vmlinuz-asahi.EFI"
                   or re.fullmatch(r"rootfs\.tar\.gz\.part0[0-3]", name)}
    if not override:
        return digests
    if not usb_payload:
        raise ValueError("An independent payload manifest requires the USB payload layout")
    data = override.read_bytes()
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError("USB payload manifest SHA-256 mismatch")
    replacement = rows(data)
    if replacement.keys() != digests.keys():
        raise ValueError("USB payload manifest does not contain the required files")
    return replacement


def legacy_release():
    """Kernel release pinned by the delivered payload manifest (single source)."""
    releases = {name.removeprefix("kernel/vmlinuz-") for name in payload_manifest(False)
                if re.fullmatch(r"kernel/vmlinuz-[^/]+", name) and not name.endswith(".EFI")}
    if len(releases) != 1:
        raise ValueError("payload.sha256 must pin exactly one kernel image")
    return releases.pop()


def luciole_ebuild():
    """Local overlay ebuild name; the version must not be hardcoded in consumers."""
    ebuilds = sorted((REPO / "overlay/gui-apps/luciole").glob("*.ebuild"))
    if len(ebuilds) != 1:
        raise ValueError("overlay/gui-apps/luciole must contain exactly one ebuild")
    return ebuilds[0].name


def build(base, inner, output, boot, root, log_id=None, vendor_cpio=None, binhost=None, native=None,
          usb_payload=False, payload_digests=None, base_sha256=None):
    boot, root = uuid.UUID(str(boot)), uuid.UUID(str(root))
    if boot == root or not boot.int or not root.int:
        raise ValueError("Boot and system PARTUUID must be distinct and nonzero")
    if usb_payload and not native:
        raise ValueError("USB-only media requires a pinned native kernel and packages")
    compressed = base.read_bytes()
    if hashlib.sha256(compressed).hexdigest() != (base_sha256 or BASE_SHA):
        raise ValueError("Unexpected base initramfs")
    payload_digests = payload_digests if payload_digests is not None else payload_manifest(usb_payload)
    for rel, digest in payload_digests.items():
        with (inner / rel).open("rb") as source:
            if hashlib.file_digest(source, "sha256").hexdigest() != digest:
                raise ValueError(f"Invalid M2 payload: {rel}")
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError("Use an empty output directory")
    vendor_cpio = vendor_cpio or Path("/Volumes/EFI - ORDO/vendorfw/firmware.cpio")
    legacy = legacy_release()
    firmware = {"apple/tpmtfw-j413.bin": touch_firmware(vendor_cpio)}
    wireless, links = wireless_firmware(vendor_cpio)
    firmware.update(wireless)
    firmware.update(regulatory_firmware(binhost or base.parent.parent / "binhost"))
    live = output / "live"
    live.mkdir()
    ext = output / "extlinux"
    ext.mkdir()
    data = bundle(include_legacy=not usb_payload)
    digest = hashlib.sha256(data).hexdigest()
    (output / f"desktop-{digest}.tar.gz").write_bytes(data)
    wait = (PLATFORM / "wait-usb.sh").read_text().replace("@ROOT_ID@", str(root))
    module_path = f"usr/lib/modules/{legacy}/kernel/drivers/power/supply/macsmc-power.ko"
    legacy_drivers = {} if usb_payload else {module_path: (REPO / "dev/m2/power/macsmc-power.ko").read_bytes()}
    fwdir = "usr/lib/firmware"
    modules = " ".join((PLATFORM / "platform-modules").read_text().split())
    firmware_files = {
        fwdir: None,
        f"{fwdir}/apple": None,
        f"{fwdir}/brcm": None,
        **{f"{fwdir}/{name}": data for name, data in firmware.items()},
        # 别名只在 initramfs 里做符号链接，避免同一份固件存多份。
        **{f"{fwdir}/{alias}": Symlink(target.rsplit("/", 1)[-1]) for alias, target in links.items()},
    }
    hostid = {}
    if usb_payload:
        # The installer and both EFI paths use the hostid derived for this target.
        value = hashlib.sha256(root.bytes).digest()[:4]
        hostid["etc/hostid"] = value if any(value) else b"\x01\x00\x00\x00"
    driver_overlay = archive({**legacy_drivers, **firmware_files, **hostid})
    recovery_image = inner / "kernel/vmlinuz-asahi.EFI"
    update_recovery = build_recovery_uki if usb_payload else update_uki
    uki = update_recovery(recovery_image, driver_overlay)
    uki_sha = hashlib.sha256(uki).hexdigest()
    (live / f"zbm-{uki_sha}.efi").write_bytes(uki)
    if native:
        required = modules.split() + (PLATFORM / "boot-drivers").read_text().split()
        release, kernel, kernel_sha, packed, native_sha = native.build(
            output, (PLATFORM / "asahi-revision").read_text().strip(), required)
        system = archive({**firmware_files, **hostid})
    else:
        release = legacy
        kernel = inner / f"kernel/vmlinuz-{release}"
        kernel_sha = payload_digests[f"kernel/vmlinuz-{release}"]
        packed = b""
        native_sha = ""
        system = subprocess.check_output(["zstd", "-dc", inner / "kernel/system-asahi.img"])
        # Use the same release tree and binary depmod indices as the working Live
        # environment. Keep the patched power driver last so it wins on unpack.
        prefix = f"usr/lib/modules/{release}/"
        with tarfile.open(REPO / "dev/m2/display/modules.tar.gz", "r:gz") as display:
            corrected = {prefix + item.name: display.extractfile(item).read() for item in display}
        builtins = {prefix + path for path in corrected[prefix + "modules.builtin"].decode().splitlines()}
        with tarfile.open(inner / "kernel/modules.tar.gz", "r|gz") as mods:
            files = {}
            for entry in mods:
                name = "usr/lib/modules/" + entry.name
                if name in builtins or name in corrected:
                    continue
                if entry.isdir():
                    files[name] = None
                elif entry.isfile():
                    files[name] = mods.extractfile(entry).read()
            files.update(corrected)
            system += archive(files)
            del files
        hardware = (PLATFORM / "early-hardware.sh").read_text().replace("@PLATFORM_MODULES@", modules)
        system += archive({"var/lib/dracut/hooks/pre-trigger/15-ordo-m2.sh": hardware.encode()})
        system += driver_overlay

    system += archive({"var/lib/dracut/hooks/pre-mount/20-ordo-usb.sh": wait.encode()})
    if log_id is not None:
        report = (PLATFORM / "boot-report.sh").read_text().replace("@LOG_ID@", str(uuid.UUID(str(log_id))))
        reports = {"ordo-boot-report": report.encode()}
        for hook in ("initqueue/settled", "pre-mount", "pre-pivot", "emergency"):
            phase = hook.split("/")[-1]
            reports[f"var/lib/dracut/hooks/{hook}/85-ordo-report.sh"] = f"/ordo-boot-report {phase}\n".encode()
        system += archive(reports)
    packed += subprocess.check_output(["zstd", "-q", "-3", "-c"], input=system)
    system_sha = hashlib.sha256(packed).hexdigest()
    (live / f"system-{system_sha}.img").write_bytes(packed)
    direct = build_system_uki(inner / "kernel/vmlinuz-asahi.EFI", kernel, packed)
    direct_sha = hashlib.sha256(direct).hexdigest()
    (live / f"ordo-{direct_sha}.efi").write_bytes(direct)
    engine = (PLATFORM / "install-external.sh").read_text().replace("@BUNDLE_SHA@", digest)
    engine = engine.replace("@SYSTEM_SHA@", system_sha).replace("@DIRECT_SHA@", direct_sha)
    engine = engine.replace("@UKI_SHA@", uki_sha).replace("@POWER_MODULE@", module_path)
    engine = engine.replace("@MIN_ROOT_BYTES@", str(int((PLATFORM / "minimum-root-bytes").read_text())))
    engine = engine.replace("@BAREFILES_SHA@", payload_digests.get("barefiles.tar.gz", ""))
    engine = engine.replace("@USB_PAYLOAD@", "1" if usb_payload else "0")
    engine = engine.replace("@PAYLOAD_HASHES@", "\n".join(f"{sha}  {path}" for path, sha in payload_digests.items()))
    engine = engine.replace("@NATIVE_SHA@", native_sha).replace("@KERNEL_SHA@", kernel_sha)
    engine = engine.replace("@KERNEL_RELEASE@", release)
    shards = "\n".join(f"{sha}  {name}" for name, sha in payload_digests.items()
                       if re.fullmatch(r"rootfs\.tar\.gz\.part0[0-3]", name))
    if len(shards.splitlines()) != 4:
        raise ValueError("payload.sha256 must pin the four rootfs shards")
    engine = engine.replace("@ROOTFS_HASHES@", shards)
    if leftover := sorted(set(re.findall(r"@[A-Z][A-Z0-9_]*@", engine))):
        raise ValueError(f"Unsubstituted installer placeholders: {', '.join(leftover)}")
    for block in ("ORDO_PAYLOAD_HASHES", "ORDO_ROOTFS_HASHES", 'NAME="Ordo Linux"'):
        if block not in engine:
            raise ValueError(f"Installer lost the {block} block")
    launch = (PLATFORM / "launcher").read_text().replace("@BOOT_ID@", str(boot)).replace("@ROOT_ID@", str(root))
    manual = (PLATFORM / "manual-init").read_text().replace("@PAYLOAD_BOOT_ID@", str(boot) if usb_payload else "")
    manual = manual.replace("@SQUASHFS_SHA@", payload_digests["image.squashfs"] if usb_payload else "")
    marker = "export CDBOOT=1"
    handoff = (
        f'mkdir -p /sysroot/{fwdir}/apple /sysroot/{fwdir}/brcm || rescue "firmware directories"\n'
        + "".join(f'cp /{fwdir}/{name} /sysroot/{fwdir}/{name} || rescue "missing firmware: {name}"\n'
                  for name in firmware)
        + "".join(f'ln -sfn {target.rsplit("/", 1)[-1]} /sysroot/{fwdir}/{alias}'
                  f' || rescue "missing firmware alias: {alias}"\n'
                  for alias, target in links.items())
    )
    if usb_payload:
        handoff += 'cp /etc/hostid /sysroot/ordo-install-hostid || rescue "missing install hostid"\n'
    else:
        handoff += f'cp /{module_path} /sysroot/ordo-power.ko || rescue "missing power driver"\n'
    live_init = (PLATFORM / "live-init").read_text().replace("@PLATFORM_MODULES@", modules)
    live_init = live_init.replace("@POWER_MODULE@", module_path)
    live_init = live_init.replace("@LIVE_RELEASE@", release if usb_payload else legacy)
    live_init = live_init.replace("@USB_PAYLOAD@", "1" if usb_payload else "0")
    entries = {"ordo-engine":engine, "ordo-launch":launch,
               "ordo-live-init":live_init,
               "ordo-check":(PLATFORM/"preflight").read_text()}
    copies = {"ordo-engine":"/ordo-engine", "ordo-launch":"/usr/bin/ordo-install",
              "ordo-live-init":"/ordo-live-init", "ordo-check":"/etc/local.d/80-ordo-check.start"}
    if usb_payload:
        private_key, public_key = live_signing_key()
        del entries["ordo-check"]
        del copies["ordo-check"]
        entries["ordo-live-efi.pem"] = public_key.decode("ascii")
        entries["ordo-auto-install"] = (PLATFORM / "auto-install.sh").read_text()
        copies["ordo-live-efi.pem"] = "/ordo-live-efi.pem"
        copies["ordo-auto-install"] = "/ordo-auto-install"
    if log_id is not None:
        logger = (PLATFORM / "save-live-log.sh").read_text().replace("@LOG_ID@", str(uuid.UUID(str(log_id))))
        entries["ordo-save-log"] = logger
        copies["ordo-save-log"] = "/etc/local.d/80-ordo-usb.stop"
    if manual.count(marker) != 1 or manual.count("exec switch_root /sysroot /sbin/init") != 1:
        raise ValueError("Missing manual Live handoff")
    setup = "".join(f'cp -p /{src} /sysroot{dst} || rescue "missing {src}"\n' for src,dst in copies.items())
    manual = manual.replace(marker, handoff + marker)
    entries["init"] = manual.replace(marker, setup+marker).replace(
        "exec switch_root /sysroot /sbin/init","exec switch_root /sysroot /ordo-live-init")
    cpio = subprocess.check_output(["zstd","-dc"],input=compressed)
    for name, scripts in [("initramfs-live-manual.img", {"init":manual}), ("initramfs-external.img", entries)]:
        overlay = archive({k:v.encode() for k,v in scripts.items()})
        packed = subprocess.check_output(["zstd","-q","-3","-c"], input=cpio + driver_overlay + overlay)
        (live / name).write_bytes(packed)
    # Earlier M2 boot instructions load this name directly from U-Boot.
    (live / "initramfs-512.img").write_bytes((live / "initramfs-external.img").read_bytes())
    live_kernel = kernel if usb_payload else inner / f"kernel/vmlinuz-{legacy}"
    (live / "vmlinuz-asahi").write_bytes(live_kernel.read_bytes())
    if usb_payload:
        boot_efi = output / "EFI/BOOT/BOOTAA64.EFI"
        boot_efi.parent.mkdir(parents=True)
        boot_efi.write_bytes(build_live_uki(recovery_image, live_kernel, live / "initramfs-external.img"))
        (live / "ordo-live.efi.sig").write_bytes(sign_live_efi(private_key, boot_efi))
    for name in ("extlinux.conf","ordo-manual.conf"):
        (ext/name).write_bytes((PLATFORM/name).read_bytes())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, required=True)
    parser.add_argument("--inner", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--boot-id", type=uuid.UUID, required=True)
    parser.add_argument("--root-id", type=uuid.UUID, required=True)
    parser.add_argument("--log-id", type=uuid.UUID, help="Allow diagnostic logs on this ORDOINNER PARTUUID")
    parser.add_argument("--vendor-cpio", type=Path)
    parser.add_argument("--usb-payload", action="store_true", help="Boot Live using the selected USB boot partition for the full payload")
    payload_args(parser)
    parser.add_argument("--binhost", type=Path, help="Package source for the signed wireless regulatory database")
    native_args(parser)
    args = parser.parse_args()
    build(args.base, args.inner, args.output, args.boot_id, args.root_id, args.log_id, args.vendor_cpio, args.binhost,
          native=NativePayload.from_args(parser, args), usb_payload=args.usb_payload,
          payload_digests=selected_payload(parser, args), base_sha256=args.base_sha256)
