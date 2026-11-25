#!/bin/sh
# Dracut can reach the root mount hook while xHCI is still enumerating the SSD.
part=/dev/disk/by-partuuid/@ROOT_ID@
delay=0
while [ "$delay" -lt 60 ]; do
    delay=$((delay + 1))
    [ ! -b "$part" ] || break
    # Accept the same GPT partition when the kernel sees it but udev has
    # not created its symlink. Never substitute a disk by size or name.
    for candidate in /dev/sd*[0-9]; do
        [ -b "$candidate" ] || continue
        if [ "$(blkid -p -s PART_ENTRY_UUID -o value "$candidate")" = "@ROOT_ID@" ]; then
            part=$candidate
            break 2
        fi
    done
    sleep 1
done
if [ -b "$part" ]; then
    zpool list -H rpool >/dev/null 2>&1 || zpool import -N -d "$part" rpool
else
    echo "Ordo system partition did not appear: $part" >&2
fi
