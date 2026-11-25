#!/bin/sh
# Run with the original configured, built arm64 kernel tree and its toolchain.
set -eu
here=$(dirname "$(readlink -f "$0")")
kernel=${1:?pass the built 7.0.9-asahi-2 kernel tree}
out=${2:?pass an output module path}
src=$kernel/drivers/power/supply/macsmc-power.c
echo "29f3b19ff9c9967ba5278bb73ae02a23c59681be53ecf7d6e84dd5cadec6f096  $src" | sha256sum -c -
tmp=$(mktemp -d)
trap 'rm -r "$tmp"' EXIT
cp "$src" "$tmp/macsmc-power.c"
patch -d "$tmp" -p4 < "$here/bcf0.patch"
python3 "$here/test_driver.py" "$tmp/macsmc-power.c"
echo 'obj-m := macsmc-power.o' > "$tmp/Makefile"
make -j1 -C "$kernel" M="$tmp" modules
strip --strip-debug "$tmp/macsmc-power.ko"
case "$(modinfo -F vermagic "$tmp/macsmc-power.ko")" in
    '7.0.9-asahi-2 '*) ;;
    *) exit 1 ;;
esac
cp "$tmp/macsmc-power.ko" "$out"
