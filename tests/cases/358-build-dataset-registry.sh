#!/bin/sh
# 回归：P1-02 config/dataset 未登记测试 BE / 构建残留
#
# 旧状态：镜像带着 rpool/ordo-build-010（68.6G）与 rpool/ordo-m2-build（11.6G）
# 构建残留交付，bootfs 还指向 rpool/root/ordo-m2-hardware。ordo snap identity
# 看到「运行根 != DATASET」就把测试 BE 当回滚 clone，教用户 promote/rename
# 成规范名 —— 而它根本不是 clone，改名只会制造混乱。
#
# 现在：config/dataset 显式登记 BUILD_DATASETS（可销毁的构建残留 glob）与
# TEST_BE（声明的验收身份，不算回滚），lib.sh 据此提供谓词。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ordo-dataset.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

dataset="$(cat "$ROOT/config/dataset")"

case_name "config/dataset 登记了构建残留与测试 BE"
assert_contains "$dataset" 'BUILD_DATASETS=' "声明构建残留列表"
assert_contains "$dataset" 'ordo-build-*' "覆盖 ordo-build-* 构建缓存"
assert_contains "$dataset" 'ordo-m2-build' "覆盖 ordo-m2-build"
assert_contains "$dataset" 'TEST_BE="${TEST_BE:-$POOL/root/ordo-m2-hardware}"' \
    "显式登记验收镜像的测试 BE"
assert_contains "$dataset" 'zfs destroy -r rpool/root/ordo-m2-hardware' "给出测试 BE 的清理命令"
assert_contains "$dataset" 'grep -E "^rpool/(ordo-build-|ordo-m2-build$)"' \
    "清理命令与声明同名"
assert_contains "$dataset" 'xargs -r -n1 zfs destroy -r' "构建残留的清理路径可执行"

run_identity() { # running-root
    ORDO_CONFIG="$ROOT/config/dataset" /bin/sh -c '
        . "$1/scripts/lib.sh"
        RUNNING_ROOT=$2
        printf "rolled=%s test_be=%s ephemeral=%s\n" \
            "$(is_rolled_back_env && printf 1 || printf 0)" \
            "$(is_test_be && printf 1 || printf 0)" \
            "$(ordo_is_ephemeral_dataset "$2" && printf 1 || printf 0)"
    ' sh "$ROOT" "$1"
}

case_name "规范数据集：正常身份"
_out="$(run_identity rpool/root/ordo)"
assert_eq "$_out" "rolled=0 test_be=0 ephemeral=0" "规范名不算回滚、不算临时"

case_name "测试 BE：是声明的身份，不是回滚 clone"
_out="$(run_identity rpool/root/ordo-m2-hardware)"
assert_eq "$_out" "rolled=0 test_be=1 ephemeral=1" "测试 BE 不触发回滚语义"

case_name "构建残留：登记为临时数据集"
_out="$(run_identity rpool/ordo-build-010)"
assert_eq "$_out" "rolled=1 test_be=0 ephemeral=1" "ordo-build-* 命中临时列表"
_out="$(run_identity rpool/ordo-m2-build)"
assert_eq "$_out" "rolled=1 test_be=0 ephemeral=1" "ordo-m2-build 命中临时列表"
_out="$(run_identity rpool/home)"
assert_eq "$_out" "rolled=1 test_be=0 ephemeral=0" "用户数据不是构建残留"

case_name "回滚 clone 仍然按漂移处理"
_out="$(run_identity rpool/root/ordo-rb-20260101-000000)"
assert_eq "$_out" "rolled=1 test_be=0 ephemeral=0" "非声明的非规范名不能豁免"

case_name "ordo snap 的身份提示：测试 BE 不再给 promote/rename 建议"
_out="$(ORDO_CONFIG="$ROOT/config/dataset" /bin/sh -c '
    . "$1/scripts/lib.sh"
    RUNNING_ROOT=$2
    warn_if_identity_drift
' sh "$ROOT" rpool/root/ordo-m2-hardware 2>&1)"
assert_eq "$_out" "" "测试 BE 不输出身份漂移提示"
_out="$(ORDO_CONFIG="$ROOT/config/dataset" /bin/sh -c '
    . "$1/scripts/lib.sh"
    RUNNING_ROOT=$2
    warn_if_identity_drift
' sh "$ROOT" rpool/root/ordo-rb-20260101-000000 2>&1)"
assert_contains "$_out" "非规范数据集" "真正的回滚 clone 仍提示"

finish
