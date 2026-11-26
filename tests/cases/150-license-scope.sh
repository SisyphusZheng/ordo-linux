#!/bin/sh
# 门禁：许可证必须覆盖且只覆盖自己的东西
#
# 曾经：整个仓库（含 5 张 Omarchy 官方截图 + 35 张过程截图）
# 被一个 MIT 许可证笼统覆盖 —— 等于对别人的作品声称授权。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

case_name "许可证文件齐全"

for f in LICENSE LICENSE-NOTES.md licenses/GPL-2.0.txt licenses/CC-BY-SA-4.0.txt \
         licenses/LGPL-2.1.txt licenses/CDDL-1.0.txt licenses/MIT.txt; do
    assert_rc "$([ -f "$ROOT/$f" ] && echo 0 || echo 1)" 0 "$f 存在"
done

case_name "按内容类型分许可"

_lic="$(cat "$ROOT/LICENSE")"
assert_contains "$_lic" "GPL-2.0" "代码/配置用 GPL-2.0"
assert_contains "$_lic" "CC BY-SA 4.0" "文档/品牌用 CC BY-SA 4.0"
assert_not_contains "$_lic" "MIT License" "不再用单一 MIT"

case_name "不再声称拥有第三方素材"

# 仓库里不得有非自产的图片（运行时壁纸除外，它们由各自的生成脚本产出）
third_party="$(cd "$ROOT" && git ls-files '*.png' '*.jpg' '*.webp' 2>/dev/null \
    | grep -v '^config/desktop/wallpapers/' || true)"
assert_eq "$third_party" "" "没有来源不明的图片"

case_name "壁纸可被重新生成（证明自产）"

assert_rc "$([ -x "$ROOT/dev/gen-branding.sh" ] && echo 0 || echo 1)" 0 "有品牌资产生成脚本"
assert_contains "$(cat "$ROOT/dev/gen-branding.sh")" "wallpaper" "脚本会生成壁纸"

case_name "每张壁纸都绑定到真实生成器"

# 出处必须是脚本名 + 产物名的事实，不是「由某脚本生成」的措辞。
_bh="$ROOT/config/desktop/wallpapers/gen-blackhole.py"
_seven="$ROOT/dev/gen-wallpaper.py"
assert_rc "$([ -f "$_bh" ] && echo 0 || echo 1)" 0 "黑洞壁纸生成器存在"
assert_contains "$(cat "$_bh")" "wallpaper-blackhole.png" "生成器写出 wallpaper-blackhole.png"
assert_contains "$(cat "$_bh")" "deco-ring.png" "生成器写出 deco-ring.png"
assert_rc "$([ -f "$_seven" ] && echo 0 || echo 1)" 0 "默认壁纸生成器存在"
assert_contains "$(cat "$_seven")" "wallpaper-seven.png" "生成器写出 wallpaper-seven.png"

_notes="$(cat "$ROOT/LICENSE-NOTES.md")"
for _png in wallpaper-seven.png wallpaper-blackhole.png deco-ring.png; do
    assert_contains "$_notes" "$_png" "LICENSE-NOTES 记录 $_png 的出处"
done
assert_contains "$_notes" "gen-wallpaper.py" "LICENSE-NOTES 给出 wallpaper-seven 的生成器"
assert_contains "$_notes" "gen-blackhole.py" "LICENSE-NOTES 给出黑洞壁纸的生成器"
assert_not_contains "$_notes" '壁纸与 logo 由 `dev/gen-branding.sh` 生成' \
    "不再把全部壁纸归给 gen-branding.sh"

case_name "LICENSE-NOTES 说明了关键取舍"

_notes="$(cat "$ROOT/LICENSE-NOTES.md")"
assert_contains "$_notes" "为什么不是 MIT" "解释了为何弃用 MIT"
assert_contains "$_notes" "CDDL" "说明了 ZFS 的 CDDL 不构成派生作品"
assert_contains "$_notes" "LGPL-2.1" "overlay 补丁的 LGPL 义务已登记"
assert_contains "$_notes" "overlay/" "overlay 的许可归属已登记"
assert_contains "$_notes" "dev/" "dev/ 的许可归属已登记"
assert_contains "$_notes" "曾经的错误" "记录了第三方素材的历史问题"

finish
