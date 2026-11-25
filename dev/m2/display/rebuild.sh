#!/bin/sh
# Rebuild the J413 display dependency chain and kmod indices on Linux.
set -eu
kernel=${1:?configured and built Asahi kernel tree}
base=${2:?original modules.tar.gz}
out=${3:?output tar.gz}
release=7.0.9-asahi-2
echo "9d960d8ff6bea64367604ee4d0253ecd01d96a902585a92ff59d291ba775a43d  $kernel/arch/arm64/boot/Image" | sha256sum -c -
echo "f8b37705d1693064a3bb05fbbbc4a0cc4ad0df97ce93b18ab21de84968d21deb  $base" | sha256sum -c -
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tree="$work/lib/modules/$release"
mkdir -p "$work/lib/modules"
tar -xzf "$base" -C "$work/lib/modules"
"$kernel/scripts/extract-ikconfig" "$kernel/arch/arm64/boot/Image" > "$work/kernel.config"
cmp "$kernel/.config" "$work/kernel.config"
cp "$kernel/modules.builtin" "$kernel/modules.builtin.modinfo" "$tree/"
grep -Fvx -f "$tree/modules.builtin" "$tree/modules.order" > "$work/order"
mv "$work/order" "$tree/modules.order"
while IFS= read -r builtin; do
    rm -f "$tree/$builtin"
done < "$tree/modules.builtin"
depmod -b "$work" "$release"
modprobe -d "$work" -S "$release" --show-depends appledrm > "$work/deps"
awk -v prefix="$tree/" '$1 == "insmod" && index($2, prefix) == 1 {print substr($2,length(prefix)+1)}' "$work/deps" > "$work/files"
grep -Fxq 'kernel/drivers/gpu/drm/apple/appledrm.ko' "$work/files"
sed 's|^kernel/||' "$work/files" > "$work/targets"
xargs make -C "$kernel" -j1 < "$work/targets"
while IFS= read -r file; do
    cp "$kernel/${file#kernel/}" "$tree/$file"
done < "$work/files"
depmod -b "$work" "$release"
(cd "$tree" && printf '%s\n' modules.*) >> "$work/files"
LC_ALL=C sort -u -o "$work/files" "$work/files"
tar --owner=0 --group=0 --numeric-owner --mtime=@0 -C "$tree" -cf "$work/result.tar" -T "$work/files"
gzip -nc "$work/result.tar" > "$out"
