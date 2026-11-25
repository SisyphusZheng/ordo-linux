#!/bin/sh
set -eu
cd "$(dirname "$(readlink -f "$0")")/../.."
sh -n config/platform/m2/boot-sync.sh
PYTHONDONTWRITEBYTECODE=1 python3 tests/m2_boot_sync.py

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/root/etc/ordo" "$scratch/root/boot" "$scratch/bin"
for release in 7.0.9-asahi-2-ordo-agx 7.2.1-asahi-1 8.0.0-gentoo; do
    printf 'kernel\n' > "$scratch/root/boot/vmlinuz-$release"
    mkdir -p "$scratch/root/lib/modules/$release"
    printf 'dep\n' > "$scratch/root/lib/modules/$release/modules.dep"
done
cat > "$scratch/bin/modinfo" <<'MOCK'
#!/bin/sh
[ "$4" = 7.0.9-asahi-2-ordo-agx ] && [ "$5" = asahi ]
MOCK
chmod +x "$scratch/bin/modinfo"
PATH="$scratch/bin:$PATH"
ORDO_ROOT="$PWD"
. config/platform/m2/boot-sync.sh
printf 'm2-native\n' > "$scratch/root/etc/ordo/platform"
m2_boot_select "$scratch/root"
[ "$M2_RELEASE" = 7.0.9-asahi-2-ordo-agx ]
printf 'm2\n' > "$scratch/root/etc/ordo/platform"
m2_boot_select "$scratch/root"
[ "$M2_RELEASE" = 7.2.1-asahi-1 ]

sed "s|/proc/device-tree/chosen/asahi,efi-system-partition|$scratch/no-dt|g; s|/etc/ordo/platform|$scratch/root/etc/ordo/platform|g" \
    scripts/lib.sh > "$scratch/lib.sh"
. "$scratch/lib.sh"
ordo_m2_boot
