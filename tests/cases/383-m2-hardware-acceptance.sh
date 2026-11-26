#!/bin/sh
# B4/B5/B6/B7 回归：扬声器保护 else/respawn/标记、摄像头摘项、背光与小组件输出
#
# 锁五件事：
#   1. 扬声器保护只在 speakersafetyd + asahi-audio 两个硬条件缺失时拒绝装配，
#      其余缺项逐条打印；启动超时 20 秒；崩溃后由 supervise-daemon 拉起；
#   1b. /run/ordo 必须对 ordo 组可写（否则标记永远写不出来，B4 阻断项）；
#   2. audio 判定失败写 /run/ordo/speaker-protection-missing，恢复后清掉；
#   3. 摄像头不在例行检查里，只有 --capture-camera 才跑；
#   4. /sys/class/backlight 非空且 max>0 才算通过；
#   5. Noctalia 小组件不再写死 output，运行时判据能抓住未连接的输出。
set -eu
cd "$(dirname "$(readlink -f "$0")")/../.."
PYTHONDONTWRITEBYTECODE=1 python3 -B - <<'PY'
import os
from pathlib import Path
import re
import subprocess
import tempfile

REPO = Path.cwd()
HARDWARE = REPO / "config/platform/m2/install-hardware.sh"
_hw = HARDWARE.read_text()
assert "d /run/ordo 0770 root ordo" in _hw, "/run/ordo 必须组可写，否则 ordo 用户写不了标记"
assert "chmod 0770 /run/ordo" in _hw, "/run/ordo 运行时权限必须与 tmpfiles 一致"
PLATFORM = REPO / "config/platform/m2"
VERIFY = PLATFORM / "verify-hardware.sh"
INSTALL_HW = PLATFORM / "install-hardware.sh"
SPEAKER = PLATFORM / "speakersafetyd.conf"
NOCTALIA = REPO / "config/desktop/noctalia/config.toml"

assert subprocess.run(["sh", "-n", str(VERIFY)], capture_output=True).returncode == 0
assert subprocess.run(["sh", "-n", str(INSTALL_HW)], capture_output=True).returncode == 0

# ---- B4 声明层 ----
speaker = SPEAKER.read_text()
assert '-ge 100' in speaker, "启动等待必须是 20 秒（100 × 0.2s）"
assert "supervisor=supervise-daemon" in speaker
assert "respawn_delay=5" in speaker and "respawn_max=0" in speaker
installer = INSTALL_HW.read_text()
for token in ("扬声器保护未装配", "降级装配", "hard_missing", "soft_missing"):
    assert token in installer, token
assert "supervisor" in speaker

# ---- B4 装配分支：硬条件、软缺项、全齐 ----
INSTALL_STUB = r'''#!/bin/sh
mode=644
while [ "$#" -gt 0 ]; do
    case "$1" in
        -Dm*) mode=${1#-Dm}; shift; mkdir -p "${2%/*}" && cp "$1" "$2" && chmod "$mode" "$2"; exit $? ;;
        -d) shift
            [ "$1" = -m ] && { shift; mode=$1; shift; }
            mkdir -p "$1" && chmod "$mode" "$1"; exit $? ;;
        -m) mode=$1; shift; cp "$1" "$2" && chmod "$mode" "$2"; exit $? ;;
        *) break ;;
    esac
done
exit 1
'''
PORTAGEQ_STUB = r'''#!/bin/sh
case "$*" in
    *speakersafetyd*) exit "${HAS_SPEAKER:-0}" ;;
    *asahi-audio*) exit "${HAS_AUDIO:-0}" ;;
esac
exit 1
'''

with tempfile.TemporaryDirectory(prefix="ordo-speaker-") as raw:
    tmp = Path(raw)
    bins = tmp / "bin"
    bins.mkdir()
    for name, body in {
        "install": INSTALL_STUB,
        "portageq": PORTAGEQ_STUB,
        "rc-update": '#!/bin/sh\nprintf "%s\\n" "$*" >> "$RC_LOG"\n',
        "id": '#!/bin/sh\n[ "$1" = -u ] && { echo 0; exit 0; }\nexec /usr/bin/id "$@"\n',
        "getent": '#!/bin/sh\nexit 1\n',
        "chgrp": '#!/bin/sh\nexit 0\n',
    }.items():
        path = bins / name
        path.write_text(body)
        path.chmod(0o755)

    def prepare(root):
        for rel in ("etc/ordo", "etc/portage/package.use", "etc/portage/package.accept_keywords",
                    "etc/portage/sets", "etc/init.d", "etc/conf.d", "usr/local/bin",
                    "usr/share/speakersafetyd/apple", "usr/share/asahi-audio/j413",
                    "usr/share/alsa/ucm2/conf.d/macaudio", "var/lib/portage"):
            (root / rel).mkdir(parents=True, exist_ok=True)

    def run(root, env):
        script = re.sub(r"/(etc|usr|var|run)/", lambda m: f"{root}/{m.group(1)}/", installer)
        script = script.replace('here=$(dirname "$(readlink -f "$0")")', f'here={PLATFORM}')
        runner = tmp / "run.sh"
        runner.write_text("set -eu\n" + script)
        rc_log = tmp / "rc.log"
        rc_log.write_text("")
        return subprocess.run(["sh", str(runner)], capture_output=True, text=True, env={
            "PATH": f"{bins}:{os.environ['PATH']}", "RC_LOG": str(rc_log), **env}), rc_log

    # 硬条件缺 asahi-audio：拒绝装配，点名缺的包
    root = tmp / "a"
    prepare(root)
    result, _ = run(root, {"HAS_SPEAKER": "0", "HAS_AUDIO": "1"})
    assert result.returncode == 0, result.stderr
    assert "扬声器保护未装配" in result.stderr and "sys-apps/speakersafetyd" not in result.stderr
    assert "media-libs/asahi-audio-4.1" in result.stderr, result.stderr
    assert not (root / "etc/conf.d/speakersafetyd").exists()

    # 两个包都在但服务脚本缺失：拒绝装配并点名，不能 rc-update 失败中断安装
    root = tmp / "b"
    prepare(root)
    result, rc_log = run(root, {"HAS_SPEAKER": "0", "HAS_AUDIO": "0"})
    assert result.returncode == 0, result.stderr
    assert "包已声明但服务脚本缺失" in result.stderr and "etc/init.d/speakersafetyd" in result.stderr, result.stderr
    assert "speakersafetyd default" not in rc_log.read_text()
    assert not (root / "etc/conf.d/speakersafetyd").exists()

    # 硬条件齐、服务脚本在、校准文件缺：降级装配但逐条打印缺项
    root = tmp / "c"
    prepare(root)
    (root / "etc/init.d/speakersafetyd").write_text("#!/sbin/openrc-run\n")
    (root / "etc/init.d/speakersafetyd").chmod(0o755)
    result, rc_log = run(root, {"HAS_SPEAKER": "0", "HAS_AUDIO": "0"})
    assert result.returncode == 0, result.stderr
    assert "降级装配" in result.stderr, result.stderr
    for missing in ("j413.conf", "graph.json", "mic.json", "MacBook Air J413.conf"):
        assert missing in result.stderr, (missing, result.stderr)
    assert (root / "etc/conf.d/speakersafetyd").is_file(), "硬条件齐时必须装配"
    assert "add speakersafetyd default" in rc_log.read_text(), rc_log.read_text()

    # 全齐：没有降级/未装配告警
    root = tmp / "d"
    prepare(root)
    (root / "etc/init.d/speakersafetyd").write_text("#!/sbin/openrc-run\n")
    (root / "etc/init.d/speakersafetyd").chmod(0o755)
    for rel in ("usr/share/speakersafetyd/apple/j413.conf",
                "usr/share/asahi-audio/j413/graph.json",
                "usr/share/asahi-audio/j413/mic.json",
                "usr/share/alsa/ucm2/conf.d/macaudio/MacBook Air J413.conf"):
        (root / rel).write_text("x\n")
    result, rc_log = run(root, {"HAS_SPEAKER": "0", "HAS_AUDIO": "0"})
    assert result.returncode == 0, result.stderr
    assert "未装配" not in result.stderr and "降级" not in result.stderr, result.stderr
    assert (root / "etc/conf.d/speakersafetyd").is_file()
    assert "add speakersafetyd default" in rc_log.read_text()

# ---- B4 audio 失败标记 ----
with tempfile.TemporaryDirectory(prefix="ordo-speaker-mark-") as raw:
    tmp = Path(raw)
    bins = tmp / "bin"
    bins.mkdir()
    for name, body in {
        "pgrep": '#!/bin/sh\nexit "${DAEMON_MISSING:-0}"\n',
        "amixer": r'''#!/bin/sh
case "$3" in
    controls) printf "%s\n" "numid=42,iface=MIXER,name='Speaker Volume Unlock'" ;;
    cget) printf '  : values=%s\n' "${LOCK_STATE:-1}" ;;
esac
''',
        "pw-dump": r'''#!/bin/sh
if [ "${ROUTES_OK:-1}" = 1 ]; then
    printf '%s\n' '"node.name": "audio_effect.j413-convolver"' \
        '"node.name": "effect_output.j413-mic"'
fi
''',
    }.items():
        path = bins / name
        path.write_text(body)
        path.chmod(0o755)
    source = VERIFY.read_text()
    body = source[source.index("marker_dir="):source.index("\nkeyboard() {")]
    script = tmp / "audio.sh"
    script.write_text("set -u\n" + body + "\naudio\n")
    marker = tmp / "run/speaker-protection-missing"
    base_env = {"PATH": f"{bins}:{os.environ['PATH']}", "ORDO_RUN_DIR": str(tmp / "run")}

    def run(**env):
        return subprocess.run(["sh", str(script)], capture_output=True, text=True,
                              env={**base_env, **env})

    result = run(DAEMON_MISSING="1")
    assert result.returncode == 1 and marker.is_file()
    assert "speakersafetyd 未运行" in marker.read_text()

    result = run(LOCK_STATE="0")
    assert result.returncode == 1 and "音量锁未启用" in marker.read_text(), marker.read_text()

    result = run(ROUTES_OK="0")
    assert result.returncode == 1 and "DSP" in marker.read_text(), marker.read_text()

    result = run()
    assert result.returncode == 0 and not marker.exists(), result.stderr

# ---- B5 摄像头：例行不查，只有 --capture-camera 才查 ----
source = VERIFY.read_text()
guard = source[source.rindex('if [ "$capture" = --capture-camera ]; then'):]
guard = guard[:guard.index("\n    fi\n")]
assert "check '内置摄像头读取帧' camera" in guard
assert source.count("check '内置摄像头读取帧' camera") == 1
with tempfile.TemporaryDirectory(prefix="ordo-camera-") as raw:
    tmp = Path(raw)
    compatible = tmp / "compatible"
    compatible.write_bytes(b"apple,j413\0apple,t8112\0")
    script = tmp / "verify"
    script.write_text(source.replace("/proc/device-tree/compatible", str(compatible))
                      .replace("/run/ordo", str(tmp / "run")))
    env = {"PATH": os.environ["PATH"], "HOME": str(tmp), "XDG_CONFIG_HOME": str(tmp / "config")}
    routine = subprocess.run(["sh", str(script)], capture_output=True, text=True, env=env)
    assert "内置摄像头" not in routine.stdout, routine.stdout
    capture = subprocess.run(["sh", str(script), "--capture-camera"], capture_output=True,
                             text=True, env=env)
    assert "内置摄像头" in capture.stdout, capture.stdout

# ---- B6 背光 ----
with tempfile.TemporaryDirectory(prefix="ordo-backlight-") as raw:
    tmp = Path(raw)
    source = VERIFY.read_text()
    body = source[source.index("backlight() {"):source.index("\n\n# 桌面小组件输出")]
    body = body.replace("/sys/class/backlight", str(tmp / "backlight"))
    script = tmp / "backlight.sh"
    script.write_text("set -u\n" + body + "\nbacklight\n")

    def run():
        return subprocess.run(["sh", str(script)], capture_output=True, text=True)

    assert run().returncode == 1, "空目录必须红"
    (tmp / "backlight/intel_backlight").mkdir(parents=True)
    (tmp / "backlight/intel_backlight/max_brightness").write_text("0\n")
    assert run().returncode == 1, "max=0 必须红"
    (tmp / "backlight/intel_backlight/max_brightness").write_text("255\n")
    assert run().returncode == 0, "max>0 必须绿"
assert "check '屏幕背光设备可用于亮度调节' backlight" in source
assert "check '桌面小组件输出在已连接的显示器上' widgets" in source
# ppd：world.usb 不再声明，安装器不再启用服务
assert "power-profiles-daemon" not in (PLATFORM / "world.usb").read_text()
assert "power-profiles-daemon:default" not in (PLATFORM / "install-external.sh").read_text()

# ---- B7 Noctalia 小组件输出 ----
noctalia = NOCTALIA.read_text()
assert not re.search(r'^[ \t]*output[ \t]*=[ \t]*"Virtual-1"', noctalia, re.M), \
    "Noctalia 小组件不得写死 Virtual-1"
assert not re.search(r'^[ \t]*output[ \t]*=[ \t]*"', noctalia, re.M), \
    "小组件应走默认输出（省略 output 键）"
with tempfile.TemporaryDirectory(prefix="ordo-widget-") as raw:
    tmp = Path(raw)
    source = VERIFY.read_text()
    body = source[source.index("widgets() {"):source.index("\n\nbattery() {")]
    body = body.replace("/sys/class/drm", str(tmp / "drm"))
    script = tmp / "widgets.sh"
    script.write_text("set -u\n" + body + "\nwidgets\n")
    connected = tmp / "drm/card0-eDP-1"
    connected.mkdir(parents=True)
    (connected / "status").write_text("connected\n")
    disconnected = tmp / "drm/card0-HDMI-A-1"
    disconnected.mkdir()
    (disconnected / "status").write_text("disconnected\n")
    config_dir = tmp / "config/noctalia"
    config_dir.mkdir(parents=True)
    config = config_dir / "config.toml"

    def run():
        return subprocess.run(["sh", str(script)], capture_output=True, text=True,
                              env={"PATH": os.environ["PATH"], "XDG_CONFIG_HOME": str(tmp / "config")})

    config.write_text('[desktop_widgets.widget.clock]\n[desktop_widgets.widget.clock.settings]\nformat = "x"\n')
    assert run().returncode == 0, "省略 output 走默认输出"
    config.write_text('[desktop_widgets.widget.clock]\noutput = "eDP-1"\n')
    assert run().returncode == 0, "已连接的输出通过"
    config.write_text('[desktop_widgets.widget.clock]\noutput = "Virtual-1"\n')
    result = run()
    assert result.returncode == 1 and "Virtual-1" in result.stderr, (result.returncode, result.stderr)
    config.write_text('[desktop_widgets.widget.clock]\noutput = "HDMI-A-1"\n')
    assert run().returncode == 1, "未连接的输出必须红"
    config.unlink()
    assert run().returncode == 2, "配置缺失是待验（2），不是通过"

manual = (REPO / "docs/manual/10-m2-external.md").read_text()
assert "未支持" in manual and "apple-isp" in manual
assert "屏幕背光设备可用于亮度调节" in manual
print("B4/B5/B6/B7 speaker / camera / backlight / widget output: ok")
PY
