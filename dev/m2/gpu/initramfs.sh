#!/bin/sh
# Assemble the portable native initramfs from an existing matched module tree.
set -eu
here=$(dirname "$(readlink -f "$0")")
ORDO_ROOT=$(cd "$here/../../.." && pwd)
# shellcheck source=config/platform/m2/boot-sync.sh
. "$ORDO_ROOT/config/platform/m2/boot-sync.sh"
stage=$(readlink -f "${1:?pass the staged native kernel and modules directory}")
release=${2:?pass the staged kernel release}
case "$release" in *asahi*-ordo-agx) ;; *) exit 1 ;; esac
module_dir=$stage/lib/modules/$release
test -s "$stage/boot/vmlinuz-$release"
test -s "$module_dir/modules.dep.bin"

M2_NATIVE=1
required=$(m2_boot_drivers)
optional=
for driver in xhci-pci uas; do
    if modinfo -b "$stage" -k "$release" -F filename "$driver" >/dev/null 2>&1; then
        optional="$optional $driver"
    fi
done
drivers=$(printf '%s\n' "$required $optional" | tr '\n' ' ')
# shellcheck disable=SC2086 # the driver inventories contain one module name per word
paths=$(m2_boot_module_paths "$stage" "$release" $drivers zfs)
early=$(tr '\n' ' ' < "$M2_BOOT_DIR/platform-modules")

tmp=$(mktemp -d "$stage/boot/.ordo-initrd.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
sed "s/@PLATFORM_MODULES@/$early/" "$M2_BOOT_DIR/early-hardware.sh" > "$tmp/early.sh"
chmod 0755 "$tmp/early.sh"
dracut --force --zstd --no-hostonly --no-hostonly-cmdline --no-early-microcode \
    --kver "$release" --kmoddir "$module_dir" --add zfs --add-drivers "$drivers" \
    --include "$tmp/early.sh" /usr/lib/dracut/hooks/pre-trigger/15-ordo-m2.sh \
    --install /etc/hostid "$tmp/initramfs.img"

# Verify actual archive paths, not just the arguments passed to dracut.
lsinitrd "$tmp/initramfs.img" | awk '/^-/ {print $NF}' > "$tmp/files"
for path in $paths modules.dep.bin modules.alias.bin; do
    if ! grep -Fxq "usr/lib/modules/$release/$path" "$tmp/files" &&
       ! grep -Fxq "lib/modules/$release/$path" "$tmp/files"; then
        printf 'Missing boot module or index in initramfs: %s\n' "$path" >&2
        exit 1
    fi
done
mv "$tmp/initramfs.img" "$stage/boot/initramfs-$release.img"
