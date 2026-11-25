#!/bin/sh
# 回归：P1-6/P1-12/P1-11 声明层必须覆盖系统实际状态
#
# 三类历史缺陷：
#   - install.sh 用 emerge -1 装 8 个包，不在 world → depclean 会拆掉
#   - 没有任何 Flatpak 应用清单 → 首启无浏览器
#   - IME 存在 ibus/fcitx5 两套事实来源 → 改哪套生效说不清
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

case_name "P1-6 install.sh 的 emerge -1 包都在 world 里"

# 抽出 install.sh 里所有 `emerge -1 ...` 的 atom（排除 -C 删除与 @ 集合）
_install="$(cat "$ROOT/install.sh")"
oneshot="$(printf '%s\n' "$_install" \
    | grep -oE 'emerge -1[^|;&]*' \
    | grep -oE '[a-z][a-z0-9-]+/[a-z0-9][a-z0-9.+-]*' \
    | sort -u)"

world_atoms="$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$ROOT/config/world" | sort -u)"
# oneshot 白名单是「刻意的例外」，必须被显式登记
oneshot_ok=""
if [ -f "$ROOT/config/oneshot-packages" ]; then
    oneshot_ok="$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$ROOT/config/oneshot-packages" \
        | awk '{print $1}' | sort -u)"
fi

missing=""
for a in $oneshot; do
    # 排除误匹配（例如 2>/dev/null 被当成 dev/null）
    case "$a" in dev/null|*/null) continue ;; esac
    printf '%s\n' "$world_atoms" | grep -qx "$a" && continue
    printf '%s\n' "$oneshot_ok" | grep -qx "$a" && continue
    missing="$missing $a"
done

if [ -z "$missing" ]; then
    assert_rc 0 0 "所有 oneshot 包都在 world（$(printf '%s' "$oneshot" | grep -c .) 个）"
else
    # 允许例外，但必须有注释说明——这里把例外列出来，由人决定是否登记
    assert_rc "$missing" "" "有 oneshot 包未进 world:${missing}"
fi

case_name "P1-12 Flatpak 应用清单存在且格式合法"

assert_rc "$([ -d "$ROOT/config/apps.d" ] && echo 0 || echo 1)" 0 "config/apps.d 存在"

core="$ROOT/config/apps.d/00-core.list"
assert_rc "$([ -f "$core" ] && echo 0 || echo 1)" 0 "有 core 清单"

bad_apps=""
if [ -f "$core" ]; then
    while IFS= read -r line; do
        case "$line" in ''|\#*) continue ;; esac
        a="$(printf '%s' "$line" | sed 's/#.*//' | awk 'NF{print $1}')"
        case "$a" in
            *.*.*) ;;   # 形如 org.mozilla.firefox
            *) bad_apps="$bad_apps $a" ;;
        esac
    done < "$core"
fi
assert_eq "$bad_apps" "" "所有 app id 形如 org.domain.Name"

case_name "P1-11 IME 只有一套事实来源"

# 只禁「真正的配置行」：注释里解释历史是允许的
_ibus_config="$(printf '%s\n' "$_install" | grep -E '^[^#]*ibus' | grep -v '^[[:space:]]*#' || true)"
assert_eq "$_ibus_config" "" "install.sh 没有 ibus 的配置行（注释除外）"
assert_not_contains "$_install" 'sources=[("xkb", "us"), ("ibus"' "不再写 GNOME ibus 输入源"
assert_contains "$_install" 'config/desktop/99imm" /etc/env.d/99imm' "通用安装器部署输入法声明"
assert_contains "$(cat "$ROOT/config/desktop/99imm")" "GTK_IM_MODULE=wayland" "声明使用 fcitx5 的 Wayland 前端"

# 不能再有 plasma-workspace 的输入法脚本（KDE 已退场）
assert_rc "$([ -e "$ROOT/config/kde" ] && echo 1 || echo 0)" 0 "config/kde 不存在（已删除）"

finish
