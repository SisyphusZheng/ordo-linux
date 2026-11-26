#!/bin/sh
# 回归：run-all 的过滤器 0 匹配不得报「全部通过」
#
# 曾经：过滤器手滑或被删掉的用例名会让循环 0 次，total 只剩 lint=1，
# 输出「✔ 1/1 全部通过」并 exit 0。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

case_name "过滤器无匹配时退出 2"

out="$(sh "$ROOT/tests/run-all.sh" ordo-no-such-case-xyz 2>&1)"; rc=$?
assert_rc "$rc" 2 "0 匹配时退出码为 2"
assert_contains "$out" "未匹配任何用例" "指出过滤器 0 匹配"
assert_contains "$out" "无法判定" "明确标注无法判定"
assert_not_contains "$out" "1/1 全部通过" "不输出「1/1 全部通过」"

finish
