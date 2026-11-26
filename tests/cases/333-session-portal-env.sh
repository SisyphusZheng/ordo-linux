#!/bin/sh
# 回归：D-Bus activation environment 的写入时序
#
# 旧版在 source ordo-session-env 时无条件把 WAYLAND_DISPLAY / XDG_CURRENT_DESKTOP
# 传给 dbus-update-activation-environment；此刻两者还不存在，按该命令语义等于
# 把变量从 activation environment 里删掉 —— portal 经 D-Bus 拉起后拿不到
# WAYLAND_DISPLAY / XDG_CURRENT_DESKTOP，找不到合成器。
# 修法：只同步已就绪的变量；合成器 autostart 在 socket 建好后补写。
set -eu
repo=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)
. "$repo/tests/lib/assert.sh"
scratch=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/run"

# 假会话总线 socket：ordo-session-env 只在 $XDG_RUNTIME_DIR/bus 不存在时才尝试起总线。
python3 - "$scratch/run/bus" <<'PY'
import socket, sys
socket.socket(socket.AF_UNIX).bind(sys.argv[1])
PY

# 桩按真实语义记录「变量名=当前值」，未设置的变量值为空。
cat > "$scratch/bin/dbus-update-activation-environment" <<'STUB'
#!/bin/sh
: "${DBUS_UPDATE_LOG:=/dev/null}"
for arg in "$@"; do
    case "$arg" in -*) continue ;; esac
    eval "val=\${$arg:-}"
    printf '%s=%s\n' "$arg" "$val" >> "$DBUS_UPDATE_LOG"
done
STUB
chmod +x "$scratch/bin/dbus-update-activation-environment"

_run() { # script
    env -u WAYLAND_DISPLAY -u DISPLAY -u XDG_CURRENT_DESKTOP -u XDG_SESSION_TYPE \
        HOME="$scratch/home" XDG_RUNTIME_DIR="$scratch/run" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$scratch/run/bus" \
        DBUS_UPDATE_LOG="$scratch/log" PATH="$scratch/bin:$PATH" \
        sh "$1"
}

cat > "$scratch/early.sh" <<EOF
#!/bin/sh
set -eu
. "$repo/config/desktop/ordo-session-env"
EOF
: > "$scratch/log"
_run "$scratch/early.sh"

case_name "尚未就绪的变量不写进 activation environment"

_log=$(cat "$scratch/log")
assert_contains "$_log" "XDG_RUNTIME_DIR=$scratch/run" "已就绪的变量照常同步"
assert_not_contains "$_log" "WAYLAND_DISPLAY=" "WAYLAND_DISPLAY 尚未存在，不得传空值"
assert_not_contains "$_log" "XDG_CURRENT_DESKTOP=" "XDG_CURRENT_DESKTOP 尚未 export，不得传空值"

case_name "合成器就绪后由函数补写"

cat > "$scratch/ready.sh" <<EOF
#!/bin/sh
set -eu
export XDG_CURRENT_DESKTOP=Umbriel WAYLAND_DISPLAY=wayland-9
. "$repo/config/desktop/ordo-session-env"
ordo_session_activate_environment
EOF
: > "$scratch/log"
_run "$scratch/ready.sh"
_log=$(cat "$scratch/log")
assert_contains "$_log" "WAYLAND_DISPLAY=wayland-9" "补写 WAYLAND_DISPLAY"
assert_contains "$_log" "XDG_CURRENT_DESKTOP=Umbriel" "补写 XDG_CURRENT_DESKTOP"

case_name "Umbriel autostart 真的调用补写（portal 靠它）"

_entry=$(python3 - "$repo" <<'PY'
import sys, tomllib
with open(sys.argv[1] + "/config/desktop/umbriel/config.toml", "rb") as fh:
    cfg = tomllib.load(fh)
found = [e for e in cfg["general"]["autostart"] if "ordo_session_activate_environment" in e]
if len(found) != 1:
    sys.exit("autostart 必须恰好有一条补写 activation environment 的条目：" + repr(cfg["general"]["autostart"]))
print(found[0])
PY
)
_entry=$(printf '%s\n' "$_entry" | sed "s|/usr/local/bin/ordo-session-env|$repo/config/desktop/ordo-session-env|g")
: > "$scratch/log"
env -u DISPLAY HOME="$scratch/home" XDG_RUNTIME_DIR="$scratch/run" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$scratch/run/bus" \
    DBUS_UPDATE_LOG="$scratch/log" PATH="$scratch/bin:$PATH" \
    WAYLAND_DISPLAY=wayland-7 XDG_CURRENT_DESKTOP=Umbriel \
    sh -c "$_entry"
_log=$(cat "$scratch/log")
assert_contains "$_log" "WAYLAND_DISPLAY=wayland-7" "autostart 时 WAYLAND_DISPLAY 已就绪"
assert_contains "$_log" "XDG_CURRENT_DESKTOP=Umbriel" "autostart 时桌面标识已就绪"

finish
