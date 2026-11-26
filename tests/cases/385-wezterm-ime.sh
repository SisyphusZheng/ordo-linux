#!/bin/sh
# 回归：C3 wezterm 属主/可写、C4 输入法收敛
#
# C3：旧镜像把 ~/.config/wezterm/wezterm.lua 软链到 root 只读的 /opt/ordo，
#     Noctalia 的 wezterm 模板每次登录 touch 失败。会话入口必须把它落成
#     桌面用户可写的真实副本；02 手册给旧机一次性步骤。
# C4：world 不装 fcitx-qt，环境里就不能留 QT_IM_MODULE=fcitx；
#     GTK/Qt 走 text-input-v3，X11 走 Umbriel 内置 XWayland 的 XIM。
set -eu
repo=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)
. "$repo/tests/lib/assert.sh"

case_name "C4 环境变量不再引用未安装的 Qt immodule"

imm="$(cat "$repo/config/desktop/99imm")"
assert_eq "$(printf '%s\n' "$imm" | grep -E '^[[:space:]]*QT_IM_MODULE=' || true)" "" \
    "99imm 不设 QT_IM_MODULE"
assert_contains "$imm" "GTK_IM_MODULE=wayland" "GTK 走 text-input-v3"
assert_contains "$imm" 'XMODIFIERS="@im=fcitx"' "X11 保留 XMODIFIERS"
assert_contains "$imm" "SDL_IM_MODULE=fcitx" "SDL 保留显式后端"

env="$(cat "$repo/config/desktop/ordo-session-env")"
assert_eq "$(printf '%s\n' "$env" | grep -E '^[[:space:]]*(export[[:space:]]+)?QT_IM_MODULE=' || true)" "" \
    "会话环境不导出 QT_IM_MODULE"
assert_contains "$env" "export GTK_IM_MODULE=wayland" "会话环境导出 GTK_IM_MODULE"
assert_contains "$env" "export XMODIFIERS=@im=fcitx" "会话环境导出 XMODIFIERS"

world="$(cat "$repo/config/world")"
assert_contains "$world" "app-i18n/fcitx" "world 有 fcitx"
assert_contains "$world" "app-i18n/fcitx-rime" "world 有 rime"
assert_not_contains "$world" "app-i18n/fcitx-qt" "world 不装 fcitx-qt（否则才需要 QT_IM_MODULE）"
assert_not_contains "$world" "app-i18n/fcitx-gtk" "world 不装 fcitx-gtk"

case_name "C4 手册收敛为一张表，不再教 fcitx-gtk / xwayland-satellite"

manual="$(cat "$repo/docs/manual/04-input-method.md")"
assert_contains "$manual" "| 变量 | 值 | 谁用 | 为什么 |" "04 有唯一变量表"
assert_contains "$manual" "| \`QT_IM_MODULE\` | **不设**" "04 写明 Qt 变量不设"
assert_contains "$manual" "text-input-v3" "04 解释协议路径"
assert_not_contains "$manual" "经 \`xwayland-satellite\` 运行" "04 不再说 X11 经 xwayland-satellite"
assert_contains "$manual" "Umbriel 内置的 XWayland" "04 指明 X11 由 Umbriel 内置 XWayland 承载"

trouble="$(cat "$repo/docs/manual/08-troubleshooting.md")"
assert_contains "$trouble" "QT_IM_MODULE\` 不应设置" "08 与 04 口径一致"
assert_not_contains "$trouble" "fcitx-gtk 模块装了吗" "08 不再教检查未安装的 fcitx-gtk"
readme="$(cat "$repo/README.md")"
assert_not_contains "$readme" "fcitx-gtk" "README 不再声称安装 fcitx-gtk"

case_name "C3 旧镜像迁移写进 02 手册"

first="$(cat "$repo/docs/manual/02-first-login.md")"
assert_contains "$first" "wezterm.lua" "02 点名 wezterm 配置"
assert_contains "$first" "ordo config apply desktop" "02 给出修复命令"
assert_contains "$first" "旧镜像升级后的一次性检查" "02 有一次性迁移章节"

case_name "C3 会话入口把软链落成用户可写副本"

tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
home="$tmp/home"
mkdir -p "$home/.config" "$tmp/bin"
printf '%s\n' '-- ordo wezterm template --' > "$tmp/wezterm-src.lua"
chmod 644 "$tmp/wezterm-src.lua"
mkdir -p "$home/.config/wezterm"
ln -sfn "$tmp/wezterm-src.lua" "$home/.config/wezterm/wezterm.lua"

cat > "$tmp/envstub" <<'ENVSTUB'
ordo_session_activate_environment() { :; }
ENVSTUB
for cmd in start-umbriel xdg-user-dirs-update gentoo-pipewire-launcher; do
    cat > "$tmp/bin/$cmd" <<'STUB'
#!/bin/sh
exit 0
STUB
    chmod 755 "$tmp/bin/$cmd"
done

# 目标机是 GNU coreutils；开发机（macOS）的 readlink 没有 -f，补一个等价的。
cat > "$tmp/bin/readlink" <<'RL'
#!/bin/sh
if [ "${1:-}" = -f ]; then
    python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$2"
else
    exec /usr/bin/readlink "$@"
fi
RL
chmod 755 "$tmp/bin/readlink"

# 只替换绝对路径的 env 源；其余逐字保留，验的是真实会话脚本。
awk -v stub="$tmp/envstub" '
    $0 == ". /usr/local/bin/ordo-session-env" { print ". " stub; next }
    { print }
' "$repo/config/desktop/umbriel/ordo-umbriel-session" > "$tmp/session"
chmod 755 "$tmp/session"

PATH="$tmp/bin:$PATH" HOME="$home" XDG_CONFIG_HOME="$home/.config" \
    ORDO_CONF_DIR="$repo/config" \
    sh "$tmp/session" > "$tmp/out" 2> "$tmp/err"

wz="$home/.config/wezterm/wezterm.lua"
assert_rc "$([ -f "$wz" ] && echo 0 || echo 1)" 0 "wezterm.lua 是普通文件"
assert_rc "$([ -L "$wz" ] && echo 1 || echo 0)" 0 "wezterm.lua 不再是软链"
assert_rc "$([ -w "$wz" ] && echo 0 || echo 1)" 0 "wezterm.lua 当前用户可写"
assert_eq "$(cat "$wz")" "$(cat "$tmp/wezterm-src.lua")" "副本内容与声明一致"
assert_eq "$(ls -ldn "$wz" | awk '{ print $3 }')" "$(id -u)" "副本属主是当前桌面用户"

case_name "C3/C2 会话入口部署用户级 portals.conf"

pconf="$home/.config/xdg-desktop-portal/portals.conf"
assert_rc "$([ -f "$pconf" ] && echo 0 || echo 1)" 0 "用户级 portals.conf 已落位"
if [ -f "$pconf" ]; then
    assert_contains "$(cat "$pconf")" "org.freedesktop.impl.portal.FileChooser=umbriel" \
        "FileChooser 指向 umbriel"
    assert_contains "$(cat "$pconf")" "org.freedesktop.impl.portal.Screenshot=umbriel" \
        "Screenshot 指向 umbriel"
    assert_contains "$(cat "$pconf")" "org.freedesktop.impl.portal.ScreenCast=umbriel" \
        "ScreenCast 指向 umbriel"
    assert_contains "$(cat "$pconf")" "default=gtk" "其余接口走 gtk"
fi

case_name "C3 已存在的真实文件不被会话覆盖"

printf '%s\n' '-- user edited --' > "$wz"
PATH="$tmp/bin:$PATH" HOME="$home" XDG_CONFIG_HOME="$home/.config" \
    ORDO_CONF_DIR="$repo/config" \
    sh "$tmp/session" > "$tmp/out2" 2> "$tmp/err2"
assert_eq "$(cat "$wz")" "-- user edited --" "真实文件保留用户改动"

finish
