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

case_name "渲染节点按驱动名认（VM 的 virtio_gpu 不被当成无节点）"
_env_src="$(cat "$repo/config/desktop/ordo-session-env")"
assert_contains "$_env_src" '*/asahi|*/virtio_gpu' "探测接受 virtio_gpu 驱动"
assert_contains "$_env_src" 'virtio_gpu_dri.so' "同时看 virtio_gpu 的 Mesa 驱动"
assert_not_contains "$_env_src" 'for _mesa in /usr/lib*/dri/asahi_dri.so; do' "不再只按 asahi_dri.so 门控"

case_name "渲染等待只按设备树 apple,j413，不按 /etc/ordo/platform"

# 把脚本里的绝对路径换到夹具目录，其余逻辑逐字保留。
sed -e "s|/sys/class/drm|$scratch/sys/class/drm|g" \
    -e "s|/dev/dri|$scratch/dev/dri|g" \
    -e "s|/usr/lib\*/dri/|$scratch/lib/dri/|g" \
    -e "s|/proc/device-tree/compatible|$scratch/compatible|g" \
    -e "s|/etc/ordo/platform|$scratch/platform|g" \
    "$repo/config/desktop/ordo-session-env" > "$scratch/session-env"
mkdir -p "$scratch/sys/class/drm" "$scratch/dev/dri" "$scratch/lib/dri" \
    "$scratch/drivers" "$scratch/home"
: > "$scratch/lib/dri/asahi_dri.so"
printf '#!/bin/sh\nexit 0\n' > "$scratch/bin/modinfo"
chmod +x "$scratch/bin/modinfo"
# 故意把平台标签写成 m2（不是 m2-native）：旧版拿它做门控，会跳过等待。
printf 'm2\n' > "$scratch/platform"
printf 'apple,j413\000apple,t8112\000' > "$scratch/compatible"

cat > "$scratch/probe.sh" <<EOF
#!/bin/sh
. "$scratch/session-env"
printf '%s|%s|%s\n' "\${WLR_RENDERER:-}" "\${WLR_RENDER_DRM_DEVICE:-}" "\${ORDO_ASAHI_RENDER_NODE_TIMEOUT:-}"
EOF

_run_probe() {
    env -u WLR_RENDERER -u WLR_RENDER_DRM_DEVICE -u ORDO_ASAHI_RENDER_NODE_TIMEOUT \
        HOME="$scratch/home" XDG_RUNTIME_DIR="$scratch/run" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$scratch/run/bus" \
        PATH="$scratch/bin:$PATH" sh "$scratch/probe.sh"
}

# AGX 节点在登录后约 0.3s 才出现：只有真的等待才等得到。
(
    sleep 0.3
    mkdir -p "$scratch/sys/class/drm/renderD128/device"
    ln -s "$scratch/drivers/asahi" "$scratch/sys/class/drm/renderD128/device/driver"
    : > "$scratch/dev/dri/renderD128"
) &
_waiter=$!
_out=$(_run_probe)
wait "$_waiter"
assert_eq "$_out" "gles2|$scratch/dev/dri/renderD128|" \
    "j413 + 平台标签 m2：仍等待并采用 AGX 节点"

case_name "非 j413 设备树不等待（平台名不能单独触发）"

rm -rf "$scratch/sys/class/drm/renderD128" "$scratch/dev/dri/renderD128"
printf 'linux,dummy-virt\000' > "$scratch/compatible"
printf 'm2-native\n' > "$scratch/platform"
_out=$(_run_probe)
assert_eq "$_out" "pixman||" "无 apple,j413 时不等待、不设超时标记"

finish
