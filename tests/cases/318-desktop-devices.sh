#!/bin/sh
set -eu
cd "$(dirname "$(readlink -f "$0")")/../.."
PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import io
from pathlib import Path
import sys
import tarfile
sys.path.insert(0, "dev/m2")
from build import bundle

drivers = Path("config/platform/m2/boot-drivers").read_bytes()
assert b"brcmfmac\nbrcmfmac-wcc\n" in drivers
storage = Path("config/package.use/ordo-storage").read_bytes()
assert b"udisks -gcr -keyring -systemd" in storage
assert b"sys-fs/udisks daemon elogind -systemd" in storage
world = Path("config/world").read_bytes()
assert all(line in world.splitlines() for line in (
    b"gnome-base/gvfs", b"sys-fs/udisks", b"x11-misc/xdg-user-dirs",
))
session = Path("config/desktop/umbriel/ordo-umbriel-session").read_text()
assert session.index("xdg-user-dirs-update") < session.index("exec start-umbriel")
with tarfile.open(fileobj=io.BytesIO(bundle(include_legacy=False))) as payload:
    assert payload.extractfile("config/platform/m2/boot-drivers").read() == drivers
    assert payload.extractfile("config/package.use/ordo-storage").read() == storage
    assert payload.extractfile("config/world").read() == world
PY
