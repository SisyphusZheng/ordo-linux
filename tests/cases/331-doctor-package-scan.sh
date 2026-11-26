#!/bin/sh
# 回归：doctor 扫已安装包时，`!` 豁免逐行生效、命中全部计数、不得提前 exit
#
# 旧版三个缺陷叠在一起，让 /var/db/pkg 扫描永远返回空、有残留也打绿勾：
#   1) awk 只收到 find 的管道输入，forbidden-world 从未作为第一个文件传入
#      （-v badf 只是变量，FNR==NR 恒真），第二段规则从未执行；
#   2) skip 命中一次 `!` 豁免后不再复位，find 顺序靠前的豁免包会污染后面所有行；
#   3) print b; exit 只报第一个命中；
#   4) 命中行的 bad 在管道子 shell 里计数丢失，打印 ✘ 仍以 0 退出。
# 判据不依赖开发机上还有多少别的坏项：同一套环境跑两次，只改
# forbidden-world，问题计数必须正好多出三个禁入包。
set -eu
repo=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)
. "$repo/tests/lib/assert.sh"
scratch=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/root/scripts" "$scratch/root/config/desktop" "$scratch/bin" "$scratch/db"

printf 'POOL=rpool\nDATASET=rpool/root/ordo\nHOME_DATASET=rpool/home\n' > "$scratch/root/config/dataset"
printf 'sys-apps/baseline\n' > "$scratch/world"
cp "$repo/scripts/lib.sh" "$scratch/root/scripts/lib.sh"
sed -e "s|/var/lib/portage/world|$scratch/world|g" \
    -e "s|/var/db/pkg|$scratch/db|g" \
    "$repo/scripts/doctor" > "$scratch/root/scripts/doctor"

# 固定 find 顺序：豁免包排最前，复现「一次豁免污染后续所有行」。
cat > "$scratch/bin/find" <<EOF
#!/bin/sh
cat <<'LIST'
$scratch/db/app-editors/nano-2.9.8
$scratch/db/app-editors/vim-9.0.12
$scratch/db/app-misc/emacs-29.4
$scratch/db/net-misc/curl-8.5.0
$scratch/db/sys-apps/baseline-1.0
LIST
EOF
chmod +x "$scratch/bin/find"

_run_doctor() {
    PATH="$scratch/bin:$PATH" HOME="$scratch/nohome" \
        sh "$scratch/root/scripts/doctor" 2>&1 || true
}
_problem_count() { # 从汇总行取「✘ N 个问题」的 N；没有该行记 0
    printf '%s\n' "$1" | sed -n 's/^✘ \([0-9][0-9]*\) 个问题.*/\1/p'
}

# A：只有豁免行，没有禁入条目 —— 拿本机环境的问题数做基线。
printf '%s\n' '!app-editors/nano' > "$scratch/root/config/forbidden-world"
_base=$(_problem_count "$(_run_doctor)")
_base=${_base:-0}

# B：同样的环境，只把禁入条目加回去。
cat > "$scratch/root/config/forbidden-world" <<'FW'
app-editors/*
!app-editors/nano
app-misc/emacs
net-misc/curl
FW
_out=$(_run_doctor)
_delta=$(( $(_problem_count "$_out" || true) - _base ))

case_name "三个残留包逐个报出，豁免包不报"

assert_contains "$_out" "已安装禁入包: app-editors/vim-9.0.12" "vim 被报出"
assert_contains "$_out" "已安装禁入包: app-misc/emacs-29.4" "emacs 被报出"
assert_contains "$_out" "已安装禁入包: net-misc/curl-8.5.0" "curl 被报出（不是只报第一个）"
assert_not_contains "$_out" "app-editors/nano-2.9.8" "!app-editors/nano 豁免生效"
assert_not_contains "$_out" "均无应用级大件" "有残留时不得打绿勾"

case_name "命中计入退出码（打印 ✘ 就不能 0 退出）"

assert_eq "$_delta" 3 "问题计数比基线多 3（未计数/提前 exit 都会小于 3）"

finish
