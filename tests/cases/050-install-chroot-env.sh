#!/bin/sh
# 回归：P0-2 chroot 必须传入 PROFILE/MARCH/VIDEO_CARDS 等 build 变量
#
# 曾经：chroot 的 env 只传了 DISK/POOL/DATASET/HOME_DS，heredoc 又是
# <<'CHROOT'（不展开）→ 内部 $PROFILE 为空 → eselect profile set ""
# 失败 → `|| warn` 吞掉 → desktop profile 永不生效且零告警。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

case_name "P0-2 chroot env 传入了 build 变量"

# 取 chroot 调用那一段（从 'chroot "$TARGET" /usr/bin/env' 到 heredoc 开始）
block="$(sed -n '/chroot "\$TARGET" \/usr\/bin\/env/,/<<.CHROOT./p' "$ROOT/install.sh")"
[ -n "$block" ] || { assert_rc 1 0 "能找到 chroot 调用"; finish; }

for var in PROFILE MARCH VIDEO_CARDS ARCH ORDO_PLATFORM REPO_DIR; do
    assert_contains "$block" "$var=" "chroot 传入了 $var"
done

case_name "P0-2 HOME_DATASET 变量名对齐"

# chroot 内使用的是 $HOME_DATASET；若只传 HOME_DS，内部会拿到空值
assert_contains "$block" "HOME_DATASET=" "传入了 HOME_DATASET（与内部变量名一致）"

case_name "P0-2 profile 失败不再降级为 warn"

_install="$(cat "$ROOT/install.sh")"
assert_not_contains "$_install" 'eselect profile set "$PROFILE" || warn' \
    "不再用 || warn 吞掉 profile 失败"
assert_contains "$_install" 'PROFILE 为空' "对空 PROFILE 有显式检查"
assert_contains "$_install" '|| die "eselect profile set' \
    "profile 失败会中止安装"

case_name "目标根先获得仓库文件，首次 world 前注册 overlay"
install_script="$ROOT/install.sh"
stage=$(grep -n 'mkdir -p "\$TARGET/var/tmp/ordo-source"' "$install_script" | cut -d: -f1)
chroot_start=$(grep -n '^chroot ' "$install_script" | cut -d: -f1)
overlay=$(grep -n '^cat > /etc/portage/repos.conf/local.conf' "$install_script" | cut -d: -f1)
world=$(grep -n 'if emerge -uDN' "$install_script" | head -1 | cut -d: -f1)
[ "$stage" -lt "$chroot_start" ] && [ "$overlay" -lt "$world" ]
assert_rc "$?" 0 "暂存和 overlay 注册都早于使用"

case_name "只写通过预检的目标盘"
verify=$(grep -n 'sha256sum --check' "$install_script" | cut -d: -f1)
write=$(grep -n '^parted .*mklabel' "$install_script" | cut -d: -f1)
[ "$verify" -lt "$write" ]
assert_rc "$?" 0 " stage3 校验先于 GPT 写入"
assert_not_contains "$_install" 'zfs unmount -a' "不卸载其他池的数据集"
assert_not_contains "$_install" 'zpool destroy' "不销毁已导入的池"

finish
