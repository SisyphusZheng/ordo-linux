#!/bin/sh
# Build the AGX-capable candidate without installing it into the running system.
set -eu
here=$(dirname "$(readlink -f "$0")")
repo=$(cd "$here/../../.." && pwd)
source_dir=$(readlink -f "${1:?pass the clean Asahi source directory}")
base_config=$(readlink -f "${2:?pass the working M2 kernel config}")
output_dir=$(readlink -f "${3:?pass an empty build directory}")
jobs=${4:?pass a compile job limit}

sh "$repo/config/check-build" arc
sh "$repo/config/check-build" jobs "-j$jobs"
test -f "$source_dir/Makefile"
test -s "$base_config"
test -d "$output_dir"
test -z "$(ls -A "$output_dir")"
test ! -e "$source_dir/.config"
test "$(uname -m)" = aarch64
available=$(df -Pk "$output_dir" | awk 'NR == 2 { print $4 }')
test "$available" -ge 4194304

# Preserve the BCF0 handling from the current working M2 boot before building a
# complete matching set of in-tree modules for the new kernel release.
python3 "$here/../power/test_driver.py" "$source_dir/drivers/power/supply/macsmc-power.c"
fragment=$repo/config/platform/m2/kernel.config
"$source_dir/scripts/kconfig/merge_config.sh" -m -O "$output_dir" "$base_config" "$fragment"
make -C "$source_dir" O="$output_dir" LLVM=1 rustavailable olddefconfig
while IFS= read -r line; do
    grep -Fx -- "$line" "$output_dir/.config"
done < "$fragment"

make -C "$source_dir" O="$output_dir" LLVM=1 -j"$jobs" Image modules
release=$(cat "$output_dir/include/config/kernel.release")
case "$release" in *asahi*-ordo-agx) ;; *) exit 1 ;; esac
stage=$output_dir/stage
make -C "$source_dir" O="$output_dir" LLVM=1 INSTALL_MOD_PATH="$stage" INSTALL_MOD_STRIP=1 modules_install
for link in build source; do
    path=$stage/lib/modules/$release/$link
    if [ -L "$path" ]; then rm "$path"; fi
done
install -Dm644 "$output_dir/arch/arm64/boot/Image" "$stage/boot/vmlinuz-$release"
install -Dm644 "$output_dir/.config" "$stage/boot/config-$release"
modinfo -b "$stage" -k "$release" asahi >/dev/null
printf '%s\n' "$stage/boot/vmlinuz-$release"
