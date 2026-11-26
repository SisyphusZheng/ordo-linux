#!/bin/sh
# 回归：P2-11 安装器的机械缺陷（都是「装完能开机，但开机的不是设计的那台机器」）
#
#   1) chroot 没有 /run → telinit 失败后落到 `kill -HUP 1`，打到 live ISO 的 PID 1。
#   2) fstab 写 /dev/sdX1（由 readlink -f 推出）→ USB 占 sda 时内置盘变 sdb，首启 /efi 挂不上。
#   3) zpool cachefile 指向 $workdir，收尾时 workdir 被删 → 属性指向不存在的目录。
#   4) greetd 四件套塞在品牌资产块里，缺文件只 warn；display-manager 无 -1 会进 world，
#      且只启用 display-manager 服务、不启用 greetd。
#   5) Luciole ebuild 名写死 0.1.0（升级要改安装器）。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

_install="$(cat "$ROOT/install.sh")"

case_name "chroot 有 /run，且不再向 PID 1 发信号"
assert_contains "$_install" 'mount --rbind /run   "$TARGET/run"' "chroot 前 bind /run"
_lrun=$(grep -n 'mount --rbind /run' "$ROOT/install.sh" | cut -d: -f1)
_lchroot=$(grep -n '^chroot "$TARGET" /usr/bin/env' "$ROOT/install.sh" | cut -d: -f1)
[ "$_lrun" -lt "$_lchroot" ]
assert_rc "$?" 0 "bind /run 早于 chroot"
assert_not_contains "$_install" "kill -HUP 1" "不再 kill -HUP 1（那是 live ISO 的 init）"
assert_eq "$(grep -c 'for mount_dir in dev sys proc run efi; do' "$ROOT/install.sh")" 2 \
    "异常清理与收尾都卸载 /run"

case_name "fstab 用 PARTUUID，不用安装期的盘符"
assert_contains "$_install" 'lsblk -no PARTUUID "$DISK_P1"' "从 ESP 读 PARTUUID"
assert_contains "$_install" 'PARTUUID=$_efi_partuuid  /efi   vfat' "fstab 首列是 PARTUUID"
assert_not_contains "$_install" '$DISK_P1                 /efi' "不再把 /dev/sdX1 写进 fstab"
assert_contains "$_install" '无法读取 ESP 的 PARTUUID' "读不到即中止，不猜盘符"

case_name "zpool cachefile 属性指向目标系统路径"
assert_contains "$_install" 'zpool set cachefile=/etc/zfs/zpool.cache "$POOL"' \
    "cachefile 属性落在 /etc/zfs/zpool.cache"
_lset=$(grep -n 'zpool set cachefile=/etc/zfs/zpool.cache' "$ROOT/install.sh" | cut -d: -f1)
_lcopy=$(grep -n 'install -m 0644 "$workdir/zpool.cache"' "$ROOT/install.sh" | cut -d: -f1)
[ "$_lcopy" -lt "$_lset" ]
assert_rc "$?" 0 "先把 cache 文件放进 BE，再改属性"

case_name "greetd 四件套不在品牌资产块里，缺失即停"
_ln_s13=$(grep -n '^# ---- 13) 品牌资产' "$ROOT/install.sh" | cut -d: -f1)
_ln_s14=$(grep -n '^# ---- 14) 登录管理器' "$ROOT/install.sh" | cut -d: -f1)
_ln_s15=$(grep -n '^# ---- 15) Flatpak 应用清单' "$ROOT/install.sh" | cut -d: -f1)
_ln_brand=$(grep -n 'if \[ -d "$REPO_DIR/assets/branding" \]' "$ROOT/install.sh" | cut -d: -f1)
_ln_greetd=$(grep -n '^_greetd_src=' "$ROOT/install.sh" | cut -d: -f1)
assert_rc "$([ -n "$_ln_s13" ] && [ -n "$_ln_s14" ] && [ -n "$_ln_brand" ] && echo 0 || echo 1)" 0 \
    "能定位品牌资产块与第 14 段"
[ "$_ln_brand" -lt "$_ln_s14" ] && [ "$_ln_s14" -lt "$_ln_greetd" ] && [ "$_ln_greetd" -lt "$_ln_s15" ]
assert_rc "$?" 0 "greetd 部署在第 14 段（品牌块之外）"
assert_contains "$_install" '|| die "缺少 $_greetd_src/config.toml' "缺 config.toml 即中止"
assert_not_contains "$_install" 'warn "未找到 config/desktop/greetd/config.toml"' \
    "不再把缺失降级为 warn"
# 每个文件断言各自的落点；旧写法 needle 是常量 "/etc/greetd"，
# 删掉任何一行真实部署仍然绿（C4 空转断言）。
_deploy_dies() { # 部署行 die 消息
    if grep -A1 -F -- "$1" "$ROOT/install.sh" | grep -qF -- "$2"; then
        echo 0
    else
        echo 1
    fi
}
assert_active_line "$ROOT/install.sh" \
    'install -Dm755 "$_greetd_src/greetd.initd" /etc/init.d/greetd' \
    "greetd 服务脚本落到 /etc/init.d/greetd"
assert_active_line "$ROOT/install.sh" \
    'install -Dm644 "$_greetd_src/pam.d-greetd" /etc/pam.d/greetd' \
    "greetd PAM 落到 /etc/pam.d/greetd"
assert_active_line "$ROOT/install.sh" \
    'install -Dm644 "$_greetd_src/tmpfiles-noctalia-greeter.conf" /etc/tmpfiles.d/noctalia-greeter.conf' \
    "greetd tmpfiles 落到 /etc/tmpfiles.d/noctalia-greeter.conf"
assert_rc "$(_deploy_dies 'install -Dm755 "$_greetd_src/greetd.initd" /etc/init.d/greetd' 'greetd 服务脚本部署失败')" 0 \
    "服务脚本缺失即 die"
assert_rc "$(_deploy_dies 'install -Dm644 "$_greetd_src/pam.d-greetd" /etc/pam.d/greetd' 'greetd PAM 部署失败')" 0 \
    "PAM 缺失即 die"
assert_rc "$(_deploy_dies 'install -Dm644 "$_greetd_src/tmpfiles-noctalia-greeter.conf" /etc/tmpfiles.d/noctalia-greeter.conf' 'greetd tmpfiles 部署失败')" 0 \
    "tmpfiles 缺失即 die"

case_name "只启用 greetd，不启用 display-manager 包装"
assert_contains "$_install" 'rc-update add greetd default || die' "greetd 失败即停"
assert_not_contains "$_install" "rc-update add display-manager" "不再启用 display-manager"
assert_not_contains "$_install" "emerge -q sys-apps/display-manager-init" "引导工具不进 world"
assert_contains "$_install" "emerge -q -1 --noreplace sys-apps/display-manager-init" \
    "display-manager-init 以 oneshot 装"
assert_contains "$_install" "emerge -q -1 --noreplace gui-libs/display-manager-init" \
    "类目回退分支同样 oneshot"

case_name "Luciole ebuild 名不写死版本"
assert_not_contains "$_install" "luciole-0.1.0.ebuild" "安装器不再钉 luciole 版本"
assert_contains "$_install" 'overlay/gui-apps/luciole/*.ebuild' "按 glob 校验 overlay"

finish
