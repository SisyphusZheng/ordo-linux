#!/bin/sh
# 回归：lint 的 skip 不得算作通过
#
# 曾经：PATH 里没有 shellcheck/python3 时，lint 打几个 skip 后仍输出
# 「✔ N 项检查全部通过」并 exit 0 —— 缺工具被当成绿勾，违反 AGENTS.md
# 「2 不等于通过」。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ordo-lint-skip.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"; mkdir -p "$bin"
for t in sh awk sed grep sort dirname basename; do
    p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$bin/$t"
done

case_name "缺 shellcheck/python3 时 lint 退出 2"

out="$(PATH="$bin" sh "$ROOT/tests/lint.sh" 2>&1)"; rc=$?
assert_rc "$rc" 2 "有 skip 时退出码为 2"
assert_contains "$out" "项无法判定" "汇总写出「无法判定」"
assert_contains "$out" "skip" "输出里确实有 skip 行"
assert_not_contains "$out" "全部通过" "不输出「全部通过」"

finish
