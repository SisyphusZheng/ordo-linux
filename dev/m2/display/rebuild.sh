#!/bin/sh
# Rebuild the J413 display dependency chain and kmod indices on Linux.
set -eu
here=$(dirname "$(readlink -f "$0")")
kernel=${1:?configured and built Asahi kernel tree}
base=${2:?original modules.tar.gz}
out=${3:?output tar.gz}
# 内核版本与两个摘要不在脚本里写死：payload.sha256 是唯一来源（P2-11）。
manifest=${ORDO_PAYLOAD_MANIFEST:-"$here/../../../config/platform/m2/payload.sha256"}
release=$(awk '$2 ~ /^kernel\/vmlinuz-/ && $2 !~ /\.EFI$/ { sub(/^kernel\/vmlinuz-/, "", $2); print $2 }' "$manifest")
if [ -z "$release" ] || [ "$(printf '%s\n' "$release" | wc -l | tr -d ' ')" != 1 ]; then
    printf 'payload.sha256 必须固定唯一内核：%s\n' "$manifest" >&2
    exit 1
fi
image=$(awk -v entry="kernel/vmlinuz-$release" '$2 == entry { print $1 }' "$manifest")
modules=$(awk '$2 == "kernel/modules.tar.gz" { print $1 }' "$manifest")
if [ -z "$image" ] || [ -z "$modules" ]; then
    printf 'payload.sha256 缺少镜像或模块包摘要：%s\n' "$manifest" >&2
    exit 1
fi
printf '%s  %s\n' "$image" "$kernel/arch/arm64/boot/Image" | sha256sum -c -
printf '%s  %s\n' "$modules" "$base" | sha256sum -c -
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
