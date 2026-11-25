#!/bin/sh
# Run inside an ARM64 release build root with dracut, ZFS and ZFSBootMenu installed.
set -eu
here=$(dirname "$(readlink -f "$0")")
repo=$(cd "$here/../.." && pwd)
stage=$(realpath "${1:?native stage directory}")
out=$(realpath "${2:?existing output directory}")
set -- "$stage"/boot/vmlinuz-*
[ "$#" -eq 1 ] && [ -s "$1" ]
kernel=$1
release=${kernel##*/vmlinuz-}
case "$release" in *-asahi-*-ordo-agx) ;; *) exit 1;; esac
modules=$stage/lib/modules/$release
[ -s "$modules/modules.dep.bin" ]
drivers=$(cat "$repo/config/platform/m2/boot-drivers" "$repo/config/platform/m2/platform-modules" | tr '\n' ' ')
tmp=$(mktemp -d "$out/.boot-kit.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/conf"
tools="bash awk cat chmod cp grep mkdir modprobe mount umount mountpoint findmnt blkid losetup switch_root sed rm sleep sha256sum sync"
dracut_image() {
    dracut --force --zstd --no-hostonly --no-hostonly-cmdline --no-early-microcode \
        --conf /dev/null --confdir "$tmp/conf" --kver "$release" --kmoddir "$modules" \
        --add-drivers "$drivers overlay zfs" "$@"
}
dracut_image --modules "base bash kernel-modules rootfs-block udev-rules" \
    --install "$tools" "$tmp/live-raw.img"
dracut_image --modules "base bash kernel-modules udev-rules zfsbootmenu" "$tmp/recovery-raw.img"
python3 "$here/portable_boot.py" generic "$tmp/live-raw.img" "$tmp/live.img"
python3 "$here/portable_boot.py" generic "$tmp/recovery-raw.img" "$tmp/recovery.img"
lsinitrd "$tmp/live.img" > "$tmp/live-list"
for binary in $tools; do
    grep -Eq "[[:space:]](usr/)?s?bin/$binary([[:space:]]|$)" "$tmp/live-list" || {
        echo "Missing Live command $binary" >&2
        exit 1
    }
done
lsinitrd "$tmp/recovery.img" > "$tmp/recovery-list"
grep -q 'zfsbootmenu-ready' "$tmp/recovery-list"
python3 "$here/portable_boot.py" recovery /usr/lib/systemd/boot/efi/linuxaa64.efi.stub \
    "$kernel" "$tmp/recovery.img" "$tmp/vmlinuz-asahi.EFI"
mv "$tmp/live.img" "$out/initramfs-live.img"
mv "$tmp/vmlinuz-asahi.EFI" "$out/vmlinuz-asahi.EFI"
