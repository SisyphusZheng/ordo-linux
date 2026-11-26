#!/bin/sh
# 回归：doctor 必须消费 M2 硬件自检报告的三态（B4）
#
# 旧版：verify-hardware.sh --session-report 把结论写进
# ~/.local/state/ordo/m2-hardware.log 末行 `exit=0/1/2`，但没有任何消费者。
# 「硬件已验证」只是产报告那条命令的自我声明。doctor 现在必须读它：
#   0 -> 通过；1 -> 报问题；2 -> 无法判定（skip，不是通过）；
#   缺失/末行不认识 -> skip（不是通过），不得冒充通过。
set -eu
repo=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)
. "$repo/tests/lib/assert.sh"
scratch=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/root/scripts" "$scratch/root/config" "$scratch/bin" \
    "$scratch/home" "$scratch/state/ordo" "$scratch/db"

printf 'POOL=rpool\nDATASET=rpool/root/ordo\nHOME_DATASET=rpool/home\n' > "$scratch/root/config/dataset"
: > "$scratch/root/config/forbidden-world"
printf 'sys-apps/baseline\n' > "$scratch/world"
cp "$repo/scripts/lib.sh" "$scratch/root/scripts/lib.sh"
sed -e "s|/proc/device-tree/compatible|$scratch/compatible|g" \
    -e "s|/var/lib/portage/world|$scratch/world|g" \
    -e "s|/var/db/pkg|$scratch/db|g" \
    "$repo/scripts/doctor" > "$scratch/root/scripts/doctor"

printf 'apple,j413\000apple,t8112\000' > "$scratch/compatible"
_log="$scratch/state/ordo/m2-hardware.log"

_doctor() {
    PATH="$scratch/bin:$PATH" HOME="$scratch/home" \
        XDG_STATE_HOME="$scratch/state" \
        sh "$scratch/root/scripts/doctor" 2>&1 || true
}

# doctor 的三种状态各有固定前缀：只断言文字会让 skip 被改成 ok 也照样绿。
_ok_mark=$(printf '\033[32m✔\033[0m')
_bad_mark=$(printf '\033[31m✘\033[0m')
_skip_mark=$(printf '\033[36m-\033[0m')

case_name "报告缺失：skip，不是通过"

rm -f "$_log"
_out=$(_doctor)
assert_contains "$_out" "$_skip_mark 没有 M2 硬件自检报告" "点出报告缺失（skip）"
assert_contains "$_out" "不是通过" "明确标为无法判定"
assert_not_contains "$_out" "M2 硬件自检通过" "缺失不得冒充通过"

case_name "exit=0：通过"

printf 'date\nuname\n通过  内屏\n通过  无线\nexit=0\n' > "$_log"
_out=$(_doctor)
assert_contains "$_out" "$_ok_mark M2 硬件自检通过" "0 映射为 ✔ 通过"
assert_not_contains "$_out" "M2 硬件自检报异常" "不误报异常"

case_name "exit=1：报问题"

printf 'date\n异常  无线\nexit=1\n' > "$_log"
_out=$(_doctor)
assert_contains "$_out" "$_bad_mark M2 硬件自检报异常" "1 映射为 ✘"
assert_not_contains "$_out" "M2 硬件自检通过" "1 不得打绿勾"

case_name "exit=2：无法判定（skip），不是通过"

printf 'date\n待验  摄像头\nexit=2\n' > "$_log"
_out=$(_doctor)
assert_contains "$_out" "$_skip_mark M2 硬件自检有「待验」项" "2 映射为 -（skip）"
assert_contains "$_out" "不是通过" "明确标注"
assert_not_contains "$_out" "M2 硬件自检通过" "2 不得当通过"

case_name "只认末行：历史 exit=0 不能让坏报告通过"

printf 'exit=0\n报告被截断\nexit=\n' > "$_log"
_out=$(_doctor)
assert_contains "$_out" "$_skip_mark M2 硬件自检报告末行不是可识别的 exit=" "点出格式不认识（skip）"
assert_not_contains "$_out" "M2 硬件自检通过" "不拿中间行的历史结论冒充通过"

case_name "非 j413 设备树：不产生这项检查"

printf 'linux,dummy-virt\000' > "$scratch/compatible"
printf 'exit=0\n' > "$_log"
_out=$(_doctor)
assert_not_contains "$_out" "M2 硬件自检" "其它机器不误报"

finish
