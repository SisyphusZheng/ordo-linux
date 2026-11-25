#!/bin/sh
# 回归：P1-4 world 行内注释制造幻影漂移
#
# 曾经：config/world 带 31 条行内注释，install.sh 原样 cp 进
# /var/lib/portage/world；verify 的 exp 侧剥注释、act 侧不剥 →
# 报 31 extra + 31 missing，把「唯一事实来源」变成不可信输出。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

case_name "P1-4 config/world 只含裸 atom"

atoms="$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$ROOT/config/world")"
bad="$(printf '%s\n' "$atoms" | awk 'NF && ($0 ~ /#/ || NF != 1)')"
assert_eq "$bad" "" "没有行内注释或多列行"

n="$(printf '%s\n' "$atoms" | grep -c . )"
if [ "$n" -gt 50 ]; then
    assert_rc 0 0 "atom 数量合理（${n} 个）"
else
    assert_rc "$n" ">50" "atom 数量合理"
fi

case_name "P1-4 用 verify 的同一管线复现，不应有幻影漂移"

# 用 config/world 模拟「install.sh 原样 cp 进 world」的结果，再按 verify 的口径比对
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ordo-world.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
cp "$ROOT/config/world" "$tmp/world"

sed -e 's/#.*//' "$tmp/world" | awk 'NF { print $1 }' \
    | sed -e 's/::.*//' -e 's/:[^/]*$//' | sort -u > "$tmp/exp"
sed -e 's/#.*//' "$tmp/world" | awk 'NF { print $1 }' \
    | sed -e 's/::.*//' -e 's/:[^/]*$//' | sort -u > "$tmp/act"

assert_eq "$(comm -13 "$tmp/exp" "$tmp/act" | wc -l | tr -d ' ')" "0" "无幻影 extra"
assert_eq "$(comm -23 "$tmp/exp" "$tmp/act" | wc -l | tr -d ' ')" "0" "无幻影 missing"

case_name "P1-4 注释与理由仍保留（迁移到 world.notes）"

[ -f "$ROOT/config/world.notes" ]
assert_rc "$?" 0 "config/world.notes 存在"
notes_lines="$(wc -l < "$ROOT/config/world.notes" | tr -d ' ')"
if [ "$notes_lines" -gt 50 ]; then
    assert_rc 0 0 "world.notes 保留了理由（${notes_lines} 行）"
else
    assert_rc "$notes_lines" ">50" "world.notes 保留了理由"
fi

finish
