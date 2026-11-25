"""Assemble an explicitly pinned native Asahi build into installation inputs."""
from dataclasses import dataclass
import gzip
import hashlib
from io import BytesIO
from pathlib import Path, PurePosixPath
import re
import subprocess
import tarfile

BOOT_IMAGE = re.compile(r"stage/boot/vmlinuz-([0-9][A-Za-z0-9.+_-]*asahi[A-Za-z0-9.+_-]*)")
MODULE_FILE = re.compile(r"^[A-Za-z0-9_./+-]+$")
GPKG = re.compile(r"binpkgs/[A-Za-z0-9_-]+/(?:[A-Za-z0-9_.+-]+/)?[A-Za-z0-9_.+-]+\.gpkg\.tar")
REQUIRED_PACKAGES = frozenset({
    "sys-fs/zfs",
    "media-libs/mesa",
    "x11-apps/mesa-progs",
    "media-libs/alsa-ucm-conf-asahi",
    "media-libs/asahi-audio",
    "sys-apps/speakersafetyd",
    "media-libs/lsp-plugins",
    "media-video/pipewire",
})
REQUIRED_USE = {
    "media-libs/mesa": {"video_cards_asahi", "vulkan"},
    "x11-apps/mesa-progs": {"gles2", "wayland"},
    "media-video/pipewire": {"extra", "lv2", "sound-server", "v4l"},
    "media-libs/lsp-plugins": {"lv2"},
}


def native_args(parser):
    parser.add_argument("--native-manifest", type=Path, help="Manifest for the optional native Asahi build")
    parser.add_argument("--native-manifest-sha256", help="Expected SHA-256 of the native input manifest")


def read_manifest(path, expected):
    data = path.read_bytes()
    if not re.fullmatch(r"[0-9a-f]{64}", expected) or hashlib.sha256(data).hexdigest() != expected:
        raise ValueError("Native input manifest SHA-256 mismatch")
    entries = {}
    for row in data.decode("ascii").splitlines():
        checksum, name = row.split("  ", 1)
        file = PurePosixPath(name)
        if (not re.fullmatch(r"[0-9a-f]{64}", checksum) or not MODULE_FILE.fullmatch(name)
                or file.is_absolute() or ".." in file.parts or str(file) != name or name in entries):
            raise ValueError(f"Invalid native input manifest entry: {name}")
        entries[name] = checksum
    return entries


def published_native(locations, trusted_pin):
    """Discover a native release without trusting a digest from writable media."""
    present = [source for source in locations if source.exists() or source.is_symlink()]
    if not (present or trusted_pin.exists() or trusted_pin.is_symlink()):
        return None
    if not trusted_pin.is_file():
        raise ValueError("Native input was found but the Ordo repository has no published release pin")
    if not present:
        paths = ", ".join(str(source) for source in locations)
        raise ValueError(f"The published native release is missing ({paths}). Use --native-source to locate it "
                         "or --legacy to choose the original release.")
    expected = trusted_pin.read_text().strip()
    for source in present:
        if not source.is_dir():
            raise ValueError(f"Native release path must be a directory: {source}")
        read_manifest(source / "native.sha256", expected)
    return NativePayload(present[0] / "native.sha256", expected)


def module_name(path):
    return path.rsplit(b"/", 1)[-1].split(b".ko", 1)[0].replace(b"_", b"-")


def boot_module_paths(index, builtins, drivers):
    dependencies = {}
    by_name = {}
    for row in index.splitlines():
        path, separator, rest = row.partition(b":")
        if separator:
            dependencies[path] = rest.split()
            by_name[module_name(path)] = path
    builtin_names = {module_name(path) for path in builtins.splitlines()}
    pending = []
    for driver in drivers:
        name = module_name(driver.encode())
        if name in builtin_names:
            continue
        if name not in by_name:
            raise ValueError(f"Native kernel module index lacks the {driver} boot driver")
        pending.append(by_name[name])
    paths = set()
    while pending:
        path = pending.pop()
        if path in paths:
            continue
        if path not in dependencies:
            raise ValueError(f"Native kernel module index lacks the dependency {path.decode()}")
        paths.add(path)
        pending.extend(dependencies[path])
    return sorted(paths)


@dataclass(frozen=True)
class NativePayload:
    manifest: Path
    expected: str

    @classmethod
    def from_args(cls, parser, args):
        if bool(args.native_manifest) != bool(args.native_manifest_sha256):
            parser.error("--native-manifest and --native-manifest-sha256 must be given together")
        return cls(args.native_manifest, args.native_manifest_sha256) if args.native_manifest else None

    def build(self, output, asahi_revision, boot_drivers):
        entries = read_manifest(self.manifest, self.expected)
        boot = [match for name in entries if (match := BOOT_IMAGE.fullmatch(name))]
        if len(boot) != 1:
            raise ValueError("Native input must name exactly one Asahi kernel")
        kernel = boot[0][0]
        release = boot[0][1]
        initramfs = f"stage/boot/initramfs-{release}.img"
        kernel_config = f"stage/boot/config-{release}"
        modules = f"stage/lib/modules/{release}/"
        index = "binpkgs/Packages"
        repository = "asahi-repo.tar.gz"
        if any(name not in entries for name in (initramfs, index, modules + "modules.dep", repository)):
            raise ValueError("Native input lacks the matching initramfs, module index, package index or Asahi repository")
        module_files = [name for name in entries if name.startswith(modules)]
        for driver in ("zfs", "asahi"):
            if not any(re.search(rf"/{driver}\.ko(?:\.[a-z0-9]+)?$", name) for name in module_files):
                raise ValueError(f"Native input lacks the {driver} kernel module")

        package_files = [name for name in entries if GPKG.fullmatch(name)]
        other = entries.keys() - {kernel, initramfs, kernel_config, index, repository, *module_files, *package_files}
        if other:
            raise ValueError(f"Unexpected native input paths: {', '.join(sorted(other))}")
        root = self.manifest.resolve().parent
        repo_data = self.read_file(root, repository, entries[repository])
        with tarfile.open(fileobj=BytesIO(repo_data), mode="r:gz") as repo:
            if repo.pax_headers.get("comment") != asahi_revision:
                raise ValueError("Native Asahi repository revision differs from the declared revision")
            for item in repo.getmembers():
                path = PurePosixPath(item.name)
                if path.is_absolute() or ".." in path.parts or not (item.isfile() or item.isdir()):
                    raise ValueError(f"Invalid native Asahi repository member: {item.name}")
            try:
                if repo.extractfile("profiles/repo_name").read().strip() != b"asahi":
                    raise ValueError("Native Asahi repository has the wrong name")
                if not repo.getmember("metadata/layout.conf").isfile():
                    raise ValueError("Native Asahi repository metadata is missing")
            except (KeyError, AttributeError) as error:
                raise ValueError("Native Asahi repository metadata is missing") from error
        package_index = self.read_file(root, index, entries[index]).decode("utf-8")
        config_files = [kernel_config] if kernel_config in entries else []
        atoms = {}
        for block in package_index.split("\n\n"):
            meta = dict(line.split(": ", 1) for line in block.splitlines() if ": " in line)
            cpv = meta.get("CPV", "")
            match = re.fullmatch(r"([A-Za-z0-9_-]+/[A-Za-z0-9_+-]+)-[0-9][A-Za-z0-9_.+-]*", cpv)
            if not match or match[1] not in REQUIRED_PACKAGES:
                continue
            path = "binpkgs/" + meta.get("PATH", "")
            if path not in package_files or match[1] in atoms:
                raise ValueError(f"Invalid or duplicate native binary package: {cpv}")
            required_use = REQUIRED_USE.get(match[1], set())
            if missing_use := required_use - set(meta.get("USE", "").split()):
                raise ValueError(f"Native binary package {cpv} lacks USE flags: {', '.join(sorted(missing_use))}")
            atoms[match[1]] = "=" + cpv
        if missing := REQUIRED_PACKAGES - atoms.keys():
            raise ValueError(f"Missing native binary packages: {', '.join(sorted(missing))}")

        image = self.read_file(root, kernel, entries[kernel])
        if (image[:2] != b"MZ" or image[56:60] != b"ARMd"
                or f"Linux version {release} ".encode() not in image):
            raise ValueError("Native kernel is not the declared AArch64 EFI-capable Image")
        initrd = self.read_file(root, initramfs, entries[initramfs])
        if not initrd.startswith(b"\x28\xb5\x2f\xfd"):
            raise ValueError("Native initramfs must use zstd")
        cpio = subprocess.check_output(["zstd", "-dc"], input=initrd)
        if b"20-ordo-usb.sh\0" in cpio:
            raise ValueError("Native initramfs must be portable and contain the matching ZFS module")
        index_name = modules + "modules.dep"
        module_index = self.read_file(root, index_name, entries[index_name])
        builtin_name = modules + "modules.builtin"
        builtins = self.read_file(root, builtin_name, entries[builtin_name]) if builtin_name in entries else b""
        required = boot_module_paths(module_index, builtins, (*boot_drivers, "asahi", "zfs"))
        prefix = f"lib/modules/{release}/".encode()
        for path in required:
            if modules + path.decode() not in entries:
                raise ValueError(f"Native input lacks the indexed module {path.decode()}")
            module_path = prefix + path.split(b".ko", 1)[0] + b".ko"
            if not re.search(re.escape(module_path) + rb"(?:\.[a-z0-9]+)?\0", cpio):
                raise ValueError(f"Native initramfs lacks the boot module {path.decode()}")
        for index_file in (b"modules.dep.bin", b"modules.alias.bin"):
            if prefix + index_file + b"\0" not in cpio:
                raise ValueError(f"Native initramfs lacks the {index_file.decode()} module index")
        del cpio

        # Include only manifest-pinned files. Native include paths are renamed
        # before archiving, so tar never receives path data from the target.
        archive_path = output / "native-input.tar.gz"
        with archive_path.open("wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw,
                                                          compresslevel=1, mtime=0) as packed:
            with tarfile.open(fileobj=packed, mode="w|", format=tarfile.GNU_FORMAT) as archive:
                for name in sorted([*module_files, index, repository, *package_files, *config_files]):
                    member = name.removeprefix("stage/lib/").removeprefix("stage/")
                    self.add_file(root, name, entries[name], member, archive)
                install_atoms = ("\n".join(sorted(atoms.values())) + "\n").encode()
                spec = tarfile.TarInfo("package-atoms")
                spec.size = len(install_atoms)
                archive.addfile(spec, BytesIO(install_atoms))
        if archive_path.stat().st_size >= 2**32:
            raise ValueError("Native payload archive exceeds a FAT32 file")
        digest = self.file_digest(archive_path)
        archive_path.rename(output / f"native-{digest}.tar.gz")

        kernel_path = output / "live" / f"vmlinuz-{release}-{entries[kernel]}"
        kernel_path.write_bytes(image)
        return release, kernel_path, entries[kernel], initrd, digest

    @staticmethod
    def source_path(root, name):
        source = root / name
        if source.is_symlink() or not source.resolve().is_relative_to(root):
            raise ValueError(f"Native input is not a regular local file: {name}")
        if not source.is_file() or not source.stat().st_size:
            raise ValueError(f"Native input is missing or empty: {name}")
        return source

    @classmethod
    def read_file(cls, root, name, digest):
        data = cls.source_path(root, name).read_bytes()
        if hashlib.sha256(data).hexdigest() != digest:
            raise ValueError(f"Native input SHA-256 mismatch: {name}")
        return data

    @staticmethod
    def file_digest(source):
        with source.open("rb") as stream:
            return hashlib.file_digest(stream, "sha256").hexdigest()

    @classmethod
    def add_file(cls, root, name, digest, member, archive):
        source = cls.source_path(root, name)
        signature = hashlib.sha256()
        with source.open("rb") as stream:
            class Reader:
                def read(self, size):
                    part = stream.read(size)
                    signature.update(part)
                    return part

            spec = tarfile.TarInfo(member)
            spec.size = source.stat().st_size
            archive.addfile(spec, Reader())
        if signature.hexdigest() != digest:
            raise ValueError(f"Native input SHA-256 mismatch: {name}")
