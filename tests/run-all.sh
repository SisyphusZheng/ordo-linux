#!/bin/sh
# 跑全部测试：L1 静态 + L2 行为用例
#
# 用法: tests/run-all.sh [用例名过滤]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

filter="${1:-}"
failed=""
total=0
passed=0

printf '=== L1 静态 ===\n'
if sh tests/lint.sh; then
    passed=$((passed + 1))
else
    failed="$failed lint"
fi
total=$((total + 1))

printf '\n=== L2 行为 ===\n'
for c in tests/cases/*.sh; do
    [ -f "$c" ] || continue
    base="$(basename "$c")"
    case "$base" in
        *"$filter"*) ;;
        *) continue ;;
    esac
    total=$((total + 1))
    if sh "$c" >/dev/null 2>&1; then
        printf '  PASS %s\n' "$base"
        passed=$((passed + 1))
    else
        printf '  FAIL %s\n' "$base"
        failed="$failed $base"
    fi
done

printf '\n'
if [ -n "$failed" ]; then
    printf '✘ %d/%d 通过；失败:%s\n' "$passed" "$total" "$failed"
    printf '   逐个复跑：sh tests/cases/<name>.sh\n'
    exit 1
fi
printf '✔ %d/%d 全部通过\n' "$passed" "$total"
exit 0
