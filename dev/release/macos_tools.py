"""Package the macOS tools used by prepare.py with relocatable dylib paths."""
from pathlib import Path
import argparse
import shutil
import subprocess


def deps(path):
    output = subprocess.check_output(["otool", "-L", path], text=True)
    return [line.strip().split(" (compatibility version", 1)[0]
            for line in output.splitlines()[1:]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    tools = args.output / "tools"
    licenses = args.output / "tool-licenses"
    tools.mkdir(parents=True, exist_ok=True)
    for formula in ("aarch64-elf-binutils", "zstd", "xz", "lz4", "mtools"):
        prefix = Path(subprocess.check_output(["brew", "--prefix", formula], text=True).strip())
        destination = licenses / formula
        destination.mkdir(parents=True, exist_ok=True)
        for pattern in ("LICENSE*", "COPYING*", "sbom.spdx.json"):
            for entry in prefix.glob(pattern):
                if entry.is_file():
                    shutil.copy2(entry, destination / entry.name)
    libdir = Path(subprocess.check_output(["brew", "--prefix", "zstd"], text=True).strip()) / "lib"
    queue = [(Path(shutil.which(binary)), binary) for binary in ("aarch64-elf-objcopy", "zstd", "mdir", "mcopy")]
    processed = set()
    while queue:
        source, name = queue.pop()
        if name in processed:
            continue
        processed.add(name)
        dest = tools / name
        shutil.copy2(source, dest)
        dest.chmod(0o755)
        flags = []
        if name.endswith(".dylib"):
            flags.extend(["-id", "@loader_path/" + name])
        for dep in deps(source):
            if dep.startswith(("/usr/lib/", "/System/Library/")) or Path(dep).name == name:
                continue
            local = libdir / Path(dep).name if dep.startswith("@rpath/") else Path(dep)
            if not local.is_file():
                raise ValueError(f"Unable to resolve {dep} for {source}")
            flags.extend(["-change", dep, "@loader_path/" + local.name])
            queue.append((local, local.name))
        if flags:
            subprocess.run(["install_name_tool", *flags, dest], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", dest], check=True)
    for name in ("aarch64-elf-objcopy", "zstd", "mdir", "mcopy"):
        subprocess.run([tools / name, "--version"], check=True, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
