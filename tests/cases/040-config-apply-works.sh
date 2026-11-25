#!/bin/sh
# Test the world projection and selected set without writing the host's Portage files.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/conf" "$tmp/compare"
export TMPDIR="$tmp/compare"
cp "$ROOT/config/world.sh" "$tmp/conf/"
printf '%s\n' sys-apps/baseline > "$tmp/conf/world"
printf '%s\n' sys-firmware/fixture > "$tmp/conf/world.bare-metal"

# Load the production functions and give them an isolated Portage state.
sed -n '/^_declared_world()/,/^# ---------- show ----------/p; /^_apply_world()/,/^}/p' \
    "$ROOT/scripts/ordo-config" > "$tmp/functions.sh"
. "$tmp/functions.sh"
sed 's|/etc/ordo/platform|'"$tmp"'/platform|g' "$tmp/conf/world.sh" > "$tmp/platform-functions"
mv "$tmp/platform-functions" "$tmp/conf/world.sh"
printf '%s\n' bare-metal > "$tmp/platform"
CONF_DIR="$tmp/conf"
_ordo_set="$tmp/sets/ordo-core"
_portage_world="$tmp/world"
_portage_sets="$tmp/world_sets"
ok() { :; }
info() { :; }
bad() { printf '%s\n' "$*" >&2; }

case_name "应用与验收使用同一平台声明"
_apply_world
assert_rc "$?" 0 "apply 写出 Portage set"
assert_contains "$(cat "$_ordo_set")" sys-firmware/fixture "真机 set 含裸机包"
printf '%s\n' sys-apps/baseline > "$_portage_world"
_compare_world
assert_rc "$?" 0 "可对比未选择 set 的旧系统"
assert_eq "$(cat "$_world_tmp/missing")" sys-firmware/fixture "未选中的 set 不掩盖缺包"
mv "$_world_tmp" "$tmp/comparison-before-selection"
printf '%s\n' '@ordo-core' > "$_portage_sets"
_compare_world
assert_rc "$?" 0 "可对比选中的 set"
assert_eq "$(cat "$_world_tmp/missing")" "" "有效 world 包含选中的真机包"
assert_eq "$(cat "$_world_tmp/extra")" "" "直接 world 与套装共同出现不会误报"
mv "$_world_tmp" "$tmp/comparison-after-selection"
printf '%s\n' sys-apps/undeclared >> "$_portage_world"
_compare_world
assert_rc "$?" 0 "可对比已有漂移的选择"
assert_eq "$(cat "$_world_tmp/extra")" sys-apps/undeclared "明确列出漂移"
mv "$_world_tmp" "$tmp/comparison-with-drift"

printf '%s\n' '@other' >> "$_portage_sets"
_compare_world 2>/dev/null
assert_rc "$?" 2 "其他选中 set 无法按 Ordo 声明核对时返回 2"

case_name "M2 的引导内核和可选原生硬件包集"
mkdir -p "$tmp/conf/platform/m2"
cp "$ROOT/config/platform/m2/world.base" "$tmp/conf/platform/m2/"
printf '%s\n' '=media-libs/example-1::asahi' > "$tmp/conf/platform/m2/world"
printf '%s\n' sys-apps/baseline sys-kernel/asahi-sources > "$_portage_world"
: > "$_portage_sets"
printf 'm2\n' > "$tmp/platform"
_compare_world
assert_rc "$?" 0 "可检查现有 M2 安装"
assert_eq "$(cat "$_world_tmp/missing" "$_world_tmp/extra")" "" "基础 M2 声明包含已安装的 Asahi 内核"
printf 'm2-native\n' > "$tmp/platform"
_compare_world
assert_contains "$(cat "$_world_tmp/missing")" '=media-libs/example-1' "未选中的原生包不能通过核验"
cp "$tmp/conf/platform/m2/world" "${_ordo_set%/*}/ordo-m2"
printf '@ordo-m2\n' > "$_portage_sets"
_compare_world
assert_rc "$?" 0 "识别原生 M2 套装"
assert_eq "$(cat "$_world_tmp/missing" "$_world_tmp/extra")" "" "原生 M2 已选包与声明一致"
rm "${_ordo_set%/*}/ordo-m2"
_compare_world 2>/dev/null
assert_rc "$?" 2 "已选套装不可读时返回无法判定"

case_name "未知模块仍返回明确错误"
out=$(sh "$ROOT/scripts/ordo-config" apply kde 2>&1)
assert_rc "$?" 1 "未知模块返回 1"
assert_contains "$out" "未知模块" "明确报未知模块"
assert_contains "$out" "world" "提示可用的模块名"

finish
