#!/bin/sh
# 回归：ordo-wifi 必须建系统级 Wi-Fi 配置（psk-flags=0、permissions 为空）
#
# 实机故障：Noctalia 网络面板把新连接建成 agent-owned，而 Ordo 按既定偏离
# 没有 Secret Service —— PSK 从未落进 /etc/NetworkManager/system-connections，
# 掉线后取不回密码，表现为「输对密码、连上约 1 秒又断开」循环重试。
# 判据：helper 调 nmcli 时显式给 wifi-sec.psk-flags 0 且 connection.permissions
# 传空值；把参数改回默认（psk-flags 1 / 去掉 permissions）必须变红。
set -eu
repo=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)
. "$repo/tests/lib/assert.sh"
scratch=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/keys" "$scratch/nonroot-bin" "$scratch/idbin"

# nmcli 桩：
#   - 记录每次调用的完整参数（空参数保留为 ||，便于断言空值）；
#   - `connection add/modify` 按实际薪资生成最小 keyfile，属性缺失时写
#     `*-present=0`，让「忘了传」与「传了空值」可区分；
#   - up/delete 成功。
cat > "$scratch/bin/nmcli" <<'STUB'
#!/bin/sh
printf 'CALL' >> "${NM_LOG:?}"
for _a in "$@"; do printf '|%s' "$_a" >> "$NM_LOG"; done
printf '\n' >> "$NM_LOG"

if [ "${1:-}" = -g ] && [ "${2:-}" = NAME ]; then
    [ "${NM_EXISTING:-0}" = 1 ] && printf '%s\n' "${NM_EXISTING_NAME:-}"
    exit 0
fi
[ "${1:-}" = connection ] || exit 1
action=${2:-}
case "$action" in
    up|delete) exit 0 ;;
    add)    name=; [ "$#" -ge 2 ] && shift 2 || exit 1 ;;
    modify) name=${3:-}; [ "$#" -ge 3 ] && shift 3 || exit 1 ;;
    *) exit 1 ;;
esac

flags=""
perm_seen=0
perm=""
psk_set=0
while [ "$#" -gt 0 ]; do
    _key=$1
    if [ "$#" -ge 2 ]; then _val=$2; shift 2; else _val=""; shift; fi
    case "$_key" in
        con-name) name=$_val ;;
        wifi-sec.psk-flags) flags=$_val ;;
        connection.permissions) perm_seen=1; perm=$_val ;;
        wifi-sec.psk) psk_set=1 ;;
    esac
done
[ -n "$name" ] || exit 1
mkdir -p "${NM_KEY_DIR:?}"
f="${NM_KEY_DIR}/$name.nmconnection"
# 系统级属性只在 add（或显式 modify 了它们）时落盘；随后写密码的
# modify 调用不能把已有属性抹掉（NM 是合并语义，不是覆盖）。
if [ "$action" = add ] || [ "$perm_seen" -eq 1 ] || [ -n "$flags" ]; then
    {
        printf '[connection]\n'
        if [ "$perm_seen" -eq 1 ]; then
            printf 'permissions=%s\n' "$perm"
        else
            printf 'permissions-present=0\n'
        fi
        printf '[wifi-security]\n'
        if [ -n "$flags" ]; then
            printf 'psk-flags=%s\n' "$flags"
        else
            printf 'psk-flags-present=0\n'
        fi
    } > "$f"
fi
[ "$psk_set" -eq 0 ] || printf 'psk-set=1\n' >> "$f"
exit 0
STUB
chmod +x "$scratch/bin/nmcli"

printf '#!/bin/sh\nprintf "0\\n"\n' > "$scratch/idbin/id"
chmod +x "$scratch/idbin/id"
# 正常路径也需要假的 root：开发机以普通用户跑用例。
cp "$scratch/idbin/id" "$scratch/bin/id"
ln -s "$scratch/bin/nmcli" "$scratch/nonroot-bin/nmcli"

_run() { # args...
    NM_LOG="$scratch/log" NM_KEY_DIR="$scratch/keys" \
        PATH="$scratch/bin:$PATH" ORDO_WIFI_PSK='correct horse' \
        sh "$repo/scripts/ordo-wifi" "$@"
}

case_name "新建设置：keyfile 里 psk-flags=0、permissions 为空"

: > "$scratch/log"
_rc=0
_run "Ordo Test" >/dev/null 2>&1 || _rc=$?
assert_rc "$_rc" 0 "创建成功"
_key="$scratch/keys/Ordo Test.nmconnection"
assert_rc "$([ -f "$_key" ] && echo 0 || echo 1)" 0 "nmcli 收到 connection add"
assert_contains "$(cat "$_key")" "psk-flags=0" "PSK 存系统 keyfile（0=system）"
assert_not_contains "$(cat "$_key")" "psk-flags-present=0" "没有漏传 psk-flags"
assert_eq "$(grep -c '^permissions=$' "$_key" || :)" 1 "permissions 传了空值（所有用户可用）"
assert_not_contains "$(cat "$_key")" "permissions-present=0" "没有漏传 permissions"
assert_contains "$(cat "$scratch/log")" "|wifi-sec.psk-flags|0|" "命令行显式 psk-flags 0"
assert_contains "$(cat "$scratch/log")" "|connection.permissions||" "命令行显式 permissions 空值"
assert_contains "$(cat "$_key")" "psk-set=1" "密码写入系统配置"

case_name "已存在同名 profile：改属性而不是重复 add"

rm -rf "$scratch/keys"
: > "$scratch/log"
_rc=0
NM_EXISTING=1 NM_EXISTING_NAME="Ordo Test" _run "Ordo Test" >/dev/null 2>&1 || _rc=$?
assert_rc "$_rc" 0 "重跑成功"
assert_not_contains "$(cat "$scratch/log")" "|connection|add|" "已存在时不 add"
assert_contains "$(cat "$scratch/log")" \
    "|connection|modify|Ordo Test|wifi-sec.key-mgmt|wpa-psk|wifi-sec.psk-flags|0|connection.permissions||" \
    "改属性时同样落系统级 flags"
assert_contains "$(cat "$scratch/keys/Ordo Test.nmconnection")" "psk-flags=0" "改完仍是系统级"

case_name "非 root：拒绝执行并说明用 doas"

_rc=0
_out=$(ORDO_WIFI_PSK=x NM_LOG="$scratch/log" NM_KEY_DIR="$scratch/keys" \
    PATH="$scratch/nonroot-bin:/usr/bin:/bin" \
    sh "$repo/scripts/ordo-wifi" "Ordo Test" 2>&1) || _rc=$?
assert_rc "$_rc" 1 "非 root 退出 1"
assert_contains "$_out" "需要 root" "点名需要 root"
assert_contains "$_out" "doas ordo-wifi" "给出正确的调用方式"

case_name "缺 nmcli：exit 2（无法判定），不是成功"

_rc=0
_out=$(ORDO_WIFI_PSK=x NM_LOG="$scratch/log" NM_KEY_DIR="$scratch/keys" \
    PATH="$scratch/idbin:/usr/bin:/bin" \
    sh "$repo/scripts/ordo-wifi" "Ordo Test" 2>&1) || _rc=$?
assert_rc "$_rc" 2 "缺 nmcli 退出 2"
assert_contains "$_out" "无法判定" "明确标注无法判定"


case_name "ordo-wifi 必须真的装进 PATH（否则文档第一条命令就是 command not found）"
assert_contains "$(cat "$repo/install.sh")" "ordo-selfcheck ordo-wifi" "install.sh 软链白名单含 ordo-wifi"
assert_contains "$(cat "$repo/config/platform/m2/install-cli.sh")" "ordo-wifi" "M2 CLI 刷新清单含 ordo-wifi"
assert_contains "$(cat "$repo/dev/m2/build.py")" "scripts/ordo-wifi" "M2 bundle 含 ordo-wifi"

finish
