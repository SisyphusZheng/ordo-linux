#!/usr/bin/env python3
"""Render selected Gentoo package defaults from verified release sources."""
import argparse
import hashlib
from pathlib import Path
import re
import tarfile

ZFS_SHA512 = "8be81dedc0c0ec38728248151a33b8cbc78b042bc27a913279009bd735faa6149ad5b4a2db5811d25f4a03820dd398e14f59a4aec07f6bd4bc39405190c4e4ad"
UPOWER_SHA512 = "f880dcdf170c3b6c31c83edcdccfc60a93879224678dbe6aa1907e61b4690863ad5dc38421c0f98b5e3cff9993a15dbc9f07b2cf6fd4eccf576939ddd2b57802"
PPD_SHA256 = "218566ee8f71358173a2c61016b92817b6ceebf4ff0fe5f2f1c2c1bef324ff43"
BSD2_SHA256 = "be4743872aa9418cb5391b29ae21e559e5544395986e5f07d8b73eb1b66ea0e6"
ZFS_SUBSTITUTIONS = {
    "DEFAULT_INIT_NFS_SERVER": "nfs",
    "DEFAULT_INIT_SHELL": "/sbin/openrc-run",
    "IS_SYSV_RC": "false",
    "initconfdir": "/etc/conf.d",
    "runstatedir": "/var/run",
    "sbindir": "/sbin",
    "sysconfdir": "/etc",
}


def verified(path, algorithm, expected):
    stream = path.open("rb")
    if hashlib.file_digest(stream, algorithm).hexdigest() != expected:
        stream.close()
        raise ValueError(f"Source digest mismatch: {path}")
    stream.seek(0)
    return stream


def write(path, data, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    path.chmod(mode)


def render(zfs, upower, ppd, bsd2_license, output):
    zfs_files = {
        "LICENSE": "LICENSE",
        "COPYRIGHT": "COPYRIGHT",
        "etc/conf.d/zfs": "etc/default/zfs.in",
        "etc/zfs/zfs-functions": "etc/zfs/zfs-functions.in",
        "etc/zfs/zed.d/zed-functions.sh": "cmd/zed/zed.d/zed-functions.sh",
        "etc/zfs/zed.d/zed.rc": "cmd/zed/zed.d/zed.rc",
    }
    for name in ("import", "load-key", "mount", "share", "zed"):
        zfs_files[f"etc/init.d/zfs-{name}"] = f"etc/init.d/zfs-{name}.in"
    for name in ("alias", "multipath", "sas_direct", "sas_switch", "scsi"):
        path = f"etc/zfs/vdev_id.conf.{name}.example"
        zfs_files[path] = path
    with verified(zfs, "sha512", ZFS_SHA512) as stream, tarfile.open(fileobj=stream) as package:
        for target, source in zfs_files.items():
            data = package.extractfile("zfs-2.4.4/" + source).read()
            if source.endswith(".in"):
                data = re.sub(rb"@([A-Za-z0-9_]+)@",
                              lambda match: ZFS_SUBSTITUTIONS[match.group(1).decode()].encode(), data)
            if target == "etc/conf.d/zfs":
                data = re.sub(rb"^ZFS_UNMOUNT=.*yes.*$", b"ZFS_UNMOUNT='no'", data, flags=re.M)
            write(output / "zfs-2.4.4" / target, data, 0o755 if target.startswith("etc/init.d/") else 0o644)
    with verified(upower, "sha512", UPOWER_SHA512) as stream, tarfile.open(fileobj=stream) as package:
        for name in ("COPYING", "etc/UPower.conf", "etc/UPower.conf.d/README.md"):
            target = name.replace("etc/", "etc/UPower/", 1)
            data = package.extractfile("upower-v1.91.3/" + name).read()
            write(output / "upower-1.91.3" / target, data)
    with verified(ppd, "sha256", PPD_SHA256) as stream:
        write(output / "power-profiles-daemon-0.30-r1/etc/init.d/power-profiles-daemon", stream.read(), 0o755)
    with verified(bsd2_license, "sha256", BSD2_SHA256) as stream:
        write(output / "zfs-2.4.4/BSD-2-Clause.txt", stream.read())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("zfs", "upower", "ppd", "bsd2_license", "output"):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    render(args.zfs, args.upower, args.ppd, args.bsd2_license, args.output)
