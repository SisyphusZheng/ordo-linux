#!/bin/sh
# Called from dracut only when ORDOINNER diagnostics were enabled at build time.
(
    phase=$1
    dev=/dev/disk/by-partuuid/@LOG_ID@
    if [ ! -b "$dev" ]; then
        # udev may not have constructed by-partuuid yet. Probe only internal NVMe partitions.
        for node in /dev/nvme*n*p*; do
            [ -b "$node" ] || continue
            if [ "$(blkid -p -s PART_ENTRY_UUID -o value "$node")" = "@LOG_ID@" ]; then
                dev=$node
                break
            fi
        done
    fi
    case "$(readlink -f "$dev")" in /dev/nvme*n*p[0-9]*) ;; *) exit 0 ;; esac
    [ "$(blkid -s LABEL -o value "$dev")" = ORDOINNER ] || exit 0
    donefile=/run/ordo-report-$phase
    [ ! -f "$donefile" ] || exit 0
    mnt=/run/ordo-boot-report
    mkdir -p "$mnt" && mount -t vfat -o nosuid,nodev,noexec "$dev" "$mnt" || exit 0
    trap 'umount "$mnt"' EXIT
    {
        echo "Ordo M2 $phase"
        cat /proc/cmdline /proc/partitions
        ls /dev/disk/by-partuuid/
        for card in /sys/class/drm/card[0-9]*; do
            if [ -L "$card/device/driver" ]; then
                echo "$card driver $(readlink -f "$card/device/driver")"
            fi
            if [ -r "$card/status" ]; then
                echo "$card $(cat "$card/status")"
            fi
        done
        cat /proc/modules
        ls /sys/bus/usb/devices
        for role in /sys/class/typec/port*/data_role; do
            [ ! -r "$role" ] || cat "$role"
        done
        zpool status
        dmesg
    } > "$mnt/ordo-boot.tmp" 2>&1 &&
        mv -f "$mnt/ordo-boot.tmp" "$mnt/ordo-boot-$phase.log" && : > "$donefile"
)
exit 0
