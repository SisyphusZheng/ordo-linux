#!/bin/sh
# 回归：A1 系统日志（诊断前置）+ A6 UPower 回到通用声明层
#
# 缺陷证据（2026-11-26 日用审查 D1-3 / D3-3）：
#   - world 里没有任何 syslog 守护，logger(1) 写进虚空；合盖冻结、池 suspend、
#     扬声器保护失效都留不下现场。
#   - upower 只写在 config/platform/m2/world，通用路径（x86 真机、VM）没有它，
#     电源档位每次登录失败；package.use/real-hardware 又重复声明一次 USE。
#
# 判据：声明层（world / world.notes / 平台集 / package.use）与两条安装路径
# （install.sh、M2 外置安装器）必须同时成立。任一处被还原都会变红。
set -eu
cd "$(dirname "$(readlink -f "$0")")/../.."
. "tests/lib/assert.sh"

atoms() { grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$1" | awk '{print $1}' | sort -u; }
has_atom() { printf '%s\n' "$1" | grep -qx "$2" && echo 0 || echo 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ordo-syslog.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

case_name "A1 world 声明 syslog 与轮转"

_world="$(atoms config/world)"
assert_rc "$(has_atom "$_world" app-admin/sysklogd)" 0 "world 含 app-admin/sysklogd"
assert_rc "$(has_atom "$_world" app-admin/logrotate)" 0 "world 含 app-admin/logrotate（sysklogd 不自带轮转）"

# world 与 world.notes 的 atom 集合必须一致：加包不加理由等于不可审计的声明。
atoms config/world > "$tmp/w.atoms"
atoms config/world.notes > "$tmp/n.atoms"
assert_eq "$(comm -3 "$tmp/w.atoms" "$tmp/n.atoms" | wc -l | tr -d ' ')" "0" \
    "world 与 world.notes 的 atom 集合一致"

case_name "A6 upower 在通用声明层，平台集不重复"

assert_rc "$(has_atom "$_world" sys-power/upower)" 0 "world 含 sys-power/upower"
_m2="$(atoms config/platform/m2/world)"
assert_rc "$(has_atom "$_m2" sys-power/upower)" 1 "M2 平台集不再重复声明 upower"

_use_rc=0
grep -Eq '^sys-power/upower[[:space:]]+elogind' config/package.use/desktop || _use_rc=$?
assert_rc "$_use_rc" 0 "package.use/desktop 统一声明 upower 的 elogind"
_rh="$(grep -vE '^[[:space:]]*#' config/package.use/real-hardware)"
assert_not_contains "$_rh" "sys-power/upower" "package.use/real-hardware 不再重复 upower 段"

case_name "A1 两条安装路径都落 syslog 配置"

for f in install.sh config/platform/m2/install-external.sh; do
    _txt="$(cat "$f")"
    assert_contains "$_txt" "*.*                                             /var/log/messages" \
        "$f 写「全部 facility → messages」规则"
    assert_contains "$_txt" 'rc_logger="YES"' "$f 打开 OpenRC 的 rc_logger"
    assert_contains "$_txt" '/etc/logrotate.d/ordo' "$f 落 logrotate 片段"
done

# 服务注册：install.sh 走服务循环，M2 安装器单独容忍（旧 rootfs 可能还没有包）。
assert_active_line install.sh 'sysklogd:default' "install.sh 把 sysklogd 加进 default runlevel"
assert_active_line config/platform/m2/install-external.sh 'rc-update add sysklogd default' \
    "M2 安装器注册 sysklogd"
assert_contains "$(cat config/world.notes)" "app-admin/sysklogd" "world.notes 记录 sysklogd 的理由"
assert_contains "$(cat config/world.notes)" "sys-power/upower" "world.notes 记录 upower 上移的理由"

finish
