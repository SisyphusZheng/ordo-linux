#!/bin/sh
set -eu
cd "$(dirname "$(readlink -f "$0")")/../.."
PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import io
from pathlib import Path
import sys
import tarfile

# Secret Service 已回归：world 回到树内 libsecret，并显式声明提供者。
world = Path("config/world").read_text().splitlines()
assert "app-crypt/libsecret" in world
assert "gnome-base/gnome-keyring" in world
assert "app-crypt/libsecret::local" not in world
# 旧的 mask 与本地配方必须一起退场，否则上游 libsecret 仍被遮蔽。
assert not Path("config/package.mask/ordo-keyring").exists()
assert not Path("overlay/app-crypt/libsecret").exists()
assert "overlay/app-crypt/libsecret" not in Path("dev/m2/build.py").read_text()

use = Path("config/package.use/ordo-keyring").read_text().splitlines()
assert "sys-auth/pambase gnome-keyring" in use
assert "app-crypt/pinentry -gtk -keyring ncurses" in use

pam = Path("config/desktop/greetd/pam.d-greetd").read_text()
assert "auth            optional        pam_gnome_keyring.so" in pam
assert "session         optional        pam_gnome_keyring.so auto_start" in pam

installer = Path("install.sh").read_text()
assert installer.index('keyring-policy.sh" configure') < installer.index('if emerge -uDN')
assert installer.index('keyring-policy.sh" remove') > installer.index('if emerge -uDN')
assert '"$REPO_DIR/config" "$REPO_DIR/overlay" /opt/ordo/' in installer
m2 = Path("config/platform/m2/install-external.sh").read_text()
first, second = [i for i in range(len(m2)) if m2.startswith('"$policy" check', i)]
assert first < m2.index('/bin/sh /opt/ordo/config/platform/m2/install-native.sh') < second
assert 'keyring-policy.sh" check' in Path("dev/vm/configure-root.sh").read_text()

sys.path.insert(0, "dev/m2")
from build import bundle

with tarfile.open(fileobj=io.BytesIO(bundle(include_legacy=False))) as payload:
    for path in (
        "config/desktop/keyring-policy.sh",
        "config/package.use/ordo-keyring",
    ):
        assert payload.extractfile(path).read() == Path(path).read_bytes()
    names = payload.getnames()
    assert "config/package.mask/ordo-keyring" not in names
    assert not any(name.startswith("overlay/app-crypt/libsecret/") for name in names)
PY
