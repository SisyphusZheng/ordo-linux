#!/bin/sh
# 门禁：登录管理器为 greetd + Noctalia Greeter，且不残留 SDDM/Qt 主题
#
# 背景：SDDM 依赖 Qt6 全家桶（实测连带 13 个 dev-qt 包、26 MB 库），
# 自定义主题需维护 618 行 QML，且 deviations #36/#37/#38 三条均出自该主题。
# 换为 greetd + Noctalia Greeter 后系统层零 GTK/Qt 依赖。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

_world="$(cat "$ROOT/config/world")"

case_name "world 声明 greetd 与 Noctalia Greeter"

printf '%s\n' "$_world" | grep -qx 'gui-libs/greetd'
assert_rc "$?" 0 "world 含 gui-libs/greetd"

printf '%s\n' "$_world" | grep -qx 'gui-libs/greetd'
assert_rc "$?" 0 "world 含 gui-libs/greetd"
printf '%s\n' "$_world" | grep -qx 'gui-apps/noctalia-greeter'
assert_rc "$?" 0 "world 含 gui-apps/noctalia-greeter"

case_name "world 不再含 SDDM"

printf '%s\n' "$_world" | grep -q 'sddm'
assert_rc "$?" 1 "world 无 sddm"

case_name "greetd 配置文件与 OpenRC 服务存在"

for f in config/desktop/greetd/config.toml config/desktop/greetd/greetd.initd; do
    assert_rc "$([ -f "$ROOT/$f" ] && echo 0 || echo 1)" 0 "$f 存在"
done

assert_rc "$([ -x "$ROOT/config/desktop/greetd/greetd.initd" ] && echo 0 || echo 1)" 0 "initd 可执行"

case_name "OpenRC 服务正确声明"

_initd="$(cat "$ROOT/config/desktop/greetd/greetd.initd")"
assert_contains "$_initd" "provide display-manager" "提供 display-manager 虚拟服务"
assert_contains "$_initd" 'command="/usr/bin/greetd"' "启动 greetd"
assert_contains "$_initd" "/etc/greetd/config.toml" "读取配置文件"

case_name "greetd 使用 Noctalia Greeter"

_toml="$(cat "$ROOT/config/desktop/greetd/config.toml")"
assert_contains "$_toml" "noctalia-greeter-session" "greeter 为 Noctalia Greeter"
assert_not_contains "$_toml" "tuigreet" "配置中不残留 tuigreet"
# Noctalia Greeter 通过 greeter-sync 与 Shell 共享壁纸/调色板，
# 不需要在 greetd 配置里硬编码任何颜色（旧 tuigreet 才需要 --theme 串）。
assert_not_contains "$_toml" "#[0-9a-fA-F]{6}" "不硬编码颜色（由 Noctalia 主题统一驱动）"

case_name "已删除 SDDM 主题目录"

assert_rc "$([ -e "$ROOT/config/sddm-theme" ] && echo 1 || echo 0)" 0 "config/sddm-theme 已移除"

case_name "install.sh 部署 greetd 而非 SDDM"

_install="$(cat "$ROOT/install.sh")"
assert_contains "$_install" "/etc/greetd/config.toml" "安装 greetd 配置"
assert_contains "$_install" "/etc/init.d/greetd" "安装 OpenRC 服务"
assert_not_contains "$_install" "/usr/share/sddm/themes" "不再部署 SDDM 主题"

case_name "greeter 已登记 keyword 例外"

_kw="$(cat "$ROOT/config/package.accept_keywords/desktop")"
assert_contains "$_kw" "gui-libs/greetd" "greetd 有 keyword 例外"
# tuigreet 已退场：world / 平台包集都不含它，keyword 例外是死配置（P2-11）。
assert_not_contains "$_kw" "gui-apps/tuigreet" "tuigreet 的 keyword 例外已删除"

case_name "world 不引入 Qt 依赖链"

# fcitx-gtk / fcitx-qt / fcitx-configtool 都会拖入 Qt 或 GTK immodule，
# 而 niri 下输入法经 text-input-v3 协议，由 fcitx5 自带的 libwaylandim.so 提供。
for pkg in app-i18n/fcitx-gtk app-i18n/fcitx-qt app-i18n/fcitx-configtool; do
    printf '%s\n' "$_world" | grep -qx "$pkg"
    assert_rc "$?" 1 "world 不含 $pkg"
done

# wpa_supplicant 的 gui USE 依赖 dev-qt/qtbase 与 qtsvg
assert_contains "$(cat "$ROOT/config/package.use/desktop")" "net-wireless/wpa_supplicant       -gui" \
    "wpa_supplicant 关闭 gui USE"

case_name "输入法仅需 fcitx + rime"

printf '%s\n' "$_world" | grep -qx 'app-i18n/fcitx'
assert_rc "$?" 0 "world 含 app-i18n/fcitx"
printf '%s\n' "$_world" | grep -qx 'app-i18n/fcitx-rime'
assert_rc "$?" 0 "world 含 app-i18n/fcitx-rime"

case_name "安装器不部署独立调色板"

# 配色由 Noctalia 从壁纸提取，install.sh 不应再写 palette.conf / themes 目录
_install="$(cat "$ROOT/install.sh")"
assert_not_contains "$_install" "/etc/ordo/themes" "不再部署 themes 目录"
assert_not_contains "$_install" "/etc/ordo/palette.conf" "不再写 palette.conf"


case_name "音频栈的用户服务已声明"

# Noctalia 的音量 OSD 与控制中心依赖 PulseAudio 协议。
# pipewire 未启动时客户端连不上，OSD 不显示、控制中心音量条为空。
_install="$(cat "$ROOT/install.sh")"
assert_contains "$_install" "/etc/user/runlevels/default" "启用用户级 runlevel"
assert_contains "$_install" "pipewire" "启用 pipewire 用户服务"

finish
