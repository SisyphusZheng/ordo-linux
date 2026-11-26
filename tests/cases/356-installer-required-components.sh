#!/bin/sh
# 回归：P1-04 install.sh 对 flatpak 缺失只 warn（fail-open）
#       P2-08 user.ordo 注册失败只 warn（M2/VM 有实例，install.sh 注册不上就白建）
#
# flatpak 是应用层的唯一入口：缺了它首启没有浏览器/商店，ordo app install
# 也无从补救。缺失必须在安装期中止，而不是装完一台「看起来正常」的机器。
# user.ordo 注册失败同理：音频/会话总线的用户服务永不启动。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ordo-required.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

_install="$(cat "$ROOT/install.sh")"
_fn="$(sed -n '/^require_flatpak() {/,/^}/p' "$ROOT/install.sh")"

case_name "flatpak 门禁是独立函数，两处消费都走它"
assert_rc "$([ -n "$_fn" ] && echo 0 || echo 1)" 0 "能从安装器抽出 require_flatpak"
assert_contains "$_fn" 'command -v flatpak' "检查 flatpak 命令"
assert_contains "$_fn" '|| die' "缺失即 die（不是 warn）"
assert_eq "$(printf '%s\n' "$_install" | grep -c '^require_flatpak$')" 2 \
    "自动更新与首启应用清单两处都调用门禁"
assert_not_contains "$_install" 'warn "flatpak 命令不存在' "不再降级为 warn"

run_gate() { # PATH
    PATH="$1" /bin/sh -c '
        die()  { printf "die\n";  exit 1; }
        warn() { printf "warn\n"; }
        '"$_fn"'
        require_flatpak
    ' > "$tmp/out" 2>&1
}

case_name "flatpak 缺失：安装中止（退出码 1）"
mkdir -p "$tmp/empty"
run_gate "$tmp/empty"; rc=$?
assert_eq "$rc" 1 "缺 flatpak 即中止"
assert_eq "$(cat "$tmp/out")" "die" "走 die 分支"

case_name "flatpak 存在：门禁放行"
mkdir -p "$tmp/bin"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/flatpak"
chmod 755 "$tmp/bin/flatpak"
run_gate "$tmp/bin"; rc=$?
assert_eq "$rc" 0 "有 flatpak 时放行"
assert_eq "$(cat "$tmp/out")" "" "放行时不输出错误"

case_name "user.ordo 注册失败即停（不再 warn）"
assert_active_line "$ROOT/install.sh" 'rc-update add user.ordo default' "仍注册 user.ordo"
assert_contains "$_install" '|| die "user.ordo 注册失败' "注册失败会中止安装"
assert_not_contains "$_install" '|| warn "user.ordo 注册失败' "不再降级为 warn"

finish
