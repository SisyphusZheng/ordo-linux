#!/bin/sh
# B1 回归：外接 USB 根池的睡眠策略、system-sleep 钩子与唤醒复检（D0-2）
#
# 锁三件事：
#   1. logind drop-in 真的禁掉四个入口（合盖/外接电源合盖/睡眠键/休眠键）；
#   2. 钩子 pre 刷池、post 读 zpool 状态，非 ONLINE 落标记 + wall，且无论
#      zpool 超时/失败都 exit 0（post 卡住会卡住唤醒）；
#   3. verify-hardware.sh --resume 只跑无线/音频/输入三项，不碰 eglinfo/摄像头。
set -eu
cd "$(dirname "$(readlink -f "$0")")/../.."
PYTHONDONTWRITEBYTECODE=1 python3 -B - <<'PY'
import os
from pathlib import Path
import subprocess
import tempfile

REPO = Path.cwd()
CONF = REPO / "config/desktop/elogind/logind.conf.d/10-ordo-external-root.conf"
HOOK = REPO / "config/desktop/elogind/system-sleep/50-ordo-root-pool.sh"
VERIFY = REPO / "config/platform/m2/verify-hardware.sh"
INSTALLER = REPO / "config/platform/m2/install-external.sh"


def sh_syntax(path):
    return subprocess.run(["sh", "-n", str(path)], capture_output=True)


# ---- 声明层 ----
text = CONF.read_text()
assert "[Login]" in text
for key in ("HandleLidSwitch=ignore", "HandleLidSwitchExternalPower=ignore",
            "HandleSuspendKey=ignore", "HandleHibernateKey=ignore"):
    active = [line for line in text.splitlines()
              if line.strip() == key and not line.lstrip().startswith("#")]
    assert active, key
for path in (HOOK, VERIFY):
    result = sh_syntax(path)
    assert result.returncode == 0, result.stderr
engine = INSTALLER.read_text()
assert 'root_transport=$(lsblk -ndo TRAN' in engine
assert 'if [ "$root_transport" != nvme ]' in engine
for needle in (
    'logind.conf.d/10-ordo-external-root.conf',
    'system-sleep/50-ordo-root-pool.sh',
):
    assert needle in engine, needle
# 钩子必须在非 nvme 分支里安装，不能在 nvme 根上无条件落。
branch = engine[engine.index('if [ "$root_transport" != nvme ]'):]
branch = branch[:branch.index("\nfi\n")]
assert '"$TARGET/opt/ordo/config/desktop/elogind/system-sleep/50-ordo-root-pool.sh"' in branch
assert '"$TARGET/lib/elogind/system-sleep/50-ordo-root-pool.sh"' in branch

# ---- 钩子行为：pre / post（健康、非 ONLINE、超时、读取失败），全部 exit 0 ----
with tempfile.TemporaryDirectory(prefix="ordo-sleep-") as raw:
    tmp = Path(raw)
    bins = tmp / "bin"
    bins.mkdir()
    log = tmp / "calls"
    status = tmp / "status"
    for name, body in {
        "zpool": r'''#!/bin/sh
printf 'zpool %s\n' "$*" >> "$LOG"
case "$1" in
    sync) exit "${SYNC_RC:-0}" ;;
    status) [ -n "${STATUS_FILE:-}" ] && cat "$STATUS_FILE"; exit "${STATUS_RC:-0}" ;;
esac
exit 1
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
        "notify-send": r'''#!/bin/sh
printf 'notify-send %s\n' "$*" >> "$LOG"
''',
        "logger": r'''#!/bin/sh
printf 'logger %s\n' "$*" >> "$LOG"
''',
    }.items():
        path = bins / name
        path.write_text(body)
        path.chmod(0o755)

    def run(action, **env):
        log.write_text("")
        return subprocess.run(
            ["sh", str(HOOK), action, "suspend"],
            capture_output=True, text=True,
            env={"PATH": f"{bins}:{os.environ['PATH']}",
                 "ORDO_RUN_DIR": str(tmp / "run"),
                 "ORDO_ROOT_POOL": "rpool",
                 "LOG": str(log), "STATUS_FILE": str(status), **env})

    # pre：刷根池，成功/失败都不影响退出码
    result = run("pre")
    assert result.returncode == 0, result.stderr
    assert "zpool sync rpool" in log.read_text(), log.read_text()
    result = run("pre", SYNC_RC="1")
    assert result.returncode == 0, "pre 失败也不得阻塞睡眠"

    # post 健康：无标记、无播报
    status.write_text("pool 'rpool' is healthy\n")
    result = run("post")
    assert result.returncode == 0
    assert not (tmp / "run/root-pool-failed").exists()
    assert "wall" not in log.read_text()

    # 先造一个旧标记，健康 post 必须清掉
    marker = tmp / "run/root-pool-failed"
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text("stale\n")
    run("post")
    assert not marker.exists(), "池恢复后旧标记必须清掉"

    # post 非 ONLINE：标记 + wall，退出码仍是 0
    status.write_text("  pool: rpool\n state: DEGRADED\nstatus: One or more devices are faulted.\n")
    result = run("post")
    assert result.returncode == 0
    assert marker.is_file(), "非 ONLINE 必须落标记"
    body = marker.read_text()
    assert "pool=rpool" in body and "state=非 ONLINE" in body, body
    assert "wall" in log.read_text() and "不是 ONLINE" in log.read_text(), log.read_text()

    # post 读状态超时：按故障落标记，不得卡住唤醒
    marker.unlink()
    result = run("post", TIMEOUT_RC="124")
    assert result.returncode == 0
    assert marker.is_file() and "超时" in marker.read_text(), marker.read_text()

    # post zpool status 直接失败：同样落标记
    marker.unlink()
    result = run("post", STATUS_RC="1")
    assert result.returncode == 0
    assert marker.is_file() and "退出码 1" in marker.read_text(), marker.read_text()

# ---- verify --resume：只查无线/音频/输入，不调 eglinfo/v4l2-ctl ----
with tempfile.TemporaryDirectory(prefix="ordo-resume-") as raw:
    tmp = Path(raw)
    compatible = tmp / "compatible"
    compatible.write_bytes(b"apple,j413\0apple,t8112\0")
    def mkdir(name):
        path = tmp / name
        path.mkdir(parents=True, exist_ok=True)
        return path
    # 固件映射与已注册无线控制器
    (mkdir("platform") / "wireless-firmware").write_text("src.bin apple,hokkaido.bin\n")
    fw = mkdir("firmware/vendorfw")
    (fw / "apple,hokkaido.bin").write_bytes(b"fw")
    radio = mkdir("ieee/phy0/device")
    (radio / "driver").symlink_to("/drivers/brcmfmac")
    # 输入设备
    for index, name in ((0, "Apple MTP keyboard"), (1, "Apple MTP multi-touch")):
        device = mkdir(f"input/input{index}")
        (device / "name").write_text(name + "\n")
    bins = tmp / "bin"
    bins.mkdir()
    calls = tmp / "calls"
    for name, body in {
        "dmesg": '#!/bin/sh\nprintf "brcmfmac: firmware ready\\n"\n',
        "pgrep": '#!/bin/sh\nexit 0\n',
        "amixer": r'''#!/bin/sh
case "$3" in
    controls) printf "%s\n" "numid=42,iface=MIXER,name='Speaker Volume Unlock'" ;;
    cget) printf '  : values=1\n' ;;
esac
''',
        "pw-dump": r'''#!/bin/sh
printf '%s\n' '"node.name": "audio_effect.j413-convolver"' \
    '"node.name": "effect_output.j413-mic"'
''',
        "eglinfo": '#!/bin/sh\nprintf x >> "$CALLS"\nexit 0\n',
        "v4l2-ctl": '#!/bin/sh\nprintf x >> "$CALLS"\nexit 0\n',
    }.items():
        path = bins / name
        path.write_text(body)
        path.chmod(0o755)
    script = tmp / "verify"
    source = VERIFY.read_text()
    source = source.replace("/proc/device-tree/compatible", str(compatible))
    source = source.replace("/opt/ordo/config/platform/m2", str(tmp / "platform"))
    source = source.replace("/etc/ordo/wireless-firmware", str(tmp / "wireless-firmware"))
    source = source.replace("/lib/firmware", str(tmp / "firmware"))
    source = source.replace("/sys/class/ieee80211", str(tmp / "ieee"))
    source = source.replace("/sys/class/input", str(tmp / "input"))
    source = source.replace("/run/ordo", str(tmp / "run"))
    script.write_text(source)
    result = subprocess.run(
        ["sh", str(script), "--resume"], capture_output=True, text=True,
        env={"PATH": f"{bins}:{os.environ['PATH']}", "HOME": str(tmp),
             "XDG_CONFIG_HOME": str(tmp / "config"), "CALLS": str(calls)})
    assert result.returncode == 0, (result.stdout, result.stderr)
    for label in ("Broadcom 无线网卡已注册", "J413 扬声器保护", "内置键盘和触控板已注册"):
        assert label in result.stdout, result.stdout
    assert "Umbriel 会话" not in result.stdout and "摄像头" not in result.stdout
    assert not calls.exists(), "resume 不得调用 eglinfo 或摄像头工具"
    # 未知参数仍是无法判定（2），不能被当成 resume
    assert subprocess.run(["sh", str(script), "--bogus"], capture_output=True).returncode == 2
print("B1 sleep policy / system-sleep / --resume: ok")
PY
