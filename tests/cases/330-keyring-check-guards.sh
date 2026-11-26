#!/bin/sh
# 回归：keyring-policy.sh check 的三态与声明判据
#
# 语义（2026-11-26 反转）：密钥服务重新提供，check 不再检查「服务不存在」，
# 而是验证「已声明且接线」：
#   world 含 gnome-keyring、package.mask 不遮蔽、greetd PAM 两行、
#   会话脚本启动 gnome-keyring-daemon。
# 任一无判据（文件缺失/不可读）→2；有判据但缺件→1；齐备→0。
set -eu
repo=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)
. "$repo/tests/lib/assert.sh"
scratch=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$scratch"' EXIT

root=$scratch/repo/config
mkdir -p "$root/desktop/greetd" "$root/desktop/umbriel" "$root/package.mask" \
    "$root/package.use"
cp "$repo/config/desktop/keyring-policy.sh" "$root/desktop/keyring-policy.sh"
cp "$repo/config/package.use/ordo-keyring" "$root/package.use/ordo-keyring"
policy=$root/desktop/keyring-policy.sh

reset_fixture() {
    printf 'app-crypt/libsecret\ngnome-base/gnome-keyring\n' > "$root/world"
    rm -f "$root/package.mask/ordo-keyring"
    cat > "$root/desktop/greetd/pam.d-greetd" <<'PAM'
auth            include         login
auth            optional        pam_gnome_keyring.so
account         include         login
password        include         login
session         include         login
session         optional        pam_gnome_keyring.so auto_start
PAM
    cat > "$root/desktop/umbriel/ordo-umbriel-session" <<'SESSION'
#!/bin/sh
. /usr/local/bin/ordo-session-env
if [ -z "${GNOME_KEYRING_CONTROL:-}" ]; then
    eval "$(gnome-keyring-daemon --start --components=secrets)"
fi
exec start-umbriel
SESSION
}

_rc=0
_out=""
run_check() {
    _rc=0
    _out=$(sh "$policy" check 2>&1) || _rc=$?
}

case_name "声明与接线齐备：check 返回 0 且无噪音"

reset_fixture
run_check
assert_rc "$_rc" 0 "齐备返回 0"
assert_eq "$_out" "" "通过时不输出噪音"

case_name "world 缺 gnome-keyring：点名缺件并返回 1"

grep -v '^gnome-base/gnome-keyring$' "$root/world" > "$root/world.new"
mv -f "$root/world.new" "$root/world"
run_check
assert_rc "$_rc" 1 "world 缺提供者返回 1"
assert_contains "$_out" "world 未声明" "说明缺的是 world 声明"

case_name "package.mask 残留 gnome-keyring：返回 1"

reset_fixture
printf 'gnome-base/gnome-keyring\n' > "$root/package.mask/ordo-keyring"
run_check
assert_rc "$_rc" 1 "mask 遮蔽服务返回 1"
assert_contains "$_out" "仍在遮蔽" "点名 mask 文件"

case_name "package.mask 残留 libsecret::gentoo：返回 1"

printf 'app-crypt/libsecret::gentoo\n' > "$root/package.mask/ordo-keyring"
run_check
assert_rc "$_rc" 1 "上游 libsecret 仍被 mask 返回 1"
assert_contains "$_out" "仍在遮蔽" "与提供者 mask 同一判据"

case_name "greetd PAM 缺 auth 行：返回 1"

reset_fixture
grep -vE '^auth[[:space:]]+optional[[:space:]]+pam_gnome_keyring[.]so$' \
    "$root/desktop/greetd/pam.d-greetd" > "$root/pam.new"
mv -f "$root/pam.new" "$root/desktop/greetd/pam.d-greetd"
run_check
assert_rc "$_rc" 1 "PAM 缺 auth 行返回 1"
assert_contains "$_out" "auth optional pam_gnome_keyring.so" "点名缺的 PAM 行"

case_name "greetd PAM 缺 session auto_start 行：返回 1"

reset_fixture
grep -v 'auto_start' "$root/desktop/greetd/pam.d-greetd" > "$root/pam.new"
mv -f "$root/pam.new" "$root/desktop/greetd/pam.d-greetd"
run_check
assert_rc "$_rc" 1 "PAM 缺 session 行返回 1"
assert_contains "$_out" "auto_start" "点名缺的 PAM 行"

case_name "会话脚本不启动守护进程：返回 1"

reset_fixture
grep -v 'gnome-keyring-daemon' "$root/desktop/umbriel/ordo-umbriel-session" > "$root/session.new"
mv -f "$root/session.new" "$root/desktop/umbriel/ordo-umbriel-session"
run_check
assert_rc "$_rc" 1 "会话不启动守护进程返回 1"
assert_contains "$_out" "未启动 gnome-keyring-daemon" "说明会话缺启动行"

case_name "会话脚本缺 GNOME_KEYRING_CONTROL 去重判据：返回 1"

reset_fixture
grep -v 'GNOME_KEYRING_CONTROL' "$root/desktop/umbriel/ordo-umbriel-session" > "$root/session.new"
mv -f "$root/session.new" "$root/desktop/umbriel/ordo-umbriel-session"
run_check
assert_rc "$_rc" 1 "会话缺去重判据返回 1"
assert_contains "$_out" "去重判据" "说明缺的是 GNOME_KEYRING_CONTROL"

case_name "world 文件缺失：无法判定返回 2"

reset_fixture
rm -f "$root/world"
run_check
assert_rc "$_rc" 2 "缺判据返回 2（不是 1）"
assert_contains "$_out" "无法判定" "明确标注无法判定"

case_name "greetd PAM 文件缺失：无法判定返回 2"

reset_fixture
rm -f "$root/desktop/greetd/pam.d-greetd"
run_check
assert_rc "$_rc" 2 "PAM 缺判据返回 2"
assert_contains "$_out" "无法判定" "明确标注无法判定"

case_name "未知子命令：返回 2"

_rc=0
_out=$(sh "$policy" nope 2>&1) || _rc=$?
assert_rc "$_rc" 2 "用法错误返回 2"
assert_contains "$_out" "Usage:" "给出用法"

case_name "remove 是 no-op + 提示（旧镜像调用点兼容）"

_rc=0
_out=$(sh "$policy" remove 2>&1) || _rc=$?
assert_rc "$_rc" 0 "remove 不再失败"
assert_contains "$_out" "不再移除" "明确告知 no-op"

case_name "configure 幂等收敛：写 package.use、删旧 mask、不碰无关 mask"

cfg=$scratch/cfg
etc=$scratch/etc/portage
mkdir -p "$cfg/config/desktop" "$cfg/config/package.use" "$etc/package.mask"
cp "$repo/config/package.use/ordo-keyring" "$cfg/config/package.use/ordo-keyring"
sed -e "s|/etc/portage|$etc|g" "$repo/config/desktop/keyring-policy.sh" \
    > "$cfg/config/desktop/keyring-policy.sh"
printf 'gnome-base/gnome-keyring\n' > "$etc/package.mask/ordo-keyring"
printf '>=sys-fs/zfs-7.3\n' > "$etc/package.mask/l1-zfs-pin"
_rc=0
sh "$cfg/config/desktop/keyring-policy.sh" configure >/dev/null 2>&1 || _rc=$?
assert_rc "$_rc" 0 "首次 configure 成功"
assert_rc "$([ -e "$etc/package.mask/ordo-keyring" ] && echo 1 || echo 0)" 0 "旧 mask 已删除"
assert_rc "$([ -e "$etc/package.mask/l1-zfs-pin" ] && echo 0 || echo 1)" 0 "无关 mask 保留"
assert_eq "$(cat "$etc/package.use/ordo-keyring")" \
    "$(cat "$cfg/config/package.use/ordo-keyring")" "package.use 与仓库一致"
cp "$etc/package.use/ordo-keyring" "$scratch/deployed.1"
_rc=0
sh "$cfg/config/desktop/keyring-policy.sh" configure >/dev/null 2>&1 || _rc=$?
assert_rc "$_rc" 0 "重复 configure 成功"
assert_rc "$(cmp -s "$scratch/deployed.1" "$etc/package.use/ordo-keyring" && echo 0 || echo 1)" 0 \
    "重复执行不改变内容"

finish
