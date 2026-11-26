#!/bin/sh
# 回归：config/release 下每个发布锚点都必须有消费方
#
# 曾经：config/release/stage3-arm64-desktop-openrc.sha256.asc 是一份离线
# 签名摘要副本，没有任何脚本读取；它的固定 tarball 名还与 config/arch
# 的 STAGE3_TARBALL 不一致，等于第二个互相矛盾的 stage3 信任锚。
# 删除后，这条用例守住「不再出现无人消费的锚点」。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

case_name "config/release 的锚点都有消费方"

orphans=""
for f in $(find "$ROOT/config/release" -type f | sort); do
    rel=${f#"$ROOT/"}
    base=${f##*/}
    hits="$(cd "$ROOT" && git grep -lF -- "$base" -- . 2>/dev/null | grep -v '^config/release/' | head -1)"
    [ -n "$hits" ] || orphans="$orphans $rel"
done
assert_eq "$orphans" "" "没有无人消费的发布锚点"

case_name "stage3 信任锚来自在线验签路径"

assert_contains "$(cat "$ROOT/install.sh")" "config/verify-stage3" \
    "install.sh 调用 verify-stage3"
assert_rc "$([ -f "$ROOT/config/verify-stage3" ] && echo 0 || echo 1)" 0 \
    "verify-stage3 随仓库分发"

finish
