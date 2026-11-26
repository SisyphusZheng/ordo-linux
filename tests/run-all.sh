#!/bin/sh
# 跑全部测试：L1 静态 + L2 行为用例
#
# 用法: tests/run-all.sh [用例名过滤]
# 退出: 0 全绿 | 1 有失败 | 2 有无法判定（或过滤器 0 匹配）
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

filter="${1:-}"
failed=""
unknown=""
total=0
passed=0
matched=0

printf '=== L1 静态 ===\n'
sh tests/lint.sh
_rc=$?
total=$((total + 1))
if [ "$_rc" -eq 0 ]; then
    passed=$((passed + 1))
else
    case "$_rc" in
        2) unknown="$unknown lint" ;;
        *) failed="$failed lint" ;;
    esac
fi

printf '\n=== L2 行为 ===\n'
for c in tests/cases/*.sh; do
    [ -f "$c" ] || continue
    base="$(basename "$c")"
    case "$base" in
        *"$filter"*) ;;
        *) continue ;;
    esac
    matched=$((matched + 1))
    total=$((total + 1))
    sh "$c" >/dev/null 2>&1
    _rc=$?
    if [ "$_rc" -eq 0 ]; then
        printf '  PASS %s\n' "$base"
        passed=$((passed + 1))
    elif [ "$_rc" -eq 2 ]; then
        printf '  ?    %s（无法判定）\n' "$base"
        unknown="$unknown $base"
    else
        printf '  FAIL %s\n' "$base"
        failed="$failed $base"
    fi
done

# 过滤器无匹配时不能只剩 lint=1 就报「全部通过」（曾经的假绿灯）。
if [ -n "$filter" ] && [ "$matched" -eq 0 ]; then
    printf '\n? 过滤器 "%s" 未匹配任何用例（0 个匹配，无法判定）\n' "$filter"
    printf '   可用: sh tests/run-all.sh <关键字>\n'
    exit 2
fi

printf '\n'
if [ -n "$failed" ]; then
    printf '✘ %d/%d 通过；失败:%s\n' "$passed" "$total" "$failed"
    printf '   逐个复跑：sh tests/cases/<name>.sh\n'
    exit 1
fi
if [ -n "$unknown" ]; then
    printf '? %d/%d 无法判定；未判定:%s\n' "$passed" "$total" "$unknown"
    printf '   2 不是通过；补齐工具或修复用例后重跑\n'
    exit 2
fi
printf '✔ %d/%d 全部通过\n' "$passed" "$total"
exit 0
