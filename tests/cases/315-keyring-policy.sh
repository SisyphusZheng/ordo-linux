#!/bin/sh
set -eu
cd "$(dirname "$(readlink -f "$0")")/../.."
PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
from hashlib import blake2b, sha512
import io
from pathlib import Path
import sys
import tarfile

overlay = Path("overlay/app-crypt/libsecret")
for line in (overlay / "Manifest").read_text().splitlines():
    kind, name, size, b_alg, b_hash, s_alg, s_hash = line.split()
    if kind == "DIST":
        continue
    data = (overlay / ("files" if kind == "AUX" else "") / name).read_bytes()
    assert int(size) == len(data)
    assert (b_alg, b_hash) == ("BLAKE2B", blake2b(data).hexdigest())
    assert (s_alg, s_hash) == ("SHA512", sha512(data).hexdigest())

recipe, = overlay.glob("*.ebuild")
assert "PDEPEND=" not in recipe.read_text()
assert "app-crypt/libsecret::local" in Path("config/world").read_text().splitlines()
policy = Path("config/package.mask/ordo-keyring").read_text().splitlines()
assert {"gnome-base/gnome-keyring", "virtual/secret-service", "app-crypt/libsecret::gentoo"} <= set(policy)
assert "app-crypt/pinentry -gtk -keyring ncurses" in Path("config/package.use/ordo-keyring").read_text().splitlines()
assert "pam_gnome_keyring" not in Path("config/desktop/greetd/pam.d-greetd").read_text()
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
        "config/package.mask/ordo-keyring",
        "config/package.use/ordo-keyring",
        "config/migrations/1795627149-remove-gnome-keyring.sh",
        *[file.as_posix() for file in overlay.rglob("*") if file.is_file()],
    ):
        assert payload.extractfile(path).read() == Path(path).read_bytes()
PY
