#!/bin/sh
# 回归：P1-01 install.sh 缺 EFI 默认引导兜底
#
# 旧状态：只 efibootmgr 注册 BootXXXX，失败仅 warn；ESP 上没有
# \EFI\BOOT\BOOT{AA64,X64}.EFI。NVRAM 写不进去的机器因此直接无引导。
# 外置安装（install-external.sh）有这份兜底，install.sh 路径没有。
#
# 用例执行安装器里的真实块（不是复制一份规则）：按架构挑文件名、复制先于
# efibootmgr、注册失败但兜底文件在 → warn 继续、没有兜底文件 → die。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ordo-efi.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

case_name "安装器里有独立的 EFI 默认引导块"
block="$(sed -n '/^# ---- EFI 默认引导兜底（P1-01）----/,/^# ---- 6) 主机名/p' "$ROOT/install.sh" | sed '$d')"
assert_rc "$([ -n "$block" ] && echo 0 || echo 1)" 0 "能抽出兜底块"
assert_contains "$block" 'BOOTAA64.EFI' "arm64 默认引导名"
assert_contains "$block" 'BOOTX64.EFI' "amd64 默认引导名"
assert_contains "$block" 'cmp -s' "复制后读回核对"
_ln_copy=$(printf '%s\n' "$block" | grep -n 'install -m 0644' | head -1 | cut -d: -f1)
_ln_reg=$(printf '%s\n' "$block" | grep -n 'efibootmgr --create' | head -1 | cut -d: -f1)
assert_rc "$([ -n "$_ln_copy" ] && [ -n "$_ln_reg" ] && [ "$_ln_copy" -lt "$_ln_reg" ] && echo 0 || echo 1)" 0 \
    "默认引导复制发生在 efibootmgr 之前"
assert_contains "$block" '[ -s "$_efi_default" ]' "efibootmgr 失败分支检查兜底文件"
assert_contains "$block" 'die "EFI 启动项注册失败，且没有固件默认引导兜底' "兜底文件缺失即 die"

mkdir -p "$tmp/bin"
cat > "$tmp/bin/efibootmgr" <<'STUB'
#!/bin/sh
printf 'efibootmgr %s\n' "$*" >> "$LOG"
if [ -e "$ORDO_EFI_ROOT/EFI/BOOT/BOOTAA64.EFI" ] || [ -e "$ORDO_EFI_ROOT/EFI/BOOT/BOOTX64.EFI" ]; then
    printf 'default-present\n' >> "$LOG"
else
    printf 'default-missing\n' >> "$LOG"
fi
exit "${EFIBOOTMGR_RC:-0}"
STUB
chmod 755 "$tmp/bin/efibootmgr"

run_block() { # arch efibootmgr-rc [skip-fixture]
    _arch=$1
    _rc=$2
    _skip=${3:-0}
    _efi="$tmp/efi-$_arch"
    rm -rf "$_efi" "$tmp/run.sh" "$tmp/log" "$tmp/out" "$tmp/err"
    mkdir -p "$_efi/EFI/ZBM"
    [ "$_skip" = 1 ] || printf 'zbm-efi-bytes' > "$_efi/EFI/ZBM/vmlinuz.EFI"
    {
        printf '%s\n' 'set -eu'
        printf '%s\n' 'say() { printf "say %s\n" "$*"; }'
        printf '%s\n' 'warn() { printf "warn %s\n" "$*" >&2; }'
        printf '%s\n' 'die() { printf "die %s\n" "$*" >&2; exit 1; }'
        printf '%s\n' "$block"
    } > "$tmp/run.sh"
    PATH="$tmp/bin:$PATH" ARCH="$_arch" DISK=/dev/fake \
        ORDO_EFI_ROOT="$_efi" LOG="$tmp/log" EFIBOOTMGR_RC="$_rc" \
        sh "$tmp/run.sh" > "$tmp/out" 2> "$tmp/err"
}

case_name "arm64：复制到 BOOTAA64.EFI，且注册时已就位"
run_block arm64 0; rc=$?
assert_eq "$rc" 0 "块执行成功"
assert_eq "$(cat "$tmp/efi-arm64/EFI/BOOT/BOOTAA64.EFI" 2>/dev/null)" "zbm-efi-bytes" \
    "默认引导内容等于 vmlinuz.EFI"
assert_contains "$(cat "$tmp/log" 2>/dev/null)" 'default-present' \
    "efibootmgr 被调用时兜底文件已存在（复制在前）"

case_name "amd64：选 BOOTX64.EFI，不写 AA64"
run_block amd64 0; rc=$?
assert_eq "$rc" 0 "块执行成功"
assert_eq "$(cat "$tmp/efi-amd64/EFI/BOOT/BOOTX64.EFI" 2>/dev/null)" "zbm-efi-bytes" \
    "amd64 的默认引导名是 BOOTX64.EFI"
assert_rc "$([ -e "$tmp/efi-amd64/EFI/BOOT/BOOTAA64.EFI" ] && echo 1 || echo 0)" 0 \
    "amd64 不产生 arm64 文件名"

case_name "efibootmgr 失败但有兜底：warn 继续，不中止安装"
run_block arm64 1; rc=$?
assert_eq "$rc" 0 "不中止"
assert_contains "$(cat "$tmp/err" 2>/dev/null)" 'warn EFI 启动项注册失败' "降级为 warn"
assert_rc "$([ -s "$tmp/efi-arm64/EFI/BOOT/BOOTAA64.EFI" ] && echo 0 || echo 1)" 0 \
    "兜底文件仍在"

case_name "generate-zbm 没产出：没有可兜底文件即 die"
run_block arm64 0 1; rc=$?
assert_eq "$rc" 1 "中止安装"
assert_contains "$(cat "$tmp/err" 2>/dev/null)" 'generate-zbm 未产出' "错误指向缺失的 ZBM 产物"
assert_rc "$([ -e "$tmp/efi-arm64/EFI/BOOT/BOOTAA64.EFI" ] && echo 1 || echo 0)" 0 \
    "缺产物时不写默认引导"

case_name "未知架构：无法选择默认引导名即 die"
run_block riscv 0; rc=$?
assert_eq "$rc" 1 "中止安装"
assert_contains "$(cat "$tmp/err" 2>/dev/null)" '未知架构' "报架构错误"

finish
