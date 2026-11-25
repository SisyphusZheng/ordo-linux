#!/bin/sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin" "$tmp/scripts" "$tmp/conf" "$tmp/boot"
# Redirect /boot in the script under test. All state-changing tools are fixtures.
sed 's|/boot/|boot/|g' "$ROOT/scripts/sysup" > "$tmp/scripts/sysup"
cp "$ROOT/scripts/lib.sh" "$tmp/scripts/"
printf '#!/bin/sh\nexit "${MIGRATION_RC:-0}"\n' > "$tmp/scripts/ordo-migrate"
chmod +x "$tmp/scripts/ordo-migrate"
cat > "$tmp/conf/check-build" <<'BUILD'
case "$1" in jobs) exec sh "$BUILD_POLICY" "$@";; arc) exit "${ARC_RC:-0}";; esac
BUILD
cat > "$tmp/bin/fixture" <<'MOCK'
#!/bin/sh
name=${0##*/}
printf '%s %s\n' "$name" "$*" >> "$COMMAND_LOG"
case "$name" in
    id) printf '%s\n' 0 ;;
    findmnt) printf '%s\n' rpool/root/ordo ;;
    nproc) printf '%s\n' 4 ;;
    portageq) printf '%s\n' "${TEST_MAKEOPTS:--j4}" ;;
    modinfo)
        [ "$2" = 6.10 ] || exit 1
        printf '%s\n' 2.4.0
        ;;
    zfs)
        case "$1:$*" in
            get:*available*) printf '%s\n' 20G ;;
            get:*org.zfsbootmenu:active*) printf '%s\n' on ;;
            version:*) printf '%s\n' zfs-2.4.0 ;;
            hold:*) exit "${HOLD_RC:-0}" ;;
        esac
        ;;
    emerge|flatpak) ;;
    *) exit 99 ;;
esac
MOCK
chmod +x "$tmp/bin/fixture"
for name in id findmnt nproc portageq modinfo zfs emerge flatpak; do
    ln -s fixture "$tmp/bin/$name"
done
export PATH="$tmp/bin:$PATH"
export BUILD_POLICY="$ROOT/config/check-build"
# lib.sh takes its configuration from the adjacent repository by design.
ln -s conf "$tmp/config"
export COMMAND_LOG="$tmp/commands"
printf '%s\n' kernel > "$tmp/boot/vmlinuz-6.9"
printf '%s\n' kernel > "$tmp/boot/vmlinuz-6.10"
printf '%s\n' initramfs > "$tmp/boot/initramfs-6.9.img"

upgrade() {
    : > "$COMMAND_LOG"
    (cd "$tmp" && sh scripts/sysup --yes) 2>&1
}

case_name "旧内核的 initramfs 不能使新内核通过"
out=$(upgrade)
assert_rc "$?" 1 "新内核缺少 initramfs 时失败"
assert_contains "$out" "6.10" "按版本选最新的已安装内核"
assert_not_contains "$(cat "$COMMAND_LOG")" "zfs release" "保留快照 hold"

case_name "迁移失败时保持快照并返回失败"
printf '%s\n' initramfs > "$tmp/boot/initramfs-6.10.img"
out=$(MIGRATION_RC=1 upgrade)
assert_rc "$?" 1 "迁移失败返回 1"
assert_contains "$out" "迁移失败" "指出迁移错误"
assert_not_contains "$(cat "$COMMAND_LOG")" "zfs release" "保留快照 hold"

case_name "编译预检先于同步和快照"
out=$(TEST_MAKEOPTS=--jobs=5 upgrade)
assert_rc "$?" 1 "并行度超过 CPU 数时拒绝升级"
assert_not_contains "$(cat "$COMMAND_LOG")" "emerge" "不启动 Portage"
out=$(ARC_RC=2 upgrade)
assert_rc "$?" 2 "ARC 无法判定时返回 2"
assert_not_contains "$(cat "$COMMAND_LOG")" "zfs snapshot" "无法判定时不创建快照"

case_name "快照无法加 hold 时中止"
out=$(HOLD_RC=1 upgrade)
assert_rc "$?" 1 "加 hold 失败时中止"
assert_not_contains "$(cat "$COMMAND_LOG")" "emerge" "没有受保护的回滚点时不升级"

case_name "迁移及启动检查都通过后才释放 hold"
out=$(upgrade)
assert_rc "$?" 0 "升级成功"
assert_contains "$(cat "$COMMAND_LOG")" "modinfo -k 6.10" "检查新内核的 ZFS 模块"
assert_contains "$(cat "$COMMAND_LOG")" "zfs release" "释放快照 hold"

finish
