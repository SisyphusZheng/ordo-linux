#!/bin/sh
# 门禁：文档只陈述事实与规格，不含评价性措辞与过程叙述
#
# 例外：ADR 的「证据/后果」段允许复述实测结论，
# 但不得使用比喻、情绪化描述或对自身工作的评价。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

DOCS="README.md AGENTS.md CONTRIBUTING.md SECURITY.md CHANGELOG.md LICENSE-NOTES.md"
ALL_DOCS="$DOCS $(cd "$ROOT" && git ls-files 'docs/*.md' 'docs/**/*.md' 2>/dev/null | tr '\n' ' ')"

case_name "无评价性措辞"

# 这些词把陈述变成评价
banned_eval='教训|战役|惊艳|优雅|完美|强大|终极|真凶|天花板|巴士因子|小而全知|诚实|不是巧合|极具|一眼|死死|血统|血泪|幽灵|铁律|值得用|存在的理由'
bad=""
for f in $ALL_DOCS; do
    [ -f "$ROOT/$f" ] || continue
    hit="$(grep -nE "$banned_eval" "$ROOT/$f" 2>/dev/null | head -2)"
    [ -n "$hit" ] && bad="$bad
$f: $hit"
done
assert_eq "$bad" "" "文档不含评价性措辞"

case_name "无过程性标题"

# 只禁「时间性过程文档」的标题形态，不禁技术名词（快照、日志本身是术语）
banned_head='^#+ (.*(进度|实录|战役|复盘|接续|突破)[）)]*$|状态快照|工作日志)'
bad=""
for f in $ALL_DOCS; do
    [ -f "$ROOT/$f" ] || continue
    hit="$(grep -nE "$banned_head" "$ROOT/$f" 2>/dev/null | head -2)"
    [ -n "$hit" ] && bad="$bad
$f: $hit"
done
assert_eq "$bad" "" "无过程性章节标题"

case_name "无 emoji 状态标记"

bad=""
for f in $ALL_DOCS; do
    [ -f "$ROOT/$f" ] || continue
    hit="$(grep -nE '✅|❌|⚠️|🟡|🔴' "$ROOT/$f" 2>/dev/null | head -2)"
    [ -n "$hit" ] && bad="$bad
$f: $hit"
done
assert_eq "$bad" "" "文档不使用 emoji 作为状态标记"

case_name "无对自身上作的评价"

# 不应出现「证明了这个项目如何」「这个项目是最好的」之类
banned_self='证明了|证明了什么|这个项目的价值|本项目的意义|值得骄傲|引以为傲'
bad=""
for f in $ALL_DOCS; do
    [ -f "$ROOT/$f" ] || continue
    hit="$(grep -nE "$banned_self" "$ROOT/$f" 2>/dev/null | head -2)"
    [ -n "$hit" ] && bad="$bad
$f: $hit"
done
assert_eq "$bad" "" "文档不评价自身工作"

case_name "不引用本地私有路径"

bad="$(cd "$ROOT" && grep -rnE '\.local/goals|\.workbuddy|\.zcode' \
        README.md AGENTS.md CONTRIBUTING.md SECURITY.md docs/ 2>/dev/null | head -3)"
assert_eq "$bad" "" "不引用未入库的本地路径"

finish
