#!/bin/sh
# 回归：selfcheck 的 shebang 失败必须计入退出码
#
# 曾经：shebang 不对只 report bad，不 n_bad+=1；同一轮仍打印
# 「✔ 入口脚本均可执行且 shebang 正确」并 exit 0。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ordo-selfcheck.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
cp -R "$ROOT/scripts" "$tmp/scripts"

case_name "缺可执行位时 selfcheck 退出 1"

chmod -x "$tmp/scripts/ordo-backup"
out="$(sh "$tmp/scripts/ordo-selfcheck" 2>&1)"; rc=$?
assert_rc "$rc" 1 "缺可执行位时退出码为 1"
assert_contains "$out" "缺少可执行位" "指出缺少可执行位"
chmod +x "$tmp/scripts/ordo-backup"

case_name "shebang 错误时 selfcheck 退出 1"

{ printf '#!/bin/bash\n'; sed '1d' "$tmp/scripts/sysup"; } > "$tmp/scripts/sysup.new"
mv "$tmp/scripts/sysup.new" "$tmp/scripts/sysup"
chmod +x "$tmp/scripts/sysup"
out="$(sh "$tmp/scripts/ordo-selfcheck" 2>&1)"; rc=$?
assert_rc "$rc" 1 "shebang 错误时退出码为 1"
assert_contains "$out" "shebang 不是 #!/bin/sh" "指出 shebang 错误"
assert_not_contains "$out" "自检通过" "不输出「自检通过」"

finish
