#!/bin/sh
# 回归：P2-08 桌面/登录接线的三处死结
#
#   1) `_apply_desktop` 把 ~/.config/wezterm/wezterm.lua 软链到 /opt/ordo/config
#      （root:root）→ 用户按手册原地改模板报 "权限不够"；install.sh 的
#      `chown -R` 又跟随软链，把系统声明层 /opt/ordo/config 交给桌面用户。
#   2) 只建 /etc/user/runlevels/default/* 软链，从不启用 user.ordo 实例
#      → 「音频由用户级 OpenRC 管理」只是注释。
#   3) config/world 声明了 xdg-user-dirs，缺 /usr/bin/xdg-user-dirs-update 时
#      会话脚本静默跳过 → XDG 目录永不初始化。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ordo-desktop.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

case_name "wezterm.lua 落成用户可写的真实副本"
HOME="$tmp" XDG_CONFIG_HOME="$tmp/.config" sh "$ROOT/scripts/ordo-config" apply desktop >/dev/null 2>&1
assert_rc "$?" 0 "apply desktop 成功"
_wz="$tmp/.config/wezterm/wezterm.lua"
assert_rc "$([ -f "$_wz" ] && echo 0 || echo 1)" 0 "wezterm.lua 存在"
assert_rc "$([ -L "$_wz" ] && echo 1 || echo 0)" 0 "wezterm.lua 不是软链"
assert_eq "$(cat "$_wz")" "$(cat "$ROOT/config/desktop/skel/.config/wezterm/wezterm.lua")" \
    "副本内容等于声明模板"
assert_rc "$([ -w "$_wz" ] && echo 0 || echo 1)" 0 "用户可原地编辑（可写）"
assert_rc "$([ "$(ls -l "$_wz" | cut -c1-3)" = "-rw" ] && echo 0 || echo 1)" 0 \
    "权限是普通可读写文件（不是只读）"

case_name "其余桌面配置仍是软链（唯一事实来源不变）"
for _f in umbriel/config.toml noctalia/config.toml ordo/keys.md; do
    assert_rc "$([ -L "$tmp/.config/$_f" ] && echo 0 || echo 1)" 0 "$_f 仍是软链"
done

case_name "重复 apply 幂等，且旧软链会被替换成副本"
ln -sfn "$ROOT/config/desktop/skel/.config/wezterm/wezterm.lua" "$_wz"
_before="$(cat "$ROOT/config/desktop/skel/.config/wezterm/wezterm.lua")"
HOME="$tmp" XDG_CONFIG_HOME="$tmp/.config" sh "$ROOT/scripts/ordo-config" apply desktop >/dev/null 2>&1
assert_rc "$([ -L "$_wz" ] && echo 1 || echo 0)" 0 "旧软链被替换为普通文件"
assert_eq "$(cat "$_wz")" "$_before" "副本内容仍与声明一致"
assert_eq "$(cat "$ROOT/config/desktop/skel/.config/wezterm/wezterm.lua")" "$_before" \
    "apply 没有反向改写仓库里的声明文件"

case_name "install.sh 不再跟随软链改属主"
_install="$(cat "$ROOT/install.sh")"
assert_contains "$_install" 'chown -hR ordo:ordo /home/ordo/.config' "apply 之后用 chown -hR"
_ln_apply=$(grep -n 'ordo-config apply desktop' "$ROOT/install.sh" | tail -1 | cut -d: -f1)
_ln_chown=$(grep -n 'chown -hR ordo:ordo /home/ordo/.config' "$ROOT/install.sh" | tail -1 | cut -d: -f1)
[ "$_ln_apply" -lt "$_ln_chown" ]
assert_rc "$?" 0 "属主修正发生在部署之后"
# apply desktop 之后紧跟的那条 chown 不能是 -R（会跟软链进 /opt/ordo/config）
_after_apply="$(awk -v n="$_ln_apply" 'NR > n && NR <= n + 4' "$ROOT/install.sh")"
assert_not_contains "$_after_apply" 'chown -R ordo:ordo /home/ordo/.config' \
    "apply 之后没有 -R 的跟随式 chown"

case_name "user.ordo 实例被启用"
assert_contains "$_install" 'ln -sfn /etc/init.d/user /etc/init.d/user.ordo' "建 user.ordo 实例"
assert_contains "$_install" 'rc-update add user.ordo default' "user.ordo 进 default runlevel"
assert_contains "$_install" '/etc/user/runlevels/default/dbus' "用户级 runlevel 软链仍在"

case_name "xdg-user-dirs 缺失即停（不再静默跳过）"
assert_contains "$_install" 'command -v xdg-user-dirs-update' "安装期检查 xdg-user-dirs-update"
assert_contains "$_install" 'xdg-user-dirs 未随 @world 安装' "缺失时中止安装"
assert_contains "$(cat "$ROOT/config/world")" 'x11-misc/xdg-user-dirs' "world 仍声明该包"

finish
