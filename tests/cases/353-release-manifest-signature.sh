#!/bin/sh
# 回归：发布摘要必须能用仓库内的信任锚离线验证
#
# P1-02：M2-SHA256SUMS 已入库，但手册只教 shasum，没有验签步骤；
# 包内 allowed_signers 自证不构成来源信任。这里把「签名可验证」变成门禁。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

SUM="$ROOT/config/release/0.1.0/M2-SHA256SUMS"
SIG="$SUM.sig"
SIGNERS="$ROOT/config/release/allowed_signers"

case_name "发布摘要与签名随仓库分发"

assert_rc "$([ -f "$SUM" ] && echo 0 || echo 1)" 0 "M2-SHA256SUMS 存在"
assert_rc "$([ -f "$SIG" ] && echo 0 || echo 1)" 0 "M2-SHA256SUMS.sig 存在"
assert_rc "$([ -f "$SIGNERS" ] && echo 0 || echo 1)" 0 "allowed_signers 存在"
assert_contains "$(cat "$SUM")" "Ordo-Linux-0.1.0-M2-Air-macOS.tar.gz" "清单列出 M2 安装包"

if ! command -v ssh-keygen >/dev/null 2>&1; then
    printf '\n? 缺少 ssh-keygen，无法验证签名（退出码 2=无法判定）\n'
    exit 2
fi

case_name "仓库信任锚能验证发布摘要签名"

out="$(ssh-keygen -Y verify -f "$SIGNERS" -I ordo-preview -n ordo-release \
    -s "$SIG" < "$SUM" 2>&1)"; rc=$?
assert_rc "$rc" 0 "ssh-keygen -Y verify 通过"
assert_contains "$out" "Good \"ordo-release\" signature" "签名命名空间为 ordo-release"

finish
