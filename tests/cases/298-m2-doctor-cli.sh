#!/bin/sh
# The public directory used to contain independent, outdated M2 CLI wrappers.
set -eu
repo=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)
. "$repo/tests/lib/assert.sh"
scratch=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
ordo=$scratch/opt/ordo
bin=$scratch/bin
state=$scratch/etc/ordo
mkdir -p "$bin" "$ordo/scripts" "$ordo/config/desktop" "$ordo/config/platform/m2" "$state/desktop" "$scratch/sets"
cp "$repo/scripts/ordo" "$ordo/scripts"
cp "$repo/config/platform/m2/world.base" "$ordo/config/platform/m2/"
cp "$repo/version" "$ordo"
printf '%s\n' sys-apps/baseline > "$ordo/config/world"
printf '%s\n' '=media-libs/example-1::asahi' > "$ordo/config/platform/m2/world"
printf '%s\n' sys-apps/baseline sys-kernel/asahi-sources > "$scratch/world"
sed "s|/etc/ordo/platform|$state/platform|g; s|/proc/device-tree/compatible|$scratch/no-dt|g" \
    "$repo/config/world.sh" > "$ordo/config/world.sh"
sed "s|/proc/device-tree/chosen/asahi,efi-system-partition|$scratch/no-dt|g; s|/etc/ordo|$state|g" \
    "$repo/scripts/lib.sh" > "$ordo/scripts/lib.sh"
sed "s|/var/lib/portage/world|$scratch/world|g" "$repo/scripts/doctor" > "$ordo/scripts/doctor"

# Use the production world comparison with an isolated Portage database.
cat > "$ordo/scripts/ordo-config" <<EOF
#!/bin/sh
set -eu
. "$ordo/scripts/lib.sh"
test "\${1:-}" = verify
test "\$CONF_DIR" = "$ordo/config"
_portage_world="$scratch/world"
_portage_sets="$scratch/world_sets"
_ordo_set="$scratch/sets/ordo-core"
EOF
sed -n '/^_declared_world()/,/^# ---------- show ----------/p' "$repo/scripts/ordo-config" >> "$ordo/scripts/ordo-config"
cat >> "$ordo/scripts/ordo-config" <<'WORLD'
_compare_world
test ! -s "$_world_tmp/extra" && test ! -s "$_world_tmp/missing" || {
    echo '✘ world fixture drift'
    exit 1
}
WORLD

for name in ordo-backup ordo-migrate ordo-snap ordo-snap-auto ordo-selfcheck ordo-wifi sysup; do
    printf '#!/bin/sh\nexit 0\n' > "$ordo/scripts/$name"
done
chmod +x "$ordo/scripts/"*
for stale in ordo ordo-config ordo-doctor sysup; do
    printf '#!/bin/sh\necho stale CLI\nexit 1\n' > "$bin/$stale"
done
chmod +x "$bin/"*
sed "s|/opt/ordo|$ordo|g; s|/usr/local/bin|$bin|g" "$repo/config/platform/m2/install-cli.sh" > "$scratch/install-cli"
sh "$scratch/install-cli"
sh "$scratch/install-cli"

export PATH="$bin:$PATH"
for selected in m2 m2-native; do
    case_name "$selected 的公开入口与 world 核验"
    printf '%s\n' "$selected" > "$state/platform"
    if [ "$selected" = m2-native ]; then
        printf '%s\n' @ordo-m2 > "$scratch/world_sets"
        cp "$ordo/config/platform/m2/world" "$scratch/sets/ordo-m2"
    fi
    assert_eq "$(readlink "$bin/ordo")" "$ordo/scripts/ordo" "刷新 ordo"
    assert_eq "$(readlink "$bin/ordo-config")" "$ordo/scripts/ordo-config" "刷新 ordo-config"
    assert_eq "$(readlink "$bin/ordo-doctor")" "$ordo/scripts/doctor" "刷新 ordo-doctor"
    assert_eq "$(readlink "$bin/sysup")" "$ordo/scripts/sysup" "刷新 sysup"
    ordo config verify
    out=$(ordo doctor 2>&1) || :
    assert_contains "$out" "配置一致" "doctor 使用随附的新版 world 核验"
    assert_not_contains "$out" "world 漂移" "旧的重复 world 检查不误报 Asahi 包"
    out=$(ordo-doctor 2>&1) || :
    assert_contains "$out" "配置一致" "独立 doctor 别名走现场同一版本"
done
finish
