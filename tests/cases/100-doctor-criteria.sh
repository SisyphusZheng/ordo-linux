#!/bin/sh
# 回归：P1-20 / P2 doctor 的判据必须守得住 AGENTS.md 的禁止事项
#
# 曾经：AGENTS.md 列了 7 条「不许」，doctor 一条判据都没有；
# 且判 systemd 用的是 `command -v systemctl`，会被自家装的
# sys-apps/systemd-utils[boot] 误伤。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

_doctor="$(cat "$ROOT/scripts/doctor")"

case_name "P1-20 判 systemd 用 PID1 而不是 systemctl 存在性"

assert_contains "$_doctor" "/proc/1/comm" "读取 PID1 的命令名"
assert_not_contains "$_doctor" 'if command -v systemctl >/dev/null 2>&1; then bad "检测到 systemctl' \
    "不再用 systemctl 命令存在性判 systemd"

case_name "AGENTS 禁令有机器判据"

assert_contains "$_doctor" "MAKEOPTS" "检查 MAKEOPTS 不超过 nproc"
assert_contains "$_doctor" "ACCEPT_KEYWORDS" "检查宽泛 keyword"
assert_contains "$_doctor" "zfs_arc_max" "检查 ARC 上限（deviations #48）"
assert_contains "$_doctor" "第二套回滚" "检查是否引入第二套回滚机制"

case_name "P2 doctor 的 atom 比对不用正则（避免 libc++ 之类崩）"

assert_not_contains "$_doctor" 'grep -qE "^\${_base}' "不再把 atom 当 ERE 用"
assert_contains "$_doctor" "awk -v a=" "改用 awk 做字面量比较"

case_name "P2 doctor 不再用 -d 匹配 glob（SC2144）"

assert_not_contains "$_doctor" '[ ! -d /var/db/pkg/"$_atom"-* ]' "不再用 -d 对 glob"

case_name "doctor 有 skip（无法判定）语义"

assert_contains "$_doctor" "n_skip" "统计无法判定项"
assert_contains "$_doctor" 'exit "$ORDO_EXIT_UNKNOWN"' "无法判定时 exit 2"

case_name "doctor 检查 GUI state 覆盖声明（2026-11-22 三次实机事故）"

assert_contains "$_doctor" "settings.toml" "读 noctalia 的 GUI state 文件"
assert_contains "$_doctor" "钉了旧壁纸" "壁纸路径被 state 覆盖时报问题"
assert_contains "$_doctor" "WOMISS" "widget_order 缺声明 widget（不渲染事故）"
assert_contains "$_doctor" "PLDIFF" "plugins.enabled 被 state 覆盖时报问题"
assert_contains "$_doctor" "定位不到桌面用户" "定位不到桌面用户时不假绿灯"
assert_contains "$_doctor" "从未覆盖声明" "无 state 文件时按无覆盖通过"

case_name "doctor 检查 GUI state 的 theme 键族（2026-11-22 第四次事故）"

assert_contains "$_doctor" "THSRC" "theme.source 被 state 覆盖时报问题"
assert_contains "$_doctor" "THFM" "wallpaper.fill_mode 被 state 覆盖时报问题"
assert_contains "$_doctor" "THCOMM" "state 钉了声明没有的 community_palette 时报问题"

case_name "doctor 的死栈判据已换成当前栈（ADR 0011）"

assert_not_contains "$_doctor" "plasma/shells" "不再检查 KDE plasma shells"
assert_contains "$_doctor" "command -v umbriel" "检查合成器 umbriel"
assert_contains "$_doctor" "command -v noctalia" "检查外壳 noctalia"
assert_contains "$_doctor" "command -v luciole" "检查文件管理 luciole"
assert_contains "$_doctor" "noctalia-greeter-session" "检查 greeter 会话脚本"
assert_contains "$_doctor" "umbriel.desktop" "检查 umbriel 会话文件"
assert_contains "$_doctor" "for _legacy in niri ashell waybar" "旧栈二进制装着即报 ✘"

finish
