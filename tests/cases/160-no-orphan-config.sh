#!/bin/sh
# 门禁：配置里引用的组件，必须在 world 里有对应声明
#
# 曾经：config/desktop/skel 下有 ghostty 与 nnn 的配置，但两个包早已被
# wezterm / yazi 取代；GTK settings.ini 引用 Arc-Dark / Papirus-Dark，
# 而这两个主题包从未进 world —— 配置写了，装完是一片默认灰。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

_world="$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$ROOT/config/world" | awk '{print $1}')"

has_pkg() { printf '%s\n' "$_world" | grep -qx "$1"; }

case_name "skel 里没有已移除组件的残留配置"

bad=""
for pair in "ghostty:x11-terms/ghostty" "nnn:app-misc/nnn" "foot:x11-terms/foot" \
            "waybar:gui-apps/waybar" "kde:config/kde"; do
    cfg="${pair%%:*}"; pkg="${pair##*:}"
    case "$cfg" in
        kde) [ -e "$ROOT/config/kde" ] && bad="$bad config/kde" ;;
        *)
            [ -e "$ROOT/config/desktop/skel/.config/$cfg" ] && ! has_pkg "$pkg" \
                && bad="$bad skel/$cfg(无 $pkg)"
            ;;
    esac
done
assert_eq "$bad" "" "没有孤儿配置"

case_name "GTK 主题包在 world 里"

gtk3="$ROOT/config/desktop/skel/.config/gtk-3.0/settings.ini"
if [ -f "$gtk3" ]; then
    for theme in $(sed -n 's/^gtk-theme-name=//p; s/^gtk-icon-theme-name=//p' "$gtk3"); do
        case "$theme" in
            Arc-Dark)        assert_rc "$(has_pkg x11-themes/arc-theme && echo 0 || echo 1)" 0 "Arc-Dark 有包" ;;
            Papirus-Dark)    assert_rc "$(has_pkg x11-themes/papirus-icon-theme && echo 0 || echo 1)" 0 "Papirus-Dark 有包" ;;
            Adwaita*|"") ;;  # 随 GTK 自带
            *)               assert_contains "$_world" "$theme" "主题 $theme 有来源" ;;
        esac
    done
fi

case_name "配置引用的命令都有包"

# 只查"必须存在否则功能直接缺失"的硬依赖。
# 引用来源是 current 桌面配置（umbriel/noctalia）与 scripts/。
for pair in "wezterm:x11-terms/wezterm" "umbriel:gui-wm/umbriel" \
            "noctalia:gui-apps/noctalia" "luciole:gui-apps/luciole" \
            "fcitx5:app-i18n/fcitx" "grim:gui-apps/grim" "slurp:gui-apps/slurp"; do
    cmd="${pair%%:*}"; pkg="${pair##*:}"
    if grep -rqn "\b$cmd\b" "$ROOT/config/desktop/umbriel/" \
                                    "$ROOT/config/desktop/noctalia/" \
                                    "$ROOT/scripts/" 2>/dev/null; then
        assert_rc "$(has_pkg "$pkg" && echo 0 || echo 1)" 0 "$cmd 被引用且有 $pkg"
    fi
done

finish
