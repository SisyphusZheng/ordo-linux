#!/bin/sh
# B2 回归：掉盘 zedlet + 会话启动播报 + 手册恢复章节（D0-3）
#
# 锁三件事：
#   1. 池正常时 zedlet 零输出、不写标记、不播报；
#   2. 非 ONLINE / zpool status 超时与失败都会落 /run/ordo/root-pool-failed，
#      并走 wall + notify-send；恢复 ONLINE 清标记；
#   3. 会话启动（--session-report）读标记，强制判异常并弹 critical 通知，
#      手册 10 有 pool suspended 的恢复步骤与独立救援盘要求。
set -eu
cd "$(dirname "$(readlink -f "$0")")/../.."
PYTHONDONTWRITEBYTECODE=1 python3 -B - <<'PY'
import os
from pathlib import Path
import socket
import subprocess
import tempfile

REPO = Path.cwd()
ZEDLET = REPO / "config/platform/m2/zed.d/statechange-ordo.sh"
VERIFY = REPO / "config/platform/m2/verify-hardware.sh"
INSTALLER = REPO / "config/platform/m2/install-external.sh"
MANUAL = REPO / "docs/manual/10-m2-external.md"

assert subprocess.run(["sh", "-n", str(ZEDLET)], capture_output=True).returncode == 0
assert subprocess.run(["sh", "-n", str(VERIFY)], capture_output=True).returncode == 0
engine = INSTALLER.read_text()
assert 'install -Dm755 "$TARGET/opt/ordo/config/platform/m2/zed.d/statechange-ordo.sh"' in engine
assert '"$TARGET/etc/zfs/zed.d/statechange-ordo.sh"' in engine

with tempfile.TemporaryDirectory(prefix="ordo-zed-") as raw:
    tmp = Path(raw)
    bins = tmp / "bin"
    bins.mkdir()
    log = tmp / "calls"
    for name, body in {
        "zpool": r'''#!/bin/sh
printf 'zpool %s\n' "$*" >> "$LOG"
case "$1" in
    status) [ -n "${STATUS_FILE:-}" ] && cat "$STATUS_FILE"; exit "${STATUS_RC:-0}" ;;
esac
exit 0
''',
        "timeout": r'''#!/bin/sh
if [ "${TIMEOUT_RC:-0}" = 124 ]; then exit 124; fi
shift
exec "$@"
''',
        "wall": r'''#!/bin/sh
printf 'wall %s\n' "$*" >> "$LOG"
cat >/dev/null 2>&1 || :
''',
        "logger": '#!/bin/sh\nprintf "logger %s\\n" "$*" >> "$LOG"\n',
        "runuser": r'''#!/bin/sh
while [ "$#" -gt 0 ]; do
    case "$1" in
        -u) shift 2 ;;
        --) shift; break ;;
        *) break ;;
    esac
done
exec "$@"
''',
        "notify-send": '#!/bin/sh\nprintf "notify %s\\n" "$*" >> "$LOG"\n',
    }.items():
        path = bins / name
        path.write_text(body)
        path.chmod(0o755)

    # 造一个真实的会话总线 socket，让通知分支被走到。
    user = tmp / "user"
    (user / "1000").mkdir(parents=True)
    with socket.socket(socket.AF_UNIX) as bus:
        bus.bind(str(user / "1000/bus"))
        source = ZEDLET.read_text().replace("/run/user", str(user))
        zedlet = tmp / "zedlet"
        zedlet.write_text(source)
        status = tmp / "status"

        def run(state=None, **env):
            log.write_text("")
            environment = {
                "PATH": f"{bins}:{os.environ['PATH']}",
                "ORDO_RUN_DIR": str(tmp / "run"),
                "ORDO_ROOT_POOL": "rpool",
                "LOG": str(log), "STATUS_FILE": str(status),
                "ZEVENT_POOL": "rpool", "ZEVENT_SUBCLASS": "statechange",
            }
            if state is not None:
                environment["ZEVENT_VDEV_STATE_STR"] = state
            environment.update(env)
            return subprocess.run(["sh", str(zedlet)], capture_output=True, text=True,
                                  env=environment)

        marker = tmp / "run/root-pool-failed"

        # 正常状态：零输出、零标记、零播报
        result = run("ONLINE")
        assert result.returncode == 0
        assert result.stdout == "" and result.stderr == "", (result.stdout, result.stderr)
        assert not marker.exists()
        assert log.read_text() == "", log.read_text()

        # 非 ONLINE：标记 + wall + critical 通知
        result = run("SUSPENDED")
        assert result.returncode == 0
        assert marker.is_file(), "非 ONLINE 必须落标记"
        body = marker.read_text()
        assert "pool=rpool" in body and "state=SUSPENDED" in body, body
        calls = log.read_text()
        assert "wall" in calls and "SUSPENDED" in calls, calls
        assert "notify -u critical" in calls, calls

        # 其它池的事件不插手
        marker.unlink()
        result = run("FAULTED", ZEVENT_POOL="tank")
        assert result.returncode == 0 and not marker.exists()
        assert log.read_text() == ""

        # 没有池状态的非状态变化子类不跑 zpool、不写标记
        result = run(None, ZEVENT_SUBCLASS="io")
        assert result.returncode == 0 and not marker.exists()
        assert log.read_text() == ""

        # 无 ZEVENT_POOL_STATE：zpool status 健康 -> 清旧标记
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text("stale\n")
        status.write_text("pool 'rpool' is healthy\n")
        result = run(None)
        assert result.returncode == 0 and not marker.exists()
        assert "zpool status -x rpool" in log.read_text()

        # 无 ZEVENT_POOL_STATE + 状态读取超时：按故障落标记，退出仍 0
        status.write_text("pool: rpool\nstate: SUSPENDED\n")
        result = run(None, TIMEOUT_RC="124")
        assert result.returncode == 0
        assert marker.is_file() and "state=UNKNOWN" in marker.read_text(), marker.read_text()

# ---- 会话启动：--session-report 读标记、强制异常、弹 critical ----
with tempfile.TemporaryDirectory(prefix="ordo-pool-session-") as raw:
    tmp = Path(raw)
    compatible = tmp / "compatible"
    compatible.write_bytes(b"apple,j413\0apple,t8112\0")
    bins = tmp / "bin"
    bins.mkdir()
    notify = tmp / "notify"
    for name, body in {
        "timeout": r'''#!/bin/sh
if [ "$1" = 45 ] && [ "$2" = sh ]; then exit "${RESULT:-0}"; fi
shift
exec "$@"
''',
        "notify-send": f'#!/bin/sh\nprintf "%s\\n" "$*" >> {notify}\n',
    }.items():
        path = bins / name
        path.write_text(body)
        path.chmod(0o755)
    script = tmp / "verify"
    source = VERIFY.read_text().replace("/proc/device-tree/compatible", str(compatible))
    source = source.replace("/run/ordo", str(tmp / "run"))
    script.write_text(source)
    env = {"PATH": f"{bins}:{os.environ['PATH']}", "HOME": str(tmp),
           "XDG_STATE_HOME": str(tmp / "state"), "RESULT": "0"}
    log = tmp / "state/ordo/m2-hardware.log"
    marker = tmp / "run/root-pool-failed"
    marker.parent.mkdir(parents=True)

    assert subprocess.run(["sh", str(script), "--session-report"], env=env).returncode == 0
    assert log.read_text().splitlines()[-1] == "exit=0"

    marker.write_text("pool=rpool\nstate=SUSPENDED\ntime=2026-11-26T00:00:00Z\n")
    notify.unlink(missing_ok=True)
    result = subprocess.run(["sh", str(script), "--session-report"], env=env,
                            capture_output=True, text=True)
    assert result.returncode == 1, (result.returncode, result.stderr)
    report = log.read_text()
    assert "根池故障标记" in report and "外接根池故障" in report, report
    assert report.splitlines()[-1] == "exit=1", report
    assert notify.is_file() and "-u critical" in notify.read_text(), notify.read_text()

manual = MANUAL.read_text()
for token in ("pool suspended", "zpool clear rpool", "独立", "救援 U 盘", "不要长按断电"):
    assert token in manual, token
print("B2 pool-failure zedlet / session notice / manual: ok")
PY
