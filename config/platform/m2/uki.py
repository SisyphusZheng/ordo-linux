"""Read and replace payload sections in the unsigned AArch64 Ordo EFI stub."""
from dataclasses import dataclass
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile


@dataclass(frozen=True)
class Section:
    rva: int
    size: int
    offset: int


class Uki:
    def __init__(self, path):
        self.path = Path(path)
        self.sections = {}
        with self.path.open("rb") as source:
            source.seek(60)
            pe, = struct.unpack("<I", source.read(4))
            source.seek(pe)
            coff = source.read(24)
            if coff[:6] != b"PE\0\0\x64\xaa":
                raise ValueError(f"{path}: expected an AArch64 EFI image")
            count, = struct.unpack_from("<H", coff, 6)
            optional_size, = struct.unpack_from("<H", coff, 20)
            opt = source.read(optional_size)
            if opt[:2] != b"\x0b\x02" or len(opt) < 152 or any(opt[144:152]):
                raise ValueError(f"{path}: expected an unsigned PE32+ EFI image")
            self.base, self.alignment = struct.unpack_from("<QI", opt, 24)
            if not self.alignment or self.alignment & (self.alignment - 1):
                raise ValueError(f"{path}: invalid PE section alignment")
            length = self.path.stat().st_size
            for _ in range(count):
                label, size, rva, raw, offset = struct.unpack_from("<8sIIII", source.read(40))
                label = label.rstrip(b"\0").decode("ascii")
                if label in self.sections or offset + raw > length:
                    raise ValueError(f"{path}: invalid PE section {label}")
                # A zero-fill or partially zero-filled section can be retained,
                # but it cannot serve as a UKI payload.
                self.sections[label] = Section(rva, size, offset if size <= raw else 0)

    def read(self, label):
        section = self.sections.get(label)
        if not section or not section.offset or not section.size:
            raise ValueError(f"{self.path}: missing UKI section {label}")
        with self.path.open("rb") as source:
            source.seek(section.offset)
            return source.read(section.size)

    def matches(self, label, path):
        section = self.sections.get(label)
        if not section or not section.offset or section.size != path.stat().st_size:
            return False
        with self.path.open("rb") as image, path.open("rb") as payload:
            image.seek(section.offset)
            while chunk := payload.read(1024 * 1024):
                if image.read(len(chunk)) != chunk:
                    return False
        return True

    def replace(self, payloads, output, work):
        objcopy = next((tool for name in ("aarch64-elf-objcopy", "aarch64-linux-gnu-objcopy", "objcopy")
                        if (tool := shutil.which(name))), None)
        if not objcopy:
            raise RuntimeError("找不到支持 AArch64 EFI 的 GNU objcopy")
        retained = [section.rva + section.size for label, section in self.sections.items() if label not in payloads]
        addr = max(retained)
        with tempfile.TemporaryDirectory(dir=work) as folder:
            stub = Path(folder) / "stub.efi"
            subprocess.run([objcopy, "--preserve-dates",
                            *["--remove-section=" + label for label in payloads], self.path, stub], check=True)
            args = [objcopy, "--preserve-dates"]
            for label, payload in payloads.items():
                if isinstance(payload, bytes):
                    file = Path(folder) / label
                    file.write_bytes(payload)
                else:
                    file = payload
                addr = (addr + self.alignment - 1) // self.alignment * self.alignment
                args += ["--add-section", f"{label}={file}", "--change-section-vma", f"{label}={self.base+addr:#x}",
                         "--set-section-flags", f"{label}=alloc,load,readonly,data,contents"]
                addr += file.stat().st_size
            subprocess.run([*args, stub, output], check=True, env={**os.environ, "SOURCE_DATE_EPOCH": "0"})
