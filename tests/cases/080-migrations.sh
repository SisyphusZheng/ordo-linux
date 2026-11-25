#!/bin/sh
# 回归：P1-15 迁移机制存在且可执行
#
# 曾经：仓库只有「从零安装」，已装机用户拿不到 config/ 的变更。
# 于是每次改进都只对下一次重装生效。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

case_name "P1-15 迁移目录与契约"

assert_rc "$([ -d "$ROOT/config/migrations" ] && echo 0 || echo 1)" 0 "config/migrations 存在"
assert_rc "$([ -f "$ROOT/config/migrations/README.md" ] && echo 0 || echo 1)" 0 "有契约文档"
assert_rc "$([ -x "$ROOT/scripts/ordo-migrate" ] && echo 0 || echo 1)" 0 "ordo-migrate 可执行"

case_name "P1-15 迁移脚本本身的规范性"

n=0
for m in "$ROOT"/config/migrations/*.sh; do
    [ -f "$m" ] || continue
    n=$((n + 1))
    base="$(basename "$m")"
    # 文件名必须是 <unix 时间戳>-<描述>.sh
    case "$base" in
        [0-9]*-*.sh) assert_rc 0 0 "$base 命名合规" ;;
        *) assert_rc "$base" "<时间戳>-<名>.sh" "$base 命名不合规" ;;
    esac
    sh -n "$m" >/dev/null 2>&1
    assert_rc "$?" 0 "$base 语法正确"
    head -1 "$m" | grep -q '^#!/bin/sh'
    assert_rc "$?" 0 "$base shebang 正确"
done
[ "$n" -gt 0 ]
assert_rc "$?" 0 "至少有一个迁移脚本"

case_name "P1-15 ordo migrate --pending 可跑"

out="$(sh "$ROOT/scripts/ordo-migrate" --pending 2>&1)"; rc=$?
# 非 root 时会拒绝——这是对的
if [ "$rc" -eq 1 ]; then
    assert_contains "$out" "需要 root" "非 root 明确拒绝"
else
    assert_rc "$rc" 0 "--pending 正常返回"
    assert_contains "$out" "迁移" "有迁移相关输出"
fi

case_name "P1-15 ordo 分发 migrate 子命令"

out="$(sh "$ROOT/scripts/ordo" migrate --pending 2>&1)"; rc=$?
assert_contains "$out" "需要 root" "ordo migrate 能分发到 ordo-migrate"

finish
