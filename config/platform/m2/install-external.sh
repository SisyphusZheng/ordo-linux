#!/bin/sh
# External Ordo Linux installer for the verified Apple Silicon payload.
set -eu
PAYLOAD=/mnt/payload
POOL=rpool
ROOTDS=rpool/root/ordo
HOMEDS=rpool/home
KERNEL_RELEASE='@KERNEL_RELEASE@'
NATIVE_SHA='@NATIVE_SHA@'
USB_PAYLOAD='@USB_PAYLOAD@'

say() { printf '\n== %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }
die() { warn "$*"; exit 1; }

[ "$#" = 3 ] || die "用法：$0 --check|--apply <启动分区 PARTUUID> <系统分区 PARTUUID>"
mode=$1
case "$mode" in --check|--apply) ;; *) die "未知操作：$mode" ;; esac
boot_id=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
root_id=$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]')
valid_uuid() {
    [ "$1" != 00000000-0000-0000-0000-000000000000 ] &&
        printf '%s\n' "$1" | grep -Eq '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
}
valid_uuid "$boot_id" && valid_uuid "$root_id" || die "无效 PARTUUID"
[ "$boot_id" != "$root_id" ] || die "两个分区必须不同"
[ "$(id -u)" = 0 ] || die "请在手动 Live 中以 root 运行"

for tool in awk blkid blockdev chroot findmnt lsblk mktemp mkswap modprobe mount mountpoint readlink sha256sum tar umount wipefs zfs zpool; do
    command -v "$tool" >/dev/null || die "缺少工具：$tool"
done
[ "$(cat /proc/device-tree/compatible | tr '\000' '\n' | grep -c '^apple,')" -gt 0 ] || die "缺少 Apple 设备树"
if [ "$USB_PAYLOAD" = 1 ]; then
    tr '\000' '\n' < /proc/device-tree/compatible | grep -Fxq apple,j413 ||
        die "此外置安装器需要 MacBook Air M2（Mac14,2）"
fi
system_id=$(tr -d '\000\r\n' < /proc/device-tree/chosen/asahi,efi-system-partition | tr '[:upper:]' '[:lower:]')
valid_uuid "$system_id" && [ "$system_id" != "$boot_id" ] && [ "$system_id" != "$root_id" ] || die "无法区分内部与外部 EFI"

BOOT="/dev/disk/by-partuuid/$boot_id"
SYSTEM="/dev/disk/by-partuuid/$system_id"
ZPART="/dev/disk/by-partuuid/$root_id"
check_target() {
    for device in "$BOOT" "$SYSTEM" "$ZPART"; do
        [ -b "$device" ] || die "找不到分区：$device"
        observed=$(blkid -p -s PART_ENTRY_UUID -o value "$device" | tr '[:upper:]' '[:lower:]')
        [ "$observed" = "${device##*/}" ] || die "分区 PARTUUID 已变化：$device"
    done
    boot_parent=$(lsblk -ndo PKNAME "$(readlink -f "$BOOT")")
    root_parent=$(lsblk -ndo PKNAME "$(readlink -f "$ZPART")")
    system_parent=$(lsblk -ndo PKNAME "$(readlink -f "$SYSTEM")")
    [ -n "$root_parent" ] && [ "$boot_parent" = "$root_parent" ] &&
        [ -n "$system_parent" ] && [ "$system_parent" != "$root_parent" ] || die "目标必须是同一块外接盘上的两个分区"
    disk="/dev/$root_parent"
    [ "$(lsblk -ndo TRAN "$disk")" = usb ] || die "目标必须是 USB 盘"
    [ "$(lsblk -ndo PTTYPE "$disk")" = gpt ] || die "目标必须使用 GPT"
    [ "$(blockdev --getsize64 "$ZPART")" -ge "@MIN_ROOT_BYTES@" ] || die "ZFS 目标分区不足 32 GiB"
    [ "$(blkid -p -s LABEL -o value "$BOOT")" = ORDOPAYLOAD ] &&
        [ "$(blkid -p -s TYPE -o value "$BOOT")" = vfat ] || die "启动分区须为 FAT32 ORDOPAYLOAD"
    [ "$(blkid -p -s LABEL -o value "$ZPART")" = ORDOZFS ] &&
        [ "$(blkid -p -s TYPE -o value "$ZPART")" = exfat ] || die "系统分区须为新建的 ExFAT ORDOZFS"
}

check_unmounted() {
    mounts=$(lsblk -nr -o MOUNTPOINTS "$(readlink -f "$1")")
    [ -z "$mounts" ] || die "目标分区仍挂载：$1。请从 ORDOINNER 运行本脚本。"
}

check_boot_mount() {
    if [ "$USB_PAYLOAD" != 1 ]; then
        check_unmounted "$BOOT"
        return
    fi
    path=$(readlink -f "$BOOT")
    device_number=$(lsblk -dnro MAJ:MIN "$path")
    [ -n "$device_number" ] && [ "$(findmnt -nro MAJ:MIN -M "$PAYLOAD")" = "$device_number" ] ||
        die "Live 载荷没有挂在指定的外置启动分区"
    [ "$(lsblk -nr -o MOUNTPOINTS "$path")" = "$PAYLOAD" ] ||
        die "外置启动分区存在其他挂载"
    case ",$(findmnt -nro OPTIONS -M "$PAYLOAD")," in
        *,ro,*) ;;
        *) die "外置安装载荷须为只读挂载" ;;
    esac
}

check_initial_efi() {
    efi="$BOOT_MOUNT/EFI/BOOT/BOOTAA64.EFI"
    if [ "$USB_PAYLOAD" = 1 ]; then
        command -v openssl >/dev/null || die "缺少 openssl，不能核验 Live EFI"
        openssl dgst -sha256 -verify /ordo-live-efi.pem \
            -signature "$BOOT_MOUNT/live/ordo-live.efi.sig" "$efi" >/dev/null ||
            die "外置 EFI 与本次 Live 镜像不匹配"
    else
        [ ! -e "$efi" ] || die "已有外置 EFI 引导器"
    fi
}

check_target
check_boot_mount
check_unmounted "$ZPART"

modprobe zfs 2>/dev/null || [ -d /sys/module/zfs ] || die "Live 未加载 ZFS"
pools=$(zpool list -H -o name) || die "无法读取已导入的池"
if printf '%s\n' "$pools" | grep -Fxq "$POOL"; then die "rpool 已导入，停止"; fi
hostid_file="$PAYLOAD/kernel/hostid"
if [ "$USB_PAYLOAD" = 1 ]; then
    [ -n "$NATIVE_SHA" ] || die "外置安装需要原生 Asahi 载荷"
    hostid_file=/ordo-install-hostid
    (cd "$PAYLOAD" && sha256sum -c -) <<'ORDO_PAYLOAD_HASHES' || die "外置载荷校验失败"
@PAYLOAD_HASHES@
ORDO_PAYLOAD_HASHES
else
    for file in "kernel/vmlinuz-$KERNEL_RELEASE" kernel/system-asahi.img kernel/vmlinuz-asahi.EFI kernel/modules.tar.gz; do
        [ -s "$PAYLOAD/$file" ] || die "缺少安装资料：$file"
    done
fi
for suffix in 00 01 02 03; do
    [ -s "$PAYLOAD/rootfs.tar.gz.part$suffix" ] || die "缺少 rootfs 分片 $suffix"
done
# 6.8 GB 解包前先核哈希：分片被改写必须在这里停住，而不是把坏数据铺进新池（P1-01）
(cd "$PAYLOAD" && sha256sum -c -) <<'ORDO_ROOTFS_HASHES' || die "rootfs 分片校验失败"
@ROOTFS_HASHES@
ORDO_ROOTFS_HASHES
[ -f "$hostid_file" ] && [ "$(wc -c < "$hostid_file" | tr -d ' ')" = 4 ] || die "hostid 不是 4 字节"
if [ "$USB_PAYLOAD" != 1 ] && [ -f "$PAYLOAD/barefiles.tar.gz" ]; then
    (cd "$PAYLOAD" && echo "@BAREFILES_SHA@  barefiles.tar.gz" | sha256sum -c -) || die "真机软件包校验失败"
fi
if command -v cpio >/dev/null; then
    CPIO_RUN=cpio
elif busybox cpio --help >/dev/null 2>&1; then
    CPIO_RUN='busybox cpio'
else
    die "缺少 cpio"
fi

work=$(mktemp -d /mnt/ordo-external.XXXXXX)
TARGET="$work/root"
BOOT_MOUNT="$work/boot"
SYSTEM_MOUNT="$work/system"
mkdir "$TARGET" "$BOOT_MOUNT" "$SYSTEM_MOUNT"
if [ "$USB_PAYLOAD" = 1 ]; then
    BOOT_MOUNT="$PAYLOAD"
fi
pool_created=0
boot_rw=0
cleanup() {
    rc=$?
    trap - EXIT INT TERM HUP
    if mountpoint -q "$TARGET"; then umount -R "$TARGET" || rc=1; fi
    if [ "$pool_created" = 1 ]; then zpool export "$POOL" || rc=1; fi
    if [ "$boot_rw" = 1 ] && [ "$USB_PAYLOAD" = 1 ]; then
        mount -o remount,ro "$BOOT_MOUNT" || rc=1
    fi
    for dir in "$SYSTEM_MOUNT" "$work/boot"; do
        if mountpoint -q "$dir"; then umount "$dir" || rc=1; fi
    done
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

mount -t vfat -o ro "$SYSTEM" "$SYSTEM_MOUNT"
[ -s "$SYSTEM_MOUNT/m1n1/boot.bin" ] && [ -s "$SYSTEM_MOUNT/vendorfw/firmware.cpio" ] || die "内置 EFI 缺少 m1n1 或 Apple 固件"
if [ "$USB_PAYLOAD" != 1 ]; then mount -t vfat -o ro "$BOOT" "$BOOT_MOUNT"; fi
check_initial_efi
[ -f "$BOOT_MOUNT/extlinux/ordo-manual.conf" ] || die "外置盘缺少手动 Live 恢复入口"
(cd "$BOOT_MOUNT" && echo "@BUNDLE_SHA@  desktop-@BUNDLE_SHA@.tar.gz" | sha256sum -c -) || die "桌面安装包校验失败"
(cd "$BOOT_MOUNT" && echo "@SYSTEM_SHA@  live/system-@SYSTEM_SHA@.img" | sha256sum -c -) || die "系统启动镜像校验失败"
(cd "$BOOT_MOUNT" && echo "@UKI_SHA@  live/zbm-@UKI_SHA@.efi" | sha256sum -c -) || die "EFI 校验失败"
(cd "$BOOT_MOUNT" && echo "@DIRECT_SHA@  live/ordo-@DIRECT_SHA@.efi" | sha256sum -c -) || die "Ordo EFI 校验失败"
SYSTEM_KERNEL="$PAYLOAD/kernel/vmlinuz-$KERNEL_RELEASE"
if [ -n "$NATIVE_SHA" ]; then
    SYSTEM_KERNEL="$BOOT_MOUNT/live/vmlinuz-$KERNEL_RELEASE-@KERNEL_SHA@"
    (cd "$BOOT_MOUNT" && echo "$NATIVE_SHA  native-$NATIVE_SHA.tar.gz" | sha256sum -c -) || die "原生安装包校验失败"
fi
printf '%s  %s\n' '@KERNEL_SHA@' "$SYSTEM_KERNEL" | sha256sum -c - || die "系统内核校验失败"
available_kib=$(df -Pk "$BOOT_MOUNT" | awk 'NR==2 {print $4}')
required_kib=$(du -k "$SYSTEM_KERNEL" "$BOOT_MOUNT/live/system-@SYSTEM_SHA@.img" \
    "$BOOT_MOUNT/live/zbm-@UKI_SHA@.efi" "$BOOT_MOUNT/live/ordo-@DIRECT_SHA@.efi" |
    awk '{sum += $1} END {print sum + 4096}')
[ "$available_kib" -gt "$required_kib" ] || die "启动分区可用空间不足"
lsblk -o PATH,SIZE,TYPE,TRAN,FSTYPE,LABEL,PARTUUID "$disk"
say "预检通过，内置 EFI 以只读方式访问"
[ "$mode" = --apply ] || exit 0

confirm=$(printf '%s' "$root_id" | tail -c 4)
printf '确认后会清除上方的 ORDOZFS 分区。请先核对目标和备份。\n'
printf 'Type INSTALL %s to install: ' "$confirm"
read -r answer || die "已取消"
[ "$answer" = "INSTALL $confirm" ] || die "已取消"
check_target
check_unmounted "$ZPART"
[ "$USB_PAYLOAD" != 1 ] || check_boot_mount
check_initial_efi
wipefs -a -- "$ZPART"
say "4/7 建池并铺 rootfs"
# The preflight checks the four bytes shared with ZBM and the installed initramfs.
cp "$hostid_file" /etc/hostid

zpool create -R "$TARGET" -o ashift=12 -O compression=zstd -O atime=off \
    -O mountpoint=none -O xattr=sa "$POOL" "$ZPART"
pool_created=1
zfs create -o mountpoint=none "$POOL/root"
# root 用 legacy + 显式 active=on：ZBM 只把 legacy 且 active=on 的数据集当 BE
# （install.sh:422-425「没有这一行，ZBM 的 BE 候选集为空」）
zfs create -o mountpoint=legacy "$ROOTDS"
zfs set org.zfsbootmenu:active=on "$ROOTDS"
# /home 用正常 mountpoint，交给 zfs-mount 自动挂，不写进 fstab
zfs create -o mountpoint=/home -o canmount=noauto "$HOMEDS"
# swap zvol（M2 Air 无 swap 风险高）
# 512e 盘上 512 的 volblocksize 元数据开销大且慢，写死 4K
zfs create -V 4G -b 4096 \
    -o compression=zle -o logbias=throughput -o sync=always \
    -o primarycache=metadata -o secondarycache=none \
    -o com.sun:auto-snapshot=false "$POOL/swap"
# 交换区需要签名；实测缺 mkswap 时首启 swapon 失败（读交换区头失败）
if command -v udevadm >/dev/null; then udevadm settle; fi
mkswap "/dev/zvol/$POOL/swap"

# 池缓存按 ADR 0013 修复 #4 定案保留（绝对路径）：Gentoo zfs-import 的 verbatim 分支
# 外置池以 PARTUUID 标识，USB 设备的枚举顺序可以变化。
mkdir -p /etc/zfs
zpool set cachefile=/etc/zfs/zpool.cache "$POOL"

mkdir -p "$TARGET"
mount -t zfs "$ROOTDS" "$TARGET"
echo "解包 rootfs（约 3-5 分钟）..."
cat "$PAYLOAD"/rootfs.tar.gz.part00 "$PAYLOAD"/rootfs.tar.gz.part01 \
    "$PAYLOAD"/rootfs.tar.gz.part02 "$PAYLOAD"/rootfs.tar.gz.part03 | tar -xz -C "$TARGET" --numeric-owner \
    --exclude='./swapfile' --exclude='./usr/src/linux-*' --exclude='./var/cache/binpkgs' \
    --xattrs --xattrs-include='*.*' || die "解包失败"
echo "rootfs 解包完成：$(du -sh "$TARGET" | cut -f1)"

# 清理 VM 时代带进来、真机上没用的东西。实测这些占了 14.7GB：
#   /swapfile        8.00GB  ← VM 的 swap 文件；我们用 ZFS swap zvol，这个纯占地方
#   /usr/src/linux-* 4.60GB  ← 内核源码；真机不需要编译内核（模块另发）
#   /var/cache/binpkgs 2.09GB ← VM 时代 quickpkg 的产物
say "清理冗余（预计回收约 15GB）"
rm -f "$TARGET/swapfile"
rm -rf "$TARGET/usr/src/linux-"* 2>/dev/null || true
rm -rf "$TARGET/var/cache/binpkgs" 2>/dev/null || true
# VM 的 machine-id 与 SSH 主机密钥不带走；OpenRC/D-Bus 首启自行再生
rm -f "$TARGET/etc/machine-id" "$TARGET"/etc/ssh/ssh_host_* 2>/dev/null || true
echo "清理后：$(du -sh "$TARGET" | cut -f1)"

# tarball 顶层目录带着 VM 时代的 uid 501，会让 systemd-tmpfiles 报 unsafe path transition；
# 统一归零（非递归，只碰顶层）
chown -h 0:0 "$TARGET" "$TARGET"/*

for d in boot efi home proc sys dev run tmp; do mkdir -p "$TARGET/$d"; done
chmod 1777 "$TARGET/tmp"

say "5/7 用户家目录"
# VM 的 /home 是单独数据集，没被打进 tarball；必须从 skel 重建。
# 【必须加 -o zfsutil】HOMEDS 的 mountpoint 属性是 /home，而这里要挂到
# $TARGET/home（=/mnt/ordo/home）。不带 zfsutil 时 mount.zfs helper 会按
# mountpoint 属性行事、拒绝挂在别处，表现为 "filesystem was not mounted"。
zfs mount "$HOMEDS" || die "/home 数据集挂载失败"
if [ "$USB_PAYLOAD" = 1 ]; then
    if ! chroot "$TARGET" getent passwd ordo >/dev/null; then
        chroot "$TARGET" useradd -u 1000 -U -m -G wheel,video,input,portage -s /bin/zsh ordo ||
            die "无法创建桌面账户"
    fi
    [ "$(chroot "$TARGET" id -u ordo)" = 1000 ] || die "桌面账户 UID 必须为 1000"
    chroot "$TARGET" usermod -p '!' root || die "无法锁定 root 口令"
    printf 'permit persist :wheel\n' > "$TARGET/etc/doas.conf"
    chmod 0400 "$TARGET/etc/doas.conf"
    say "为本机的 ordo 账户设置密码（用于登录和 doas）"
    mount --bind /dev "$TARGET/dev" || die "无法准备密码输入设备"
    chroot "$TARGET" passwd ordo || die "未设置桌面账户密码"
    umount "$TARGET/dev" || die "无法卸载密码输入设备"
fi
if [ ! -d "$TARGET/home/ordo" ]; then
    mkdir -p "$TARGET/home/ordo"
    [ -d "$TARGET/etc/skel" ] && cp -a "$TARGET/etc/skel/." "$TARGET/home/ordo/" 2>/dev/null || true
    chown -R 1000:1000 "$TARGET/home/ordo"
    echo "已从 /etc/skel 重建 /home/ordo"
else
    echo "/home/ordo 已存在"
fi
# 用户级 OpenRC（音频/会话总线）需要 runlevel 目录
mkdir -p "$TARGET/home/ordo/.config/rc/runlevels/boot" \
         "$TARGET/home/ordo/.config/rc/runlevels/default"
for s in dbus pipewire pipewire-pulse wireplumber; do
    [ -f "$TARGET/etc/user/init.d/$s" ] && \
        ln -sfn "/etc/user/init.d/$s" "$TARGET/home/ordo/.config/rc/runlevels/default/$s"
done
[ -f "$TARGET/etc/user/init.d/dbus" ] && \
    ln -sfn /etc/user/init.d/dbus "$TARGET/home/ordo/.config/rc/runlevels/boot/dbus"
chown -R 1000:1000 "$TARGET/home/ordo/.config" 2>/dev/null || true

say "6/7 内核、模块、固件"
cp "$SYSTEM_KERNEL" "$TARGET/boot/vmlinuz-$KERNEL_RELEASE"
cp "$BOOT_MOUNT/live/system-@SYSTEM_SHA@.img" "$TARGET/boot/initramfs-$KERNEL_RELEASE.img"
if [ -n "$NATIVE_SHA" ]; then
    NATIVE_FILES="$TARGET/var/tmp/ordo-native"
    mkdir -p "$NATIVE_FILES"
    tar -xzf "$BOOT_MOUNT/native-$NATIVE_SHA.tar.gz" -C "$NATIVE_FILES" || die "原生安装包解包失败"
    [ -s "$NATIVE_FILES/modules/$KERNEL_RELEASE/modules.dep" ] || die "原生内核模块索引缺失"
    mkdir -p "$TARGET/lib/modules"
    [ ! -e "$TARGET/lib/modules/$KERNEL_RELEASE" ] || die "根文件系统已包含此原生内核版本"
    mv "$NATIVE_FILES/modules/$KERNEL_RELEASE" "$TARGET/lib/modules/"
    if [ -s "$NATIVE_FILES/boot/config-$KERNEL_RELEASE" ]; then
        mv "$NATIVE_FILES/boot/config-$KERNEL_RELEASE" "$TARGET/boot/"
    fi
else
    tar -xzf "$PAYLOAD/kernel/modules.tar.gz" -C "$TARGET/lib/modules/" --numeric-owner || \
        die "Asahi 内核模块解包失败"
    install -m 0644 /ordo-power.ko "$TARGET/@POWER_MODULE@"
fi

# asahi 驱动显式加载（udev 冷插为主，这里做二次保险）
mkdir -p "$TARGET/etc/modules-load.d"
cat > "$TARGET/etc/modules-load.d/ordo-asahi.conf" <<'MLEOF'
# Ordo — Apple Silicon 必需模块（显式加载，补 udev 冷插的保险）
macsmc
spi-apple
spi-hid-apple
nvme-apple
MLEOF

# 真机专用包（world.bare-metal 那批：音频 UCM / 电源管理 / i2c）
# VM 的 rootfs 里没有这些；已预转成 barefiles.tar.gz 以避开 live 环境对 zstd 的依赖。
if [ "$USB_PAYLOAD" != 1 ] && [ -f "$PAYLOAD/barefiles.tar.gz" ]; then
    echo "安装真机专用包..."
    # The pinned archive was staged on macOS and records UID 501 for every entry.
    tar --keep-directory-symlink --no-overwrite-dir --no-same-owner --exclude='._*' \
        -xzf "$PAYLOAD/barefiles.tar.gz" -C "$TARGET" \
        && echo "真机包就位（alsa-ucm-conf/upower/power-profiles-daemon/i2c-tools）" \
        || warn "真机包解包失败，音频/电源管理可能缺件"
elif [ "$USB_PAYLOAD" != 1 ]; then
    warn "缺少 barefiles.tar.gz，音频/电源管理将缺件"
fi

# Apple 固件：安装器放在 ESP 的 vendorfw/firmware.cpio
if [ -f "$SYSTEM_MOUNT/vendorfw/firmware.cpio" ]; then
    echo "解出 Apple 固件..."
    mkdir -p "$TARGET/lib/firmware"
    cp "$SYSTEM_MOUNT/vendorfw/firmware.cpio" "$work/firmware.cpio"
    if (cd "$TARGET/lib/firmware" && $CPIO_RUN -idm < "$work/firmware.cpio" >/dev/null); then
        ln -sfn vendorfw "$TARGET/lib/firmware/vendor"
        echo "固件就位：$(du -sh "$TARGET/lib/firmware/vendorfw" 2>/dev/null | cut -f1)"
    else
        die "Apple 固件解包失败"
    fi
    rm -f "$work/firmware.cpio"
else
    die "内置 EFI 缺少 Apple 固件"
fi
install -m 0644 /usr/lib/firmware/regulatory.db /usr/lib/firmware/regulatory.db.p7s "$TARGET/lib/firmware/"

say "7/7 配置与 ZBM"
# fstab：不写任何 zfs 行（走 mountpoint 属性）；ESP 用 noauto，不参与启动关键路径
cat > "$TARGET/etc/fstab" <<EOF
# Ordo — 由 install-ordo.sh 生成
# zfs 数据集由 mountpoint 属性自动挂载，不在此列
/dev/zvol/$POOL/swap  none  swap  sw  0 0
EOF

echo ordo > "$TARGET/etc/hostname"
[ -f "$TARGET/etc/conf.d/hostname" ] && sed -i 's/^hostname=.*/hostname="ordo"/' "$TARGET/etc/conf.d/hostname" || true

# 真机 runlevels 校准
mkdir -p "$TARGET/opt/ordo"
tar -xzf "$BOOT_MOUNT/desktop-@BUNDLE_SHA@.tar.gz" -C "$TARGET/opt/ordo"
if [ "$USB_PAYLOAD" = 1 ]; then
    luciole="$TARGET/opt/ordo/overlay/gui-apps/luciole"
    for file in "$luciole"/Manifest "$luciole"/*.ebuild; do
        [ -f "$file" ] || die "本地 overlay 缺少 $(basename "$file")"
        install -Dm644 "$file" "$TARGET/var/db/repos/local/gui-apps/luciole/${file##*/}"
    done
fi
# 固件请求名补齐（P1-03）：Apple 固件包只带源文件名，brcmfmac 按板型后缀请求。
# 映射表与 dev/m2/build.py、boot-sync.sh、verify-hardware.sh 共读同一份。
link_vendorfw() {
    _map=$TARGET/opt/ordo/config/platform/m2/wireless-firmware
    _root="$TARGET/lib/firmware/vendorfw"
    [ -s "$_map" ] || die "缺少无线固件映射表"
    [ -d "$_root" ] || die "缺少 Apple 固件目录"
    while IFS= read -r _line || [ -n "$_line" ]; do
        _line=${_line%%#*}
        case "$_line" in *[![:space:]]*) ;; *) continue ;; esac
        set -- $_line
        _source=$1
        _primary=$2
        shift 2
        [ -s "$_root/$_source" ] || die "缺少 Apple 固件：$_source"
        install -Dm644 "$_root/$_source" "$_root/$_primary"
        for _alias in "$@"; do
            mkdir -p "$_root/${_alias%/*}"
            ln -sfn "${_primary##*/}" "$_root/$_alias"
        done
    done < "$_map"
}
link_vendorfw

build_version=$(cat "$TARGET/opt/ordo/version")
version=${build_version%%-*}
printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "发行版本无效"
rm -f -- "$TARGET/etc/os-release"
cat > "$TARGET/etc/os-release" <<OSREL
NAME="Ordo Linux"
PRETTY_NAME="Ordo Linux $version (Ab Chao)"
ID=ordo
ID_LIKE=gentoo
BUILD_ID=$version
VERSION_ID=$version
VERSION="$version (Ab Chao)"
VERSION_CODENAME=ab-chao
HOME_URL="https://github.com/ordo-linux/ordo"
SUPPORT_URL="https://github.com/ordo-linux/ordo/issues"
BUG_REPORT_URL="https://github.com/ordo-linux/ordo/issues"
OSREL
ln -sfn /etc/os-release "$TARGET/usr/lib/os-release"
if [ -z "$NATIVE_SHA" ]; then
    sh "$TARGET/opt/ordo/config/platform/m2/install-display.sh" "$TARGET/lib/modules/$KERNEL_RELEASE" \
        "$TARGET/opt/ordo/dev/m2/display/modules.tar.gz"
fi
mount -t proc proc "$TARGET/proc" 2>/dev/null || true
mount -t sysfs sysfs "$TARGET/sys" 2>/dev/null || true
mount --bind /dev "$TARGET/dev" 2>/dev/null || true
if [ "$USB_PAYLOAD" = 1 ]; then
    policy=/opt/ordo/config/desktop/keyring-policy.sh
    chroot "$TARGET" /bin/sh "$policy" check || die "发行根系统含旧版密钥服务"
fi
if [ -n "$NATIVE_SHA" ]; then
    for fs in proc sys dev; do mountpoint -q "$TARGET/$fs" || die "原生安装需要挂载 $fs"; done
    cp /etc/hostid "$TARGET/etc/hostid"
    chroot "$TARGET" /bin/sh /opt/ordo/config/platform/m2/install-hardware.sh
    chroot "$TARGET" /bin/sh /opt/ordo/config/platform/m2/install-native.sh "$KERNEL_RELEASE" "$root_id" || \
        die "原生内核、ZFS 或硬件软件包未通过验收"
    rm -rf "$NATIVE_FILES"
fi
if [ "$USB_PAYLOAD" = 1 ]; then
    chroot "$TARGET" /bin/sh "$policy" check || die "硬件包引入了密钥服务"
fi
chroot "$TARGET" /bin/sh /opt/ordo/config/platform/m2/install-cli.sh || die "Ordo CLI 安装失败"
if [ "$USB_PAYLOAD" = 1 ]; then
    greeter="$TARGET/opt/ordo/config/desktop/greetd"
    install -Dm755 "$greeter/greetd.initd" "$TARGET/etc/init.d/greetd"
    install -Dm644 "$greeter/pam.d-greetd" "$TARGET/etc/pam.d/greetd"
    install -Dm644 "$greeter/tmpfiles-noctalia-greeter.conf" "$TARGET/etc/tmpfiles.d/noctalia-greeter.conf"
    chroot "$TARGET" usermod -aG video,input greetd
    chroot "$TARGET" install -d -m 750 -o greetd -g greetd /var/lib/greetd
    chroot "$TARGET" systemd-tmpfiles --create /etc/tmpfiles.d/noctalia-greeter.conf
    sed -i -E '/^[^#][^:]*:.*[[:space:]]tty1([[:space:]]|$)/s/^/# /' "$TARGET/etc/inittab"
    install -Dm755 "$TARGET/opt/ordo/config/zfs-arc.start" "$TARGET/etc/local.d/zz-zfs-arc.start"
    for _set in @ordo-core @ordo-m2; do
        [ -f "$TARGET/etc/portage/sets/${_set#@}" ] || continue
        mkdir -p "$TARGET/var/lib/portage"
        : >> "$TARGET/var/lib/portage/world_sets"
        grep -Fxq "$_set" "$TARGET/var/lib/portage/world_sets" ||
            printf '%s\n' "$_set" >> "$TARGET/var/lib/portage/world_sets"
    done
    chroot "$TARGET" /bin/sh /opt/ordo/scripts/ordo-config apply world || die "无法启用平台包集"
    for service in dbus:default elogind:boot zfs-import:boot zfs-mount:boot \
        NetworkManager:default power-profiles-daemon:default chronyd:default cronie:default local:default; do
        chroot "$TARGET" rc-update add "${service%:*}" "${service#*:}" || die "无法启用 $service"
    done
fi
chroot "$TARGET" /bin/sh -c '
    rc-update del sshd default 2>/dev/null || true
    rc-update add bluetooth default 2>/dev/null || true
    rc-update add zfs-zed default 2>/dev/null || true
    /bin/sh /opt/ordo/config/platform/m2/first-desktop.sh
' || die "首启桌面配置失败"
umount "$TARGET/dev" 2>/dev/null || true
umount "$TARGET/sys" 2>/dev/null || true
umount "$TARGET/proc" 2>/dev/null || true

# ---- 构建清单（P1-02）----
# M2 外置安装此前不产 /etc/ordo/build-manifest，真机上 `ordo config verify`
# 恒 exit 2（无法判定）。生成器与 install.sh / VM 装配共用
# scripts/ordo-build-manifest，格式只在那里定义。
# 平台取 install-hardware.sh / install-native.sh 刚写下的值（m2 / m2-native）。
_manifest_platform=$(cat "$TARGET/etc/ordo/platform" 2>/dev/null || printf '%s\n' m2)
chroot "$TARGET" /bin/sh /opt/ordo/scripts/ordo-build-manifest / "$_manifest_platform" arm64 \
    || die "构建清单生成失败（$TARGET/etc/ordo/build-manifest）"

for ssh_service in "$TARGET"/etc/runlevels/*/sshd; do
    [ -L "$ssh_service" ] || continue
    rm -f -- "$ssh_service" || die "无法停用镜像自带的 sshd"
done
# hostid 必须跟池一起落到目标系统（ADR 0002「三处一致」）
# 池缓存也随 hostid 一起拷入：ADR 0013 修复 #4 的 verbatim 分支要求缓存存在，
# 真机内部 NVMe 的 /dev/nvme0n1pN 路径在 BE 引导时不变。
if [ -f /etc/hostid ]; then
    cp /etc/hostid "$TARGET/etc/hostid"
    echo "hostid 已对齐"
else
    warn "live 环境无 /etc/hostid"
fi
mkdir -p "$TARGET/etc/zfs"
cp /etc/zfs/zpool.cache "$TARGET/etc/zfs/zpool.cache"
echo "池缓存与 hostid 已随池一起落进目标系统"

# inittab 清掉 VM 专用项（ttyAMA0 串口 getty、startDM）
if [ -f "$TARGET/etc/inittab" ]; then
    sed -i '/ttyAMA0/d; /startDM/d' "$TARGET/etc/inittab"
fi

# 丢掉 VM 的池缓存与网络残留
rm -f "$TARGET/usr/lib/initramfs/zz-ordo-zpool.cache" 2>/dev/null || true
: > "$TARGET/etc/resolv.conf" 2>/dev/null || true

say "写入外置 Bootloader"
mount -o remount,rw "$BOOT_MOUNT"
boot_rw=1
mkdir -p "$BOOT_MOUNT/EFI/BOOT" "$BOOT_MOUNT/ordo-kernel"
check_initial_efi
cp "$SYSTEM_KERNEL" "$BOOT_MOUNT/ordo-kernel/vmlinuz"
cp "$BOOT_MOUNT/live/system-@SYSTEM_SHA@.img" "$BOOT_MOUNT/ordo-kernel/initramfs.img"
mkdir -p "$BOOT_MOUNT/EFI/Ordo"
cp "$BOOT_MOUNT/live/zbm-@UKI_SHA@.efi" "$BOOT_MOUNT/EFI/Ordo/ZFSBootMenu.EFI"
cp "$BOOT_MOUNT/live/ordo-@DIRECT_SHA@.efi" "$BOOT_MOUNT/EFI/BOOT/ORDO.NEW"
cat > "$BOOT_MOUNT/extlinux/ordo-system.conf" <<'XEOF'
TIMEOUT 50
DEFAULT ordo

LABEL ordo
  KERNEL /ordo-kernel/vmlinuz
  INITRD /ordo-kernel/initramfs.img
  APPEND root=zfs:AUTO ro loglevel=7 console=tty0 firmware_class.path=/lib/firmware/vendorfw

LABEL ordo-manual
  KERNEL /live/vmlinuz-asahi
  INITRD /live/initramfs-live-manual.img
  APPEND console=tty0 loglevel=7 ignore_loglevel
XEOF
zpool set bootfs="$ROOTDS" "$POOL"
zfs set canmount=on "$HOMEDS"
zfs snapshot "$ROOTDS@install-$(date +%Y%m%d-%H%M%S)"
umount -R "$TARGET"
zpool export "$POOL"
pool_created=0
cp "$BOOT_MOUNT/extlinux/ordo-system.conf" "$BOOT_MOUNT/extlinux/ordo-system.new"
mv -f "$BOOT_MOUNT/extlinux/ordo-system.new" "$BOOT_MOUNT/extlinux/extlinux.conf"
check_initial_efi
mv -f "$BOOT_MOUNT/EFI/BOOT/ORDO.NEW" "$BOOT_MOUNT/EFI/BOOT/BOOTAA64.EFI"
# NVRAM 写不进去时，EFI/BOOT/BOOTAA64.EFI 是唯一的引导入口，必须读回核对（P1-01）
cmp -s "$BOOT_MOUNT/EFI/BOOT/BOOTAA64.EFI" "$BOOT_MOUNT/live/ordo-@DIRECT_SHA@.efi" ||
    die "默认引导文件读回不一致：EFI/BOOT/BOOTAA64.EFI"
sync
say "外置盘已写入，池已导出。保留这块 USB 盘再从 Ordo Linux 启动。"
