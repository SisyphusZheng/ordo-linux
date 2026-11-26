#!/bin/sh
# 回归：P2-11 声明层的死键 —— arm64 微码、无效 USE、无效 keyword
#
# 审计证据：
#   - config/world.bare-metal 无条件含 sys-firmware/intel-microcode，
#     而 config/arch 默认 arm64 → arm64 真机装进 x86 微码（树上不存在）。
#   - config/package.accept_keywords/desktop 里 tuigreet / wlsunset / ashell
#     不在 world，也不在任何平台 world → keyword 是死配置（ashell 已随 ADR 0011 退场）。
#   - config/package.use/desktop 的 `noto-cjk cjk`、`util-linux rfkill`
#     在介质 Packages 的 IUSE 里不存在 → 空操作。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

# 直接跑生产声明合并函数
_world() { # platform arch
    sh -c '. "$1/config/world.sh"; ordo_world "$1/config" "$2" "$3"' sh "$ROOT" "$1" "$2"
}

case_name "arm64 真机不装 x86 微码"
arm64_list="$(_world bare-metal arm64)"
assert_rc "$?" 0 "bare-metal + arm64 可解析"
assert_not_contains "$arm64_list" "sys-firmware/intel-microcode" "arm64 声明不含 intel-microcode"
assert_contains "$arm64_list" "net-wireless/iw" "arm64 真机仍含架构中立包"

case_name "amd64 真机才装 x86 微码"
amd64_list="$(_world bare-metal amd64)"
assert_contains "$amd64_list" "sys-firmware/intel-microcode" "amd64 声明含 intel-microcode"
assert_contains "$amd64_list" "sys-firmware/linux-firmware" "分片不丢中立包"

case_name "缺省架构按 arm64 处理（不把 x86 微码塞进默认集）"
default_list="$(_world bare-metal '')"
assert_not_contains "$default_list" "sys-firmware/intel-microcode" "无 ARCH 时不引入 x86 微码"

case_name "world.bare-metal 本体仍是裸 atom（不含架构标记列）"
_bad="$(awk 'NF && $0 !~ /^[[:space:]]*#/ { if ($0 ~ /#/ || NF != 1) print NR": "$0 }' \
    "$ROOT/config/world.bare-metal")"
assert_eq "$_bad" "" "world.bare-metal 只含裸 atom"
assert_rc "$([ -f "$ROOT/config/world.bare-metal.amd64" ] && echo 0 || echo 1)" 0 \
    "amd64 分片存在"

case_name "install.sh 按 ARCH 计算包集并守住 arm64"
_install="$(cat "$ROOT/install.sh")"
assert_contains "$_install" 'ordo_world "$1/config" "$2" "$3"' "install.sh 把架构传给声明合并"
assert_contains "$_install" 'REPO_DIR" "$ORDO_PLATFORM" "$ARCH"' "实际传入的是 config/arch 的 ARCH"
assert_contains "$_install" "arm64 的 @ordo-core 含 x86 微码" "arm64 出现微码即中止"

case_name "accept_keywords 没有死配置"
_world_all=""
for _p in vm bare-metal m2 m2-native; do
    _world_all="$_world_all
$(_world "$_p" amd64)"
done
_dangling=""
while IFS= read -r _line; do
    case "$_line" in ''|\#*) continue ;; esac
    _atom="$(printf '%s' "$_line" | awk '{print $1}' | sed 's/^[=<>~]*//; s/::.*//')"
    printf '%s\n' "$_world_all" | sed 's/^[=<>~]*//; s/::.*//' | grep -qx "$_atom" \
        || _dangling="$_dangling $_atom"
done < "$ROOT/config/package.accept_keywords/desktop"
assert_eq "$_dangling" "" "每条 keyword 都对应 world 里的包"

case_name "已退场/未声明的 keyword 行已删除"
_kw="$(cat "$ROOT/config/package.accept_keywords/desktop")"
assert_not_contains "$_kw" "gui-apps/tuigreet" "tuigreet 不在 world，keyword 已删"
assert_not_contains "$_kw" "gui-apps/wlsunset" "wlsunset 不在 world，keyword 已删"
assert_not_contains "$_kw" "gui-apps/ashell" "ashell 已退场，keyword 已删"
assert_contains "$_kw" "gui-libs/greetd" "greetd 在 world，keyword 保留"

case_name "无效 USE 已删除"
_pu="$(cat "$ROOT/config/package.use/desktop")"
assert_not_contains "$_pu" "media-fonts/noto-cjk" "noto-cjk 没有 cjk USE，死行已删"
assert_not_contains "$_pu" "sys-apps/util-linux" "util-linux 没有 rfkill USE，死行已删"
_rh="$(grep -vE '^[[:space:]]*#' "$ROOT/config/package.use/real-hardware")"
assert_not_contains "$_rh" "sys-firmware/intel-microcode" \
    "real-hardware 不再无条件启用 Intel 微码 USE"

finish
