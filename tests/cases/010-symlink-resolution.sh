#!/bin/sh
# 回归：P0-1 安装后软链入口必须能找到 lib.sh
#
# 曾经的缺陷：install.sh 把 ordo 软链到 /usr/local/bin，而 ordo 用
# $(dirname "$0") 找 lib.sh —— 软链下解析成 /usr/local/bin/lib.sh，报
# "No such file or directory"，5 个入口全废。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

case_name "P0-1 软链后入口可运行"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ordo-link.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# 模拟 install.sh 的安装布局：把 scripts/ 复制到一处，再软链到另一处
mkdir -p "$tmp/opt/ordo"
cp -r "$ROOT/scripts" "$ROOT/config" "$tmp/opt/ordo/"
[ -f "$ROOT/version" ] && cp "$ROOT/version" "$tmp/opt/ordo/"
for e in ordo sysup ordo-snap ordo-backup ordo-config ordo-migrate ordo-selfcheck; do
    [ -f "$tmp/opt/ordo/scripts/$e" ] || continue
    ln -sf "$tmp/opt/ordo/scripts/$e" "$tmp/bin/$e"
done
ln -sf "$tmp/opt/ordo/scripts/doctor" "$tmp/bin/ordo-doctor"

# 1) 软链入口能跑起来（--help 不需要 root/ZFS）
out="$("$tmp/bin/ordo" --help 2>&1)"; rc=$?
assert_rc "$rc" 0 "ordo --help 退出码"
assert_contains "$out" "用法" "ordo --help 有输出"
assert_not_contains "$out" "No such file" "不再报 lib.sh 找不到"

# 2) 子命令分发能落到正确脚本
out="$("$tmp/bin/ordo" selfcheck 2>&1)"; rc=$?
assert_rc "$rc" 0 "ordo selfcheck 通过"
assert_contains "$out" "自检通过" "selfcheck 输出结论"

# 3) 分发到不存在的脚本时必须明确报错，而不是 sh 的报错
rm -f "$tmp/opt/ordo/scripts/ordo-snap"
out="$("$tmp/bin/ordo" snap list 2>&1)"; rc=$?
assert_rc "$rc" 1 "缺失目标脚本时退出码为 1"
assert_contains "$out" "找不到可执行脚本" "给了明确错误信息"

finish
