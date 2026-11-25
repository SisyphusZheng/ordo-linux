#!/bin/sh
# 门禁：许可证必须覆盖且只覆盖自己的东西
#
# 曾经：整个仓库（含 5 张 Omarchy 官方截图 + 35 张过程截图）
# 被一个 MIT 许可证笼统覆盖 —— 等于对别人的作品声称授权。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

case_name "许可证文件齐全"

for f in LICENSE LICENSE-NOTES.md licenses/GPL-2.0.txt licenses/CC-BY-SA-4.0.txt; do
    assert_rc "$([ -f "$ROOT/$f" ] && echo 0 || echo 1)" 0 "$f 存在"
done

case_name "按内容类型分许可"

_lic="$(cat "$ROOT/LICENSE")"
assert_contains "$_lic" "GPL-2.0" "代码/配置用 GPL-2.0"
assert_contains "$_lic" "CC BY-SA 4.0" "文档/品牌用 CC BY-SA 4.0"
assert_not_contains "$_lic" "MIT License" "不再用单一 MIT"

case_name "不再声称拥有第三方素材"

# 仓库里不得有非自产的图片（运行时壁纸除外，它们由 dev/gen-branding.sh 生成）
third_party="$(cd "$ROOT" && git ls-files '*.png' '*.jpg' '*.webp' 2>/dev/null \
    | grep -v '^config/desktop/wallpapers/' || true)"
assert_eq "$third_party" "" "没有来源不明的图片"

case_name "壁纸可被重新生成（证明自产）"

assert_rc "$([ -x "$ROOT/dev/gen-branding.sh" ] && echo 0 || echo 1)" 0 "有品牌资产生成脚本"
assert_contains "$(cat "$ROOT/dev/gen-branding.sh")" "wallpaper" "脚本会生成壁纸"

case_name "LICENSE-NOTES 说明了关键取舍"

_notes="$(cat "$ROOT/LICENSE-NOTES.md")"
assert_contains "$_notes" "为什么不是 MIT" "解释了为何弃用 MIT"
assert_contains "$_notes" "CDDL" "说明了 ZFS 的 CDDL 不构成派生作品"
assert_contains "$_notes" "曾经的错误" "记录了第三方素材的历史问题"

finish
