#!/bin/sh
# 门禁：Umbriel/Noctalia 配置的内部接线正确
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

_um="$ROOT/config/desktop/umbriel/config.toml"
_no="$ROOT/config/desktop/noctalia/config.toml"

case_name "Umbriel：自动启动 Noctalia"

_umt="$(cat "$_um")"
assert_contains "$_umt" 'autostart' "有 autostart"
assert_contains "$_umt" 'noctalia' "启动 Noctalia 外壳"

case_name "Umbriel：键位已接线"

assert_contains "$_umt" '"Mod+Return"' "Win+Return 开终端"
assert_contains "$_umt" '"Mod+S"' "Win+S 搜索"
assert_contains "$_umt" '"Mod+Q"' "Win+Q 关窗口"
assert_contains "$_umt" '"Mod+L"' "Win+L 锁屏"
assert_contains "$_umt" '"Mod+I"' "Win+I 切输入法"
assert_contains "$_umt" 'workspace-set-layout' "有布局切换动作"

case_name "Umbriel：布局与外观"

assert_contains "$_umt" 'mode = "scrolling"' "默认滚动布局"
assert_contains "$_umt" 'corner_radius' "有圆角"

case_name "Noctalia：壁纸驱动配色"

_not="$(cat "$_no")"
assert_contains "$_not" 'source = "wallpaper"' "配色来源是壁纸"
assert_contains "$_not" 'wallpaper_scheme = "faithful"' "用 faithful 提取算法（geek 绿）"
# 注释里可以提 fruit-salad（作为反例），实际取值不能是它
_actual="$(grep -E '^wallpaper_scheme' "$_no" | head -1)"
assert_not_contains "$_actual" 'fruit-salad' "实际取值不是 fruit-salad"

case_name "Noctalia：玻璃面板"

assert_contains "$_not" 'transparency_mode = "glass"' "面板为玻璃质感"

case_name "配置可解析"

for f in "$_um" "$_no"; do
    python3 -c "import tomllib,sys;tomllib.load(open(sys.argv[1],'rb'))" "$f" 2>/dev/null
    assert_rc "$?" 0 "$(basename "$(dirname "$f")")/config.toml 可解析"
done

finish
