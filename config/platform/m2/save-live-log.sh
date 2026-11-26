#!/bin/sh
# Installed only when the media builder has been given a diagnostic PARTUUID.
set -eu
phase=${1:-shutdown}
case "$phase" in start|result|shutdown) ;; *) exit 1 ;; esac
mnt=/mnt/payload
dev=$(findmnt -n -o SOURCE --mountpoint "$mnt")
case "$dev" in /dev/nvme*n*p[0-9]*) ;; *) exit 1 ;; esac
[ "$(blkid -s PARTUUID -o value "$dev")" = "@LOG_ID@" ]
[ "$(blkid -s LABEL -o value "$dev")" = ORDOINNER ]
[ "$(findmnt -n -o FSTYPE --mountpoint "$mnt")" = vfat ]
case ",$(findmnt -n -o OPTIONS --mountpoint "$mnt")," in *,ro,*) ;; *) exit 1 ;; esac
# Collect in RAM first, keeping the writable interval short.
report=$(mktemp)
trap 'rm -f "$report"' EXIT
{
    echo "Ordo M2 USB diagnostic v1 / $phase"
    cat /proc/sys/kernel/random/boot_id /proc/uptime /proc/cmdline || :
    cat /tmp/ordo-preflight.log 2>/dev/null || :
    lsblk -o NAME,SIZE,TRAN,FSTYPE,LABEL,PARTUUID || :
    lsusb -t || :
    for role in /sys/class/typec/port*/data_role /sys/class/usb_role/*/role; do
        if [ -r "$role" ]; then printf '%s: %s\n' "$role" "$(cat "$role")"; fi
    done
    if [ -r /sys/kernel/debug/devices_deferred ]; then cat /sys/kernel/debug/devices_deferred; fi
    lsmod || :
    dmesg | tail -1500
    if [ -r /var/log/messages ]; then tail -200 /var/log/messages; fi
} >"$report" 2>&1
mount -o remount,rw "$dev" "$mnt"
trap 'mount -o remount,ro "$dev" "$mnt"; rm -f "$report"' EXIT
pending=$(mktemp "$mnt/.ordo-log.XXXXXX")
if cp "$report" "$pending" && mv -f "$pending" "$mnt/ordo-live-$phase.log"; then
    sync
else
    rm -f "$pending"
    exit 1
fi
mount -o remount,ro "$dev" "$mnt"
trap 'rm -f "$report"' EXIT
