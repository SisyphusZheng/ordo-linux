#!/bin/sh
set -eu
cd "$(dirname "$(readlink -f "$0")")/../.."
python3 - <<'PY'
import os
from pathlib import Path
import subprocess
import tempfile
import tomllib

platform = Path("config/platform/m2")
config = tomllib.loads(Path("config/desktop/umbriel/config.toml").read_text())
assert any("/ordo-m2-hardware --session-report" in cmd for cmd in config["general"]["autostart"])
first = (platform / "first-desktop.sh").read_text()
assert 'sh "$src/m2-desktop-fix.sh"' in first
assert 'sh /opt/ordo/config/platform/m2/install-hardware.sh' in first
with tempfile.TemporaryDirectory() as d:
    root = Path(d)
    compatible = root / "compatible"
    compatible.write_bytes(b"apple,j413\0apple,t8112\0")
    script = root / "verify"
    script.write_text((platform / "verify-hardware.sh").read_text().replace("/proc/device-tree/compatible", str(compatible)))
    timeout = root / "timeout"
    timeout.write_text('#!/bin/sh\n[ "$#" = 3 ] && [ "$1" = 45 ] && [ "$2" = sh ] || exit 88\nexit "$RESULT"\n')
    timeout.chmod(0o755)
    for result, expected in ((0, 0), (1, 1), (2, 2), (124, 2)):
        env = {**os.environ, "PATH": d + ":" + os.environ["PATH"], "XDG_STATE_HOME": d, "RESULT": str(result)}
        run = subprocess.run(["sh", str(script), "--session-report"], env=env)
        assert run.returncode == expected
        log = root / "ordo/m2-hardware.log"
        assert log.read_text().endswith(f"exit={expected}\n")
        assert log.stat().st_mode & 0o777 == 0o600
    compatible.write_bytes(b"linux,dummy-virt\0")
    log.unlink()
    assert subprocess.run(["sh", str(script), "--session-report"], env=env).returncode == 2
    assert not log.exists()
PY
