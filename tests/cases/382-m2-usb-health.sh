#!/bin/sh
# B3 回归：USB 根池健康（autotrim / 月检 TRIM 兜底 / swap sync / 威胁模型登记）
#
# 锁三件事：
#   1. 建池后调用 tune-usb-pool.sh；autotrim 成功不写 cron，失败落月检 cron
#      且整个安装不因此中止（USB 桥能力无法在仓库内预判）；
#   2. swap zvol 是 sync=standard，不再把每页换出同步刷到 USB；
#   3. deviations 与手册写明明文盘威胁模型和真机 TRIM 验证步骤。
set -eu
cd "$(dirname "$(readlink -f "$0")")/../.."
PYTHONDONTWRITEBYTECODE=1 python3 -B - <<'PY'
import os
from pathlib import Path
import subprocess
import tempfile

REPO = Path.cwd()
TUNE = REPO / "config/platform/m2/tune-usb-pool.sh"
INSTALLER = REPO / "config/platform/m2/install-external.sh"
DEVIATIONS = REPO / "docs/deviations.md"
MANUAL = REPO / "docs/manual/10-m2-external.md"

assert subprocess.run(["sh", "-n", str(TUNE)], capture_output=True).returncode == 0
engine = INSTALLER.read_text()
# swap zvol：sync=standard，且没有残留的 sync=always
assert "-o sync=standard" in engine
assert "sync=always" not in engine
swap = engine[engine.index('zfs create -V 4G'):]
swap = swap[:swap.index('"$POOL/swap"')]
assert "-o sync=standard" in swap and "-o sync=always" not in swap
# 建池后调用 tune，且参数是池名 + 安装根
assert 'sh "$TARGET/opt/ordo/config/platform/m2/tune-usb-pool.sh" "$POOL" "$TARGET"' in engine
assert engine.index('zpool create -R "$TARGET"') < engine.index('tune-usb-pool.sh" "$POOL"')

with tempfile.TemporaryDirectory(prefix="ordo-trim-") as raw:
    tmp = Path(raw)
    bins = tmp / "bin"
    bins.mkdir()
    log = tmp / "zpool.log"
    zpool = bins / "zpool"
    zpool.write_text(
        '#!/bin/sh\n'
        'printf "%s\\n" "$*" >> "$LOG"\n'
        'exit "${ZPOOL_RC:-0}"\n')
    zpool.chmod(0o755)
    root = tmp / "root"
    cron = root / "etc/cron.d/ordo-trim"

    def run(*args, **env):
        log.write_text("")
        environment = {"PATH": f"{bins}:{os.environ['PATH']}", "LOG": str(log)}
        environment.update(env)
        return subprocess.run(["sh", str(TUNE), *args], capture_output=True,
                              text=True, env=environment)

    # autotrim 成功：设置属性、不落 cron
    result = run("rpool", str(root))
    assert result.returncode == 0, result.stderr
    assert "set autotrim=on rpool" in log.read_text(), log.read_text()
    assert not cron.exists()

    # autotrim 失败：不失败安装，落月检 cron
    result = run("rpool", str(root), ZPOOL_RC="1")
    assert result.returncode == 0, result.stderr
    assert "autotrim" in result.stderr and "月检" in result.stderr, result.stderr
    assert cron.is_file(), "autotrim 失败必须落月检 cron"
    body = cron.read_text()
    assert "17 3 1 * * root zpool trim rpool" in body, body
    assert (cron.stat().st_mode & 0o777) == 0o644, oct(cron.stat().st_mode & 0o777)

    # 再次成功：撤掉兜底，避免双重 TRIM
    result = run("rpool", str(root), ZPOOL_RC="0")
    assert result.returncode == 0 and not cron.exists()

    # 参数错误：2（无法判定），不能猜池名
    assert run().returncode == 2

    # 连 cron 目录都写不进去：1（明确失败），不能假装成功
    blocker = tmp / "blocked"
    blocker.write_text("not a directory\n")
    result = run("rpool", str(blocker), ZPOOL_RC="1")
    assert result.returncode == 1, (result.returncode, result.stderr)

deviations = DEVIATIONS.read_text()
for token in ("明文", "加密", "月检", "sync=standard", "TRIM"):
    assert token in deviations, token
manual = MANUAL.read_text()
for token in ("zpool get autotrim rpool", "zpool trim rpool", "sync=standard", "明文"):
    assert token in manual, token
print("B3 USB health (autotrim / trim cron / swap sync / threat model): ok")
PY
