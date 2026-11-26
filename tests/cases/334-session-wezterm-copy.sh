#!/bin/sh
# 回归：会话入口把 wezterm.lua 从只读软链落成用户可写副本
#
# 旧版 ordo config apply desktop / 旧镜像把 ~/.config/wezterm/wezterm.lua
# 软链到 root:root 的 /opt/ordo，而这份模板按手册要用户原地编辑，Noctalia 的
# wezterm 模板也会往里写色名 —— 实机报 "touch wezterm.lua: 权限不够"。
# 新装机的 apply 已改真实副本；会话入口负责把旧系统里的软链也修好。
set -eu
repo=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)
. "$repo/tests/lib/assert.sh"
scratch=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/home/.config/wezterm" "$scratch/bin" "$scratch/run"

python3 - "$scratch/run/bus" <<'PY'
import socket, sys
socket.socket(socket.AF_UNIX).bind(sys.argv[1])
PY

# 会话脚本里的部署路径换成仓库路径，其余逐字保留。
sed -e "s|/usr/local/bin/ordo-session-env|$repo/config/desktop/ordo-session-env|g" \
    "$repo/config/desktop/umbriel/ordo-umbriel-session" > "$scratch/session.sh"

for cmd in start-umbriel gentoo-pipewire-launcher xdg-user-dirs-update \
    dbus-update-activation-environment; do
    printf '#!/bin/sh\nexit 0\n' > "$scratch/bin/$cmd"
    chmod +x "$scratch/bin/$cmd"
done

_target="$scratch/home/.config/wezterm/wezterm.lua"
# 软链指向 scratch 里的模板副本：测试永不能写进仓库本体
cp "$repo/config/desktop/skel/.config/wezterm/wezterm.lua" "$scratch/template.lua"
ln -s "$scratch/template.lua" "$_target"

_run_session() {
    env -u XDG_CONFIG_HOME HOME="$scratch/home" XDG_RUNTIME_DIR="$scratch/run" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$scratch/run/bus" \
        PATH="$scratch/bin:$PATH" sh "$scratch/session.sh" \
        > "$scratch/out" 2> "$scratch/err"
}

_run_session

case_name "软链落成真实副本"

assert_rc "$([ -L "$_target" ] && echo 1 || echo 0)" 0 "不再是软链"
assert_rc "$([ -f "$_target" ] && echo 0 || echo 1)" 0 "是普通文件"
assert_eq "$(cat "$_target")" \
    "$(cat "$repo/config/desktop/skel/.config/wezterm/wezterm.lua")" "内容与模板一致"
assert_rc "$([ -w "$_target" ] && echo 0 || echo 1)" 0 "桌面用户可写"

case_name "再次登录不覆盖用户改动"

printf '%s\n' '-- ordo-test-user-edit' >> "$_target"
_run_session
assert_contains "$(cat "$_target")" "-- ordo-test-user-edit" "用户改动保留"
assert_not_contains "$(cat "$repo/config/desktop/skel/.config/wezterm/wezterm.lua")" \
    "-- ordo-test-user-edit" "测试不得写进仓库模板"

case_name "缺 xdg-user-dirs-update 时告警而不是静默跳过"

rm -f "$scratch/bin/xdg-user-dirs-update"
_run_session
assert_contains "$(cat "$scratch/err")" "缺少 xdg-user-dirs-update" "点出缺的包"
assert_contains "$(cat "$scratch/err")" "XDG 目录不初始化" "说明后果"

finish
