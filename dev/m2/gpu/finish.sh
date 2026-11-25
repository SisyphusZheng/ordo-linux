#!/bin/sh
# Add matched OpenZFS and a device-independent initramfs to the candidate.
set -eu
here=$(dirname "$(readlink -f "$0")")
repo=$(cd "$here/../../.." && pwd)
source_dir=$(readlink -f "${1:?pass the Asahi source directory}")
build_dir=$(readlink -f "${2:?pass the completed kernel build directory}")
zfs_archive=$(readlink -f "${3:?pass the OpenZFS 2.4.4 release tarball}")
jobs=${4:?pass a compile job limit}

sh "$repo/config/check-build" arc
sh "$repo/config/check-build" jobs "-j$jobs"
release=$(cat "$build_dir/include/config/kernel.release")
case "$release" in *asahi*-ordo-agx) ;; *) exit 1 ;; esac
stage=$build_dir/stage
module_dir=$stage/lib/modules/$release
test -s "$stage/boot/vmlinuz-$release"
test -s "$build_dir/Module.symvers"
test -d "$module_dir"
printf '%s  %s\n' 2a3c70d55a37cc71618a95a60e81ad66530201eb118d37741dc92efcf848c8b1 "$zfs_archive" | sha256sum -c -
for link in build source; do
    if [ -L "$module_dir/$link" ]; then rm "$module_dir/$link"; fi
done

tmp=$(mktemp -d "$build_dir/ordo-zfs.XXXXXX")
tar -xf "$zfs_archive" -C "$tmp"
cd "$tmp/zfs-2.4.4"
# Apply the same release label as the Gentoo zfs ebuild used on the target.
version=$(zfs version | sed -n '1s/^zfs-//p')
case "$version" in 2.4.4-r[0-9]*-gentoo) ;; *) exit 1 ;; esac
revision=${version#2.4.4-}
sed "s/^Release:.*/Release:       $revision/" META > META.new
mv META.new META
kernel_ld=${KERNEL_LD:-$(command -v ld.lld || command -v ld)}
TEST_JOBS="$jobs" CC=clang KERNEL_CC=clang KERNEL_LLVM=1 KERNEL_LD="$kernel_ld" \
    ./configure --with-config=kernel --with-linux="$source_dir" --with-linux-obj="$build_dir"
make -j"$jobs" LLVM=1 LD="$kernel_ld"
install -d "$module_dir/extra"
find module -name '*.ko' -type f -exec install -m644 -t "$module_dir/extra" {} +
test "$(modinfo -F version "$module_dir/extra/zfs.ko")" = "$version"
depmod -b "$stage" "$release"

# Media preparation appends the machine firmware and the USB root wait hook.
sh "$here/initramfs.sh" "$stage" "$release"
rm -rf "$tmp"
