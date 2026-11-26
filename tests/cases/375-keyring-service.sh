#!/bin/sh
# 回归：Secret Service 回归后的接线完整性
#
# 判据：
#   1) greetd PAM 在 include login 之后有 auth/session 两行 pam_gnome_keyring；
#   2) 会话在 D-Bus 之后、start-umbriel（Noctalia autostart）之前启动守护进程；
#   3) world 有 gnome-keyring、mask 不再遮蔽、本地 libsecret 配方已退场；
#   4) 偏离文档标记「已收回」，README/手册不再声称没有密钥服务。
# 任一项被还原都应让本用例变红。
set -eu
cd "$(dirname "$(readlink -f "$0")")/../.."
PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
from pathlib import Path
import re
import subprocess
import tomllib

def lines(path):
    return Path(path).read_text().splitlines()

def active(lines_):
    return [(i, line) for i, line in enumerate(lines_) if line.strip() and not line.lstrip().startswith("#")]

def find(lines_, needle):
    return [i for i, line in enumerate(lines_) if needle in line]

# ---- 1) PAM 两行，且在 include login 之后 ----
print("== greetd PAM 接线")
pam = lines("config/desktop/greetd/pam.d-greetd")
def pam_index(pattern):
    hits = [i for i, line in active(pam) if re.match(pattern, line)]
    assert len(hits) == 1, f"{pattern} 应恰好出现一次：{hits}"
    return hits[0]
auth_inc = pam_index(r"^auth\s+include\s+login\s*$")
auth_key = pam_index(r"^auth\s+optional\s+pam_gnome_keyring\.so\s*$")
session_inc = pam_index(r"^session\s+include\s+login\s*$")
session_key = pam_index(r"^session\s+optional\s+pam_gnome_keyring\.so\s+auto_start\s*$")
assert auth_inc < auth_key, "auth 行必须在 include login 之后"
assert session_inc < session_key, "session 行必须在 include login 之后"

# ---- 2) 会话启动顺序：dbus -> keyring -> autostart ----
print("== 会话启动顺序")
session = lines("config/desktop/umbriel/ordo-umbriel-session")
env = lines("config/desktop/ordo-session-env")
source = find(session, ". /usr/local/bin/ordo-session-env")
exec_start = find(session, "exec start-umbriel")
assert len(source) == 1 and len(exec_start) == 1
assert source[0] < exec_start[0], "必须 source 会话环境后才 exec 合成器"
kr_session = find(session, "gnome-keyring-daemon --start --components=secrets")
kr_env = find(env, "gnome-keyring-daemon --start --components=secrets")
if kr_session:
    assert len(kr_session) == 1
    keyring_pos = kr_session[0]
    assert source[0] < keyring_pos < exec_start[0], \
        "keyring 必须在 D-Bus 就绪（source）之后、autostart（exec start-umbriel）之前"
    kr_lines = session
else:
    assert len(kr_env) == 1, "会话与环境脚本都没有启动 gnome-keyring-daemon"
    keyring_pos = kr_env[0]
    bus = find(env, "export DBUS_SESSION_BUS_ADDRESS")
    assert bus and bus[-1] < keyring_pos, "keyring 必须在 D-Bus 会话总线就绪之后"
    assert source[0] < exec_start[0]
    kr_lines = env
assert any("GNOME_KEYRING_CONTROL" in line and i < keyring_pos
           for i, line in enumerate(kr_lines)), "启动前必须有 GNOME_KEYRING_CONTROL 去重判据"
cfg = tomllib.loads(Path("config/desktop/umbriel/config.toml").read_text())
autostart = cfg["general"]["autostart"]
assert any("noctalia" in entry for entry in autostart), "autostart 必须包含 Noctalia"
assert not any("gnome-keyring-daemon" in entry for entry in autostart), \
    "keyring 不得推迟到 autostart（那样会晚于 Noctalia）"

# ---- 3) world / mask / overlay / package.use ----
print("== 声明层")
world = [line.strip() for line in lines("config/world") if line.strip() and not line.lstrip().startswith("#")]
assert "app-crypt/libsecret" in world
assert "gnome-base/gnome-keyring" in world
assert "app-crypt/libsecret::local" not in world, "本地 libsecret 配方必须退场"
assert not Path("config/package.mask/ordo-keyring").exists(), "mask 文件必须删除"
assert not Path("overlay/app-crypt/libsecret").exists(), "本地 libsecret overlay 必须删除"
use = lines("config/package.use/ordo-keyring")
assert "sys-auth/pambase gnome-keyring" in use
assert "app-crypt/pinentry -gtk -keyring ncurses" in use

# ---- 4) 文档：偏离已收回、契约反转 ----
print("== 文档")
dev = Path("docs/deviations.md").read_text()
heading = "### libsecret 客户端与 Secret Service 分开安装"
start = dev.index(heading)
tail = dev[start + len(heading):]
end = re.search(r"\n#{2,3} ", tail)
section = dev[start:] if end is None else dev[start:start + len(heading) + end.start()]
assert "已收回" in section, "偏离条目必须标记已收回"
assert "2026-11-26" in section, "收回日期必须可核"
assert "跨会话" in section, "必须写明收回原因（跨会话保存密码）"
assert "PAM" in section, "必须写明 PAM 自动解锁"
assert "默认桌面没有全局密钥服务" not in section, "旧结论必须删除"

readme = Path("config/desktop/README.md").read_text()
rstart = readme.index("## 密钥服务契约")
rend = readme.find("\n## ", rstart + 1)
rsec = readme[rstart:] if rend == -1 else readme[rstart:rend]
assert "gnome-keyring" in rsec
assert "PAM" in rsec and "自动" in rsec and "解锁" in rsec
assert "没有全局 Secret Service" not in rsec, "README 不能再声称没有服务"
assert "首启自动登录" in rsec, "必须登记 initial_session 的限制"

manual = Path("docs/manual/02-first-login.md").read_text()
assert "面板点一下" in manual, "手册应改为面板直连"
assert "旧镜像" in manual and "ordo-wifi" in manual, "ordo-wifi 降级为旧镜像兜底"
assert "默认不安装 GNOME Keyring" not in manual, "旧的「不安装」结论必须删除"

changelog = Path("CHANGELOG.md").read_text()
unreleased = changelog[changelog.index("## [Unreleased]"):changelog.index("## [0.1.0]")]
assert "gnome-keyring" in unreleased and "Secret Service" in unreleased, \
    "Unreleased 必须记录密钥服务回归"

# ---- 5) 会话行为：启动一次、导出、失败不阻断 ----
print("== 会话行为")
import os
import socket
import tempfile

with tempfile.TemporaryDirectory() as td:
    td = Path(td)
    bin_ = td / "bin"
    bin_.mkdir()
    home = td / "home"
    home.mkdir()
    runtime = td / "run"
    runtime.mkdir()
    session_env = td / "session-env"
    session_env.write_text(
        "#!/bin/sh\n"
        "ordo_session_activate_environment() { printf 'called\\n' >> \"$ACT_LOG\"; }\n")
    # 会话脚本逐字复制，只把环境脚本换成桩（不在这里重复验证 D-Bus 启动）。
    session_src = Path("config/desktop/umbriel/ordo-umbriel-session").read_text()
    session_src = session_src.replace(". /usr/local/bin/ordo-session-env",
                                      f". {session_env}")
    session = td / "session"
    session.write_text(session_src)
    session.chmod(0o755)
    (bin_ / "start-umbriel").write_text(
        "#!/bin/sh\nprintf '%s\\n' \"${GNOME_KEYRING_CONTROL:-}\" > \"$SESSION_LOG\"\n")
    (bin_ / "xdg-user-dirs-update").write_text("#!/bin/sh\nexit 0\n")
    (bin_ / "gentoo-pipewire-launcher").write_text("#!/bin/sh\nexit 0\n")
    (bin_ / "gnome-keyring-daemon").write_text(
        "#!/bin/sh\n"
        "printf '%s\\n' \"$*\" >> \"$KR_LOG\"\n"
        "[ \"${KR_FAIL:-0}\" = 1 ] && exit 1\n"
        "[ \"${KR_EMPTY:-0}\" = 1 ] && exit 0\n"
        "printf 'GNOME_KEYRING_CONTROL=%s\\n' \"$KR_CONTROL\"\n")
    for entry in bin_.iterdir():
        entry.chmod(0o755)

    def run_session(**overrides):
        env_ = {
            "PATH": f"{bin_}:{os.environ['PATH']}",
            "HOME": str(home),
            "XDG_RUNTIME_DIR": str(runtime),
            "XDG_CONFIG_HOME": str(home / ".config"),
            "KR_LOG": str(td / "kr.log"),
            "KR_CONTROL": str(runtime / "keyring"),
            "SESSION_LOG": str(td / "session.log"),
            "ACT_LOG": str(td / "activate.log"),
        }
        env_.update(overrides)
        for key in ("GNOME_KEYRING_CONTROL",):
            if key not in overrides:
                env_.pop(key, None)
        return subprocess.run(["sh", str(session)], env=env_,
                              capture_output=True, text=True)

    control = str(runtime / "keyring")
    result = run_session()
    assert result.returncode == 0, result.stderr
    calls = (td / "kr.log").read_text().splitlines()
    assert calls == ["--start --components=secrets"], calls
    assert (td / "session.log").read_text().strip() == control, "控制目录必须导出给子进程"
    assert (td / "activate.log").read_text().strip() == "called", \
        "启动后必须补写 D-Bus activation environment"

    (td / "kr.log").unlink()
    result = run_session(GNOME_KEYRING_CONTROL="/preset")
    assert result.returncode == 0, result.stderr
    assert not (td / "kr.log").exists(), "已有 GNOME_KEYRING_CONTROL 时不得重复启动"
    assert (td / "session.log").read_text().strip() == "/preset"

    result = run_session(KR_FAIL="1")
    assert result.returncode == 0, "守护进程启动失败不得阻断会话"
    assert "启动失败" in result.stderr
    assert (td / "session.log").read_text().strip() == ""

# ---- 6) activation environment 必须带上 GNOME_KEYRING_CONTROL ----
print("== activation environment")
with tempfile.TemporaryDirectory() as td:
    td = Path(td)
    bin_ = td / "bin"
    bin_.mkdir()
    runtime = td / "run"
    runtime.mkdir()
    sock = socket.socket(socket.AF_UNIX)
    sock.bind(str(runtime / "bus"))
    sock.close()
    (bin_ / "dbus-update-activation-environment").write_text(
        "#!/bin/sh\n"
        "for arg in \"$@\"; do\n"
        "    case \"$arg\" in -*) continue ;; esac\n"
        "    eval \"val=\\${$arg:-}\"\n"
        "    printf '%s=%s\\n' \"$arg\" \"$val\" >> \"$DBUS_LOG\"\n"
        "done\n")
    (bin_ / "dbus-update-activation-environment").chmod(0o755)
    probe = td / "probe.sh"
    probe.write_text(
        "#!/bin/sh\n"
        "set -eu\n"
        f". {Path('config/desktop/ordo-session-env').resolve()}\n")
    log = td / "dbus.log"
    env_ = {
        "PATH": f"{bin_}:{os.environ['PATH']}",
        "HOME": str(td / "home"),
        "XDG_RUNTIME_DIR": str(runtime),
        "DBUS_SESSION_BUS_ADDRESS": f"unix:path={runtime / 'bus'}",
        "GNOME_KEYRING_CONTROL": f"{runtime / 'keyring'}",
        "DBUS_LOG": str(log),
    }
    env_.pop("WAYLAND_DISPLAY", None)
    result = subprocess.run(["sh", str(probe)], env=env_, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert f"GNOME_KEYRING_CONTROL={runtime / 'keyring'}" in log.read_text()

# ---- 7) 策略脚本自身验收 ----
print("== keyring-policy check")
subprocess.run(["sh", "config/desktop/keyring-policy.sh", "check"], check=True)
print("ok")
PY
