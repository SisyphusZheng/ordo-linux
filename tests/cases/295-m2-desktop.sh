#!/bin/sh
# Exercise the chroot desktop fix with local config and runlevel fixtures.
set -eu
cd "$(dirname "$(readlink -f "$0")")/../.."
python3 - <<'PY'
import gzip
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path.cwd()
desktop = repo / "config/desktop"
native_install = (repo / "config/platform/m2/install-native.sh").read_text()
assert native_install.index("sh /opt/ordo/config/desktop/m2-desktop-fix.sh") < native_install.index("    emerge ")
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory).resolve()
    for path in ("runlevels/boot", "runlevels/default", "env.d", "bin"):
        (root / path).mkdir(parents=True)
    script = root / "m2-desktop-fix.sh"
    script.write_text((desktop / script.name).read_text()
                      .replace("/etc/env.d", str(root / "env.d"))
                      .replace("/etc/runlevels", str(root / "runlevels"))
                      .replace("/proc/config.gz", str(root / "config.gz")))
    shutil.copyfile(desktop / "99imm", root / "99imm")
    for command, body in {
        "install": 'cp "$2" "$3"',
        "env-update": 'echo env-update >> "$LOG"',
        "rc-update": 'echo "$*" >> "$LOG"; rm "$RUNLEVELS/$3/$2"',
    }.items():
        tool = root / "bin" / command
        tool.write_text(f"#!/bin/sh\n{body}\n")
        tool.chmod(0o755)
    log = root / "log"
    env = {**os.environ, "PATH": f"{root}/bin:{os.environ['PATH']}", "LOG": str(log),
           "RUNLEVELS": str(root / "runlevels")}
    config_file = root / "config.gz"
    for kernel_config in (None, "CONFIG_BINFMT_MISC=y", "CONFIG_BINFMT_MISC=m",
                          "# CONFIG_BINFMT_MISC is not set"):
        if kernel_config:
            config_file.write_bytes(gzip.compress((kernel_config + "\n").encode()))
        for level in ("boot", "default"):
            link = root / "runlevels" / level / "binfmt"
            if not link.is_symlink():
                link.symlink_to("/etc/init.d/binfmt")
        log.write_text("")
        subprocess.run(["sh", script], env=env, check=True)
        assert (root / "env.d/99imm").read_bytes() == (desktop / "99imm").read_bytes()
        events = log.read_text().splitlines()
        assert events[0] == "env-update", events
        if kernel_config == "# CONFIG_BINFMT_MISC is not set":
            assert events[1:] == ["del binfmt boot", "del binfmt default"], events
            subprocess.run(["sh", script], env=env, check=True)
            assert log.read_text().splitlines()[-1] == "env-update"
        else:
            assert len(events) == 1, events

    config_file.unlink()
    migration, = (repo / "config/migrations").glob("*-m2-desktop-environment.sh")
    tree = root / "compatible"
    migrated = root / "migrations" / migration.name
    migrated.parent.mkdir()
    platform = root / "platform/m2"
    platform.mkdir(parents=True)
    (platform / "repair-barefiles.py").write_text("print('repair')\n")
    migrated.write_text(migration.read_text().replace("/proc/device-tree/compatible", str(tree))
                        .replace('../desktop/', '../'))
    for compatible in (b"apple,j413\0apple,t8112\0", b"linux,dummy-virt\0"):
        tree.write_bytes(compatible)
        log.write_text("")
        subprocess.run(["sh", migrated], env=env, check=True)
        assert bool(log.read_text()) == compatible.startswith(b"apple,j413")
PY
python3 tests/m2_barefiles_ownership.py
if command -v env-update >/dev/null 2>&1; then
    env_root=$(mktemp -d)
    trap 'rm -rf "$env_root"' EXIT
    mkdir -p "$env_root/etc/env.d"
    cp config/desktop/99imm "$env_root/etc/env.d/99imm"
    PORTAGE_CONFIGROOT="$env_root" ROOT="$env_root" env-update --no-ldconfig >"$env_root/log" 2>&1
    if grep -E 'Invalid token|99imm.*Error' "$env_root/log"; then
        exit 1
    fi
    env -i sh -c '. "$1"; test "$XMODIFIERS" = @im=fcitx && test "$GTK_IM_MODULE" = wayland' sh "$env_root/etc/profile.env"
fi
