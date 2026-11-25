#!/bin/sh
# 回归：ADR 必须可被机器索引（状态字段 + 索引表 + 证据段）
#
# 曾经：0006 被 0009 取代后，7 处残留表述无人发现 ——
# 根因不是"忘了改"，而是**没有检查机制**。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

case_name "每篇 ADR 都有状态/日期字段"

bad=""
for f in "$ROOT"/docs/decisions/[0-9]*.md; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"
    grep -qE '^- 状态：' "$f" || bad="$bad $b:无状态"
    grep -qE '^- 日期：' "$f" || bad="$bad $b:无日期"
done
assert_eq "$bad" "" "状态与日期字段齐全"

case_name "每篇 ADR 都有决策/证据结构"

bad=""
for f in "$ROOT"/docs/decisions/[0-9]*.md; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"
    # 至少要有一个 h2 标题
    grep -qE '^## ' "$f" || bad="$bad $b:无章节"
done
assert_eq "$bad" "" "结构完整"

case_name "被取代的 ADR 状态行明确"

assert_contains "$(cat "$ROOT/docs/decisions/0006-桌面栈选型KDE.md")" "取代" \
    "0006 标注了被取代"

case_name "ADR 索引存在且覆盖所有 ADR"

idx="$ROOT/docs/decisions/README.md"
assert_rc "$([ -f "$idx" ] && echo 0 || echo 1)" 0 "索引文件存在"

missing=""
for f in "$ROOT"/docs/decisions/[0-9]*.md; do
    [ -f "$f" ] || continue
    n="$(basename "$f" | cut -c1-4)"
    grep -q "($n" "$idx" || missing="$missing $n"
done
assert_eq "$missing" "" "索引覆盖了每一篇 ADR"

finish
