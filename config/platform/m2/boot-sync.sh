#!/bin/sh
# Runtime coordination for the M2 removable EFI and its matching ZFS BE.
# shellcheck disable=SC2034 # paths and selected release are used by the callers
M2_BOOT_DIR="$ORDO_ROOT/config/platform/m2"
M2_BOOT_WORK=
M2_BOOT_MOUNTED=0
M2_BOOT_BE_MOUNTED=0

m2_boot_cleanup() {
    if [ "$M2_BOOT_BE_MOUNTED" -eq 1 ]; then
        umount "$M2_BOOT_WORK/be" || ordo_warn "无法卸载 $M2_BOOT_WORK/be"
    fi
    if [ "$M2_BOOT_MOUNTED" -eq 1 ]; then
        umount "$M2_BOOT_WORK/esp" || ordo_warn "无法卸载 $M2_BOOT_WORK/esp"
    fi
    if [ -n "$M2_BOOT_WORK" ]; then
        rm -rf "$M2_BOOT_WORK/hooks" "$M2_BOOT_WORK/firmware"
        rm -f "$M2_BOOT_WORK/firmware.sha256"
        rmdir "$M2_BOOT_WORK/be" "$M2_BOOT_WORK/esp" "$M2_BOOT_WORK" 2>/dev/null || :
    fi
}

m2_boot_open() {
    if [ ! -r /proc/device-tree/chosen/asahi,efi-system-partition ]; then
        ordo_bad "找不到内部 Asahi EFI 的设备树标识"
        return "$ORDO_EXIT_UNKNOWN"
    fi
    ordo_require_tools blkid findmnt flock install ln lsblk modinfo modprobe mount python3 sha256sum sort umount zpool zstd
    mkdir -p /run/lock || return "$ORDO_EXIT_BAD"
    exec 9>/run/lock/ordo-m2-boot.lock
    flock -n 9 || { ordo_bad "已有 M2 升级或回滚正在运行"; return "$ORDO_EXIT_BAD"; }

    _m2_status=$(zpool status -PL "$1") || return "$ORDO_EXIT_UNKNOWN"
    # This installer creates exactly one whole-disk leaf partition in the pool.
    # Do not guess which disk owns the boot files of a richer pool topology.
    _m2_root=$(printf '%s\n' "$_m2_status" | awk '/^[[:space:]]*\/dev\// {print $1}')
    [ -b "$_m2_root" ] || { ordo_bad "无法确认外置 ZFS 分区"; return "$ORDO_EXIT_UNKNOWN"; }
    _m2_parent=$(lsblk -dno PKNAME "$_m2_root") || return "$ORDO_EXIT_UNKNOWN"
    _m2_parts=$(lsblk -rpn -o NAME,TYPE,PARTN "/dev/$_m2_parent") || return "$ORDO_EXIT_UNKNOWN"
    _m2_esp=$(printf '%s\n' "$_m2_parts" | awk '$2 == "part" && $3 == 1 { print $1 }')
    _m2_root_part=$(printf '%s\n' "$_m2_parts" | awk '$2 == "part" && $3 == 2 { print $1 }')
    if [ "$_m2_root" != "$_m2_root_part" ] || [ ! -b "$_m2_esp" ]; then
        ordo_bad "外置盘分区布局与 Ordo 安装不符"
        return "$ORDO_EXIT_UNKNOWN"
    fi

    _m2_internal=$(tr -d '\000\r\n' < /proc/device-tree/chosen/asahi,efi-system-partition | tr '[:upper:]' '[:lower:]')
    _m2_esp_id=$(blkid -p -s PART_ENTRY_UUID -o value "$_m2_esp") || return "$ORDO_EXIT_UNKNOWN"
    M2_ROOT_ID=$(blkid -p -s PART_ENTRY_UUID -o value "$_m2_root") || return "$ORDO_EXIT_UNKNOWN"
    _m2_internal_device="/dev/disk/by-partuuid/$_m2_internal"
    _m2_internal_parent=$(lsblk -dno PKNAME "$_m2_internal_device") || return "$ORDO_EXIT_UNKNOWN"
    if [ -z "$_m2_internal" ] || [ -z "$_m2_internal_parent" ] || [ "$_m2_internal_parent" = "$_m2_parent" ] ||
       [ "$_m2_internal" = "$_m2_esp_id" ] || [ "$_m2_internal" = "$M2_ROOT_ID" ] ||
       [ "$(blkid -p -s TYPE -o value "$_m2_esp")" != vfat ]; then
        ordo_bad "无法将外置 FAT 启动分区与内部 Asahi EFI 区分"
        return "$ORDO_EXIT_UNKNOWN"
    fi
    if findmnt -rn -S "$_m2_esp" >/dev/null; then
        ordo_bad "外置启动分区已挂载：$_m2_esp"
        return "$ORDO_EXIT_BAD"
    fi

    M2_BOOT_WORK=$(mktemp -d /run/ordo-m2-boot.XXXXXX) || return "$ORDO_EXIT_BAD"
    trap m2_boot_cleanup 0
    mkdir "$M2_BOOT_WORK/esp" "$M2_BOOT_WORK/be" || return "$ORDO_EXIT_BAD"
    if mount -t vfat -o ro,nodev,nosuid,noexec,umask=0077 "$_m2_esp" "$M2_BOOT_WORK/esp"; then
        M2_BOOT_MOUNTED=1
    else
        return "$ORDO_EXIT_BAD"
    fi
    PYTHONDONTWRITEBYTECODE=1 python3 "$M2_BOOT_DIR/boot-sync.py" "$M2_BOOT_WORK/esp"
}

m2_boot_select() {
    M2_BOOT_ROOT=${1%/}
    M2_NATIVE=0
    if [ -r "$M2_BOOT_ROOT/etc/ordo/platform" ] &&
       [ "$(cat "$M2_BOOT_ROOT/etc/ordo/platform")" = m2-native ]; then
        M2_NATIVE=1
    fi
    M2_RELEASE=$(
        for _m2_kernel in "$1"/boot/vmlinuz-*asahi*; do
            [ -s "$_m2_kernel" ] || continue
            _m2_name=${_m2_kernel##*/vmlinuz-}
            case "$_m2_name" in (*[!A-Za-z0-9._+-]*|*.old|*.bak) continue ;; esac
            if [ "$M2_NATIVE" -eq 1 ] &&
               ! modinfo -b "${M2_BOOT_ROOT:-/}" -k "$_m2_name" asahi >/dev/null 2>&1; then
                continue
            fi
            printf '%s\n' "$_m2_name"
        done | LC_ALL=C sort -V | tail -1
    )
    if [ -z "$M2_RELEASE" ] || [ ! -s "$1/lib/modules/$M2_RELEASE/modules.dep" ]; then
        ordo_bad "找不到配套模块索引的 Asahi 内核"
        return "$ORDO_EXIT_BAD"
    fi
    M2_KERNEL="$1/boot/vmlinuz-$M2_RELEASE"
    M2_INITRD="$1/boot/initramfs-$M2_RELEASE.img"
    if [ ! -s "$M2_INITRD" ] && [ -s "${M2_INITRD%.img}" ]; then
        M2_INITRD=${M2_INITRD%.img}
    fi
}

m2_boot_drivers() {
    cat "$M2_BOOT_DIR/platform-modules" "$M2_BOOT_DIR/boot-drivers" || return 1
    if [ "$M2_NATIVE" -eq 1 ]; then
        printf '%s\n' asahi
    fi
}

# Resolve dependencies using the selected kernel's own indices. Built-ins
# satisfy the requirement but do not belong in the initramfs module tree.
m2_boot_module_paths() {
    _m2_dep_root=$1
    _m2_dep_release=$2
    shift 2
    for _m2_driver do
        _m2_deps=$(modprobe -d "$_m2_dep_root" -S "$_m2_dep_release" --show-depends "$_m2_driver") || return 1
        [ -n "$_m2_deps" ] || return 1
        printf '%s\n' "$_m2_deps" | awk '/^insmod / {
            sub(/^insmod .*\/lib\/modules\/[^/]+\//, "")
            sub(/[[:space:]].*/, "")
            print
        }'
    done
}

m2_boot_firmware() {
    _m2_fw_dir="$M2_BOOT_ROOT/lib/firmware"
    [ -s "$M2_BOOT_DIR/wireless-firmware" ] || return 1
    _m2_fw_dest=${1:-}
    # 映射来自 wireless-firmware：源文件名 → 内核请求名（首个落副本，其余符号链接）。
    # 只放源文件名时 brcmfmac 一条都请求不到（P1-03）。
    while IFS= read -r _m2_line || [ -n "$_m2_line" ]; do
        _m2_line=${_m2_line%%#*}
        case "$_m2_line" in
            *[![:space:]]*) ;;
            *) continue ;;
        esac
        # shellcheck disable=SC2086 # 映射用空白分隔，这里就要按词拆
        set -- $_m2_line
        _m2_src=$1
        _m2_primary=$2
        shift 2
        _m2_source="$_m2_fw_dir/$_m2_src"
        case "$_m2_src" in
            (apple/*|brcm/*) _m2_source="$_m2_fw_dir/vendorfw/$_m2_src" ;;
        esac
        [ -s "$_m2_source" ] || { printf '缺少 J413 固件：%s\n' "$_m2_source" >&2; return 1; }
        if [ -n "$_m2_fw_dest" ]; then
            install -Dm644 "$_m2_source" "$_m2_fw_dest/$_m2_primary" || return 1
            for _m2_alias in "$@"; do
                mkdir -p "$_m2_fw_dest/${_m2_alias%/*}" || return 1
                ln -sfn "${_m2_primary##*/}" "$_m2_fw_dest/$_m2_alias" || return 1
            done
        fi
        _m2_checksum=$(sha256sum "$_m2_source") || return 1
        printf '%s  usr/lib/firmware/%s\n' "${_m2_checksum%% *}" "$_m2_primary"
        for _m2_alias in "$@"; do
            printf 'symlink:%s  usr/lib/firmware/%s\n' "${_m2_primary##*/}" "$_m2_alias"
        done
    done < "$M2_BOOT_DIR/wireless-firmware"
    for _m2_fw in apple/tpmtfw-j413.bin regulatory.db regulatory.db.p7s; do
        _m2_fw_source="$_m2_fw_dir/$_m2_fw"
        case "$_m2_fw" in
            (apple/*|brcm/*) _m2_fw_source="$_m2_fw_dir/vendorfw/$_m2_fw" ;;
        esac
        [ -s "$_m2_fw_source" ] || { printf '缺少 J413 固件：%s\n' "$_m2_fw_source" >&2; return 1; }
        if [ -n "$_m2_fw_dest" ]; then
            install -Dm644 "$_m2_fw_source" "$_m2_fw_dest/$_m2_fw" || return 1
        fi
        _m2_checksum=$(sha256sum "$_m2_fw_source") || return 1
        printf '%s  usr/lib/firmware/%s\n' "${_m2_checksum%% *}" "$_m2_fw"
    done
}

m2_boot_check_initrd() {
    [ -s "$1" ] || return 1
    _m2_policy=${3:-rollback}
    set -- --check-initrd "$1" "$M2_RELEASE" "$M2_ROOT_ID" "$2"
    if [ "$M2_NATIVE" -eq 1 ] || [ "$_m2_policy" = forward ]; then
        _m2_manifest="$M2_BOOT_WORK/firmware.sha256"
        m2_boot_firmware > "$_m2_manifest" || return 1
        set -- "$@" --firmware-manifest "$_m2_manifest"
        _m2_required=$(m2_boot_drivers) || return 1
        # shellcheck disable=SC2086 # one declared module name per word
        _m2_paths=$(m2_boot_module_paths "${M2_BOOT_ROOT:-/}" "$M2_RELEASE" $_m2_required zfs) || return 1
        for _m2_mod_path in $_m2_paths; do
            case "${_m2_mod_path##*/}" in
                (zfs.ko|zfs.ko.*) ;; # validated separately against ZFS userspace below
                (*) set -- "$@" --driver "$_m2_mod_path" ;;
            esac
        done
    fi
    PYTHONDONTWRITEBYTECODE=1 python3 "$M2_BOOT_DIR/boot-sync.py" "$@"
}

m2_boot_build_initrd() {
    ordo_require_tools dracut modinfo cpio
    _m2_drivers=$(
        while IFS= read -r _m2_driver; do
            modinfo -k "$M2_RELEASE" "$_m2_driver" >/dev/null 2>&1 || exit 1
            printf '%s ' "$_m2_driver"
        done < "$M2_BOOT_DIR/platform-modules"
    ) || { ordo_bad "新内核缺少 M2 早期引导驱动"; return "$ORDO_EXIT_BAD"; }

    # The original supported Asahi release uses usb-storage without UAS.
    # Include the available host-controller and storage variants for the new release.
    for _m2_driver in xhci-hcd xhci-pci xhci-plat-hcd uas usb-storage; do
        if modinfo -k "$M2_RELEASE" "$_m2_driver" >/dev/null 2>&1; then
            _m2_drivers="$_m2_drivers $_m2_driver"
        fi
    done

    _m2_extra_drivers=$(m2_boot_drivers) || return "$ORDO_EXIT_BAD"
    _m2_extra_drivers=$(printf '%s' "$_m2_extra_drivers" | tr '\n' ' ')
    _m2_firmware="$M2_BOOT_WORK/firmware"
    m2_boot_firmware "$_m2_firmware" > "$M2_BOOT_WORK/firmware.sha256" || return "$ORDO_EXIT_BAD"
    _m2_hooks="$M2_BOOT_WORK/hooks"
    mkdir -p "$_m2_hooks/pre-trigger" "$_m2_hooks/pre-mount" || return "$ORDO_EXIT_BAD"
    sed "s/@PLATFORM_MODULES@/$_m2_drivers/" "$M2_BOOT_DIR/early-hardware.sh" \
        > "$_m2_hooks/pre-trigger/15-ordo-m2.sh" || return "$ORDO_EXIT_BAD"
    sed "s/@ROOT_ID@/$M2_ROOT_ID/g; s/ rpool/ $POOL/g" "$M2_BOOT_DIR/wait-usb.sh" \
        > "$_m2_hooks/pre-mount/20-ordo-usb.sh" || return "$ORDO_EXIT_BAD"
    chmod +x "$_m2_hooks/"*/*.sh || return "$ORDO_EXIT_BAD"
    if [ ! -s /etc/hostid ] || [ ! -d /lib/firmware/vendorfw ]; then
        ordo_bad "缺少 /etc/hostid 或 Apple 固件"
        return "$ORDO_EXIT_BAD"
    fi
    _m2_initrd=$(mktemp /boot/.ordo-initrd.XXXXXX) || return "$ORDO_EXIT_BAD"
    if dracut --force --zstd --no-early-microcode --no-hostonly --no-hostonly-cmdline --add zfs --add-drivers "zfs $_m2_drivers $_m2_extra_drivers" \
        --include "$_m2_hooks" /usr/lib/dracut/hooks \
        --include "$_m2_firmware" /usr/lib/firmware \
        --include /lib/firmware/vendorfw /usr/lib/firmware/vendorfw \
        --install /etc/hostid --kver "$M2_RELEASE" "$_m2_initrd" &&
       m2_boot_check_initrd "$_m2_initrd" "$1" forward && mv -f "$_m2_initrd" "$M2_INITRD"; then
        return 0
    fi
    rm -f "$_m2_initrd"
    return "$ORDO_EXIT_BAD"
}

m2_boot_mount_be() {
    mount -t zfs -o ro,nosuid,nodev,noexec "$1" "$M2_BOOT_WORK/be" || return "$ORDO_EXIT_BAD"
    M2_BOOT_BE_MOUNTED=1
}

m2_boot_unmount_be() {
    umount "$M2_BOOT_WORK/be" || return "$ORDO_EXIT_BAD"
    M2_BOOT_BE_MOUNTED=0
}

m2_boot_publish() {
    mount -o remount,rw "$M2_BOOT_WORK/esp" || return "$ORDO_EXIT_BAD"
    PYTHONDONTWRITEBYTECODE=1 python3 "$M2_BOOT_DIR/boot-sync.py" "$M2_BOOT_WORK/esp" \
        --publish "$M2_KERNEL" "$M2_INITRD" "$@"
}

m2_boot_check_native_install() {
    M2_BOOT_WORK=$1
    M2_BOOT_ROOT=
    M2_NATIVE=1
    M2_RELEASE=$2
    M2_ROOT_ID=$3
    m2_boot_check_initrd "/boot/initramfs-$M2_RELEASE.img" "$4"
}
