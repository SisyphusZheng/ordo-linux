#!/bin/sh
# 回归：A2 ordo 自更新 + 作废迁移退场；A7 构建残留清理
#
# 缺陷证据（D1-4 / D3-5）：
#   - /opt/ordo 是冻结副本，修复只对「下一次重装」生效；而重装先 wipefs 整盘。
#   - 迁移 1795627149 引用已删除的 app-crypt/libsecret::local，sysup 在迁移
#     阶段必然中止，且没有任何检查能提前发现悬空 atom。
#   - 交付镜像带着构建数据集与测试 BE，只有手工 zfs destroy 一条路。
#
# 本用例覆盖：自更新的校验/拒绝/原子切换（软链 rename）、sysup 的调用顺序、
# 迁移 atom 审计、cleanup-build 的 bootfs 守卫与销毁顺序。
set -eu
cd "$(dirname "$(readlink -f "$0")")/../.."
. "tests/lib/assert.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ordo-selfupdate.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"
mkdir -p "$bin"

sha_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    fi
}

mk_release() { # 版本 输出 tarball
    _v=$1; _out=$2
    rm -rf "$tmp/pkg"
    mkdir -p "$tmp/pkg/ordo-$_v/scripts"
    cp scripts/lib.sh scripts/ordo scripts/ordo-migrate "$tmp/pkg/ordo-$_v/scripts/"
    printf '%s\n' "$_v" > "$tmp/pkg/ordo-$_v/version"
    ( cd "$tmp/pkg" && tar -czf "$_out" "ordo-$_v" )
}

case_name "A2 自更新脚本存在且接入 sysup 的迁移前步骤"

assert_rc "$([ -x scripts/ordo-selfupdate ] && echo 0 || echo 1)" 0 "scripts/ordo-selfupdate 可执行"

_sysup="$(cat scripts/sysup)"
assert_contains "$_sysup" 'ordo-selfupdate' "sysup 调用自更新"
assert_contains "$_sysup" '--no-selfupdate' "sysup 提供跳过开关（文档与参数一致）"

_i_self=$(grep -n '更新 ordo 工具链' scripts/sysup | head -1 | cut -d: -f1)
_i_mig=$(grep -n '运行待执行迁移' scripts/sysup | head -1 | cut -d: -f1)
assert_rc "$([ -n "$_i_self" ] && [ -n "$_i_mig" ] && [ "$_i_self" -lt "$_i_mig" ] && echo 0 || echo 1)" 0 \
    "自更新在迁移之前（新迁移只存在于新版本里）"
_block="$(sed -n '/# 0) 自更新/,/^if \[ "\$RUN_MIGRATE"/p' scripts/sysup)"
assert_contains "$_block" 'exit "$ORDO_EXIT_BAD"' "自更新失败时中止（不继续迁移）"
assert_contains "$_block" '2) ordo_warn' "没有更新源（退出码 2）只告警，不算通过"

# 原子切换的实现形态：临时软链 + rename(2)，不是先删后拷。
assert_contains "$(cat scripts/ordo-selfupdate)" 'mv -T "$1" "$2"' \
    "GNU mv -T：把目标软链当文件 rename（原子）"
assert_contains "$(cat scripts/ordo-selfupdate)" 'mv -h "$1" "$2"' \
    "BSD mv -h：目标软链不跟随（原子）"
assert_contains "$(cat scripts/ordo-selfupdate)" 'ln -s "$TARGET_DIR" "$_lnk"' \
    "先建临时软链再 rename"

case_name "A2 首次更新：真实目录转软链并保留旧版本"

mkdir -p "$tmp/opt/ordo/scripts"
cp scripts/lib.sh scripts/ordo scripts/ordo-migrate "$tmp/opt/ordo/scripts/"
printf '0.1.0\n' > "$tmp/opt/ordo/version"
mk_release 9.9.9 "$tmp/r1.tgz"
_sha1="$(sha_of "$tmp/r1.tgz")"
rc=0
sh scripts/ordo-selfupdate --root "$tmp/opt/ordo" --from "$tmp/r1.tgz" --sha256 "$_sha1" \
    > "$tmp/o1" 2> "$tmp/e1" || rc=$?
assert_rc "$rc" 0 "首次更新退出 0"
assert_rc "$([ -L "$tmp/opt/ordo" ] && echo 0 || echo 1)" 0 "安装根变成软链（之后才能原子切换）"
assert_eq "$(cat "$tmp/opt/ordo/version")" "9.9.9" "version 指向新版本"
assert_rc "$([ -d "$tmp/opt/ordo.d/9.9.9" ] && echo 0 || echo 1)" 0 "版本目录落在 ordo.d"
assert_rc "$([ -d "$tmp/opt/ordo.d/legacy-0.1.0" ] && echo 0 || echo 1)" 0 "旧真实目录保留为 legacy-0.1.0"
case "$(readlink "$tmp/opt/ordo")" in
    */ordo.d/9.9.9) assert_rc 0 0 "软链指向 9.9.9" ;;
    *) assert_rc "$(readlink "$tmp/opt/ordo")" "*/ordo.d/9.9.9" "软链指向 9.9.9" ;;
esac

case_name "A2 再次更新：原子替换，旧版本目录保留"

mk_release 9.9.10 "$tmp/r2.tgz"
_sha2="$(sha_of "$tmp/r2.tgz")"
rc=0
sh scripts/ordo-selfupdate --root "$tmp/opt/ordo" --from "$tmp/r2.tgz" --sha256 "$_sha2" \
    > "$tmp/o2" 2> "$tmp/e2" || rc=$?
assert_rc "$rc" 0 "第二次更新退出 0"
assert_eq "$(cat "$tmp/opt/ordo/version")" "9.9.10" "version 指向 9.9.10"
assert_rc "$([ -d "$tmp/opt/ordo.d/9.9.9" ] && echo 0 || echo 1)" 0 "上一版本仍保留（可手工回指）"

case_name "A2 摘要不匹配：拒绝安装且不改动安装根"

mk_release 9.9.11 "$tmp/r3.tgz"
rc=0
sh scripts/ordo-selfupdate --root "$tmp/opt/ordo" --from "$tmp/r3.tgz" \
    --sha256 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" \
    > "$tmp/o3" 2> "$tmp/e3" || rc=$?
assert_rc "$rc" 1 "摘要不匹配退出 1"
assert_contains "$(cat "$tmp/e3")" "摘要不匹配" "点名摘要不匹配"
assert_eq "$(cat "$tmp/opt/ordo/version")" "9.9.10" "安装根仍是旧版本"
assert_rc "$([ -e "$tmp/opt/ordo.d/9.9.11" ] && echo 1 || echo 0)" 0 "没有落下半套新版本"

case_name "A2 无更新源：退出 2（无法判定，不是成功）"

rc=0
ORDO_SELFUPDATE_CONF="$tmp/none.conf" ORDO_SELFUPDATE_SOURCE="" \
    sh scripts/ordo-selfupdate --root "$tmp/opt/ordo" > "$tmp/o4" 2> "$tmp/e4" || rc=$?
assert_rc "$rc" 2 "无更新源退出 2"
assert_contains "$(cat "$tmp/e4")" "没有配置更新源" "说明缺的是更新源"

case_name "A2 dry-run 不落盘"

mk_release 9.9.12 "$tmp/r4.tgz"
_sha4="$(sha_of "$tmp/r4.tgz")"
rc=0
sh scripts/ordo-selfupdate --root "$tmp/opt/ordo" --from "$tmp/r4.tgz" --sha256 "$_sha4" --dry-run \
    > "$tmp/o5" 2> "$tmp/e5" || rc=$?
assert_rc "$rc" 0 "dry-run 退出 0"
assert_rc "$([ -e "$tmp/opt/ordo.d/9.9.12" ] && echo 1 || echo 0)" 0 "dry-run 不创建版本目录"
assert_eq "$(cat "$tmp/opt/ordo/version")" "9.9.10" "dry-run 不改安装根"

case_name "A2 迁移里的 atom 必须仍有声明（悬空 atom 红）"

_audit_rc=0
sh -c '. scripts/lib.sh; ordo_migration_dangling_atoms config' > "$tmp/atoms" 2>&1 || _audit_rc=$?
assert_rc "$_audit_rc" 0 "现有迁移没有悬空 atom"
assert_eq "$(cat "$tmp/atoms")" "" "审计输出为空"
assert_rc "$([ -e config/migrations/1795627149-remove-gnome-keyring.sh ] && echo 1 || echo 0)" 0 \
    "引用已删除 ::local 配方的迁移已删除"

mkdir -p "$tmp/fixture/migrations" "$tmp/fixture/overlay/gui-apps/foo"
printf 'sys-apps/baseline\n' > "$tmp/fixture/world"
cat > "$tmp/fixture/migrations/123-bad.sh" <<'BAD'
#!/bin/sh
emerge --ask=n app-crypt/libsecret::local app-misc/no-such-package
BAD
rc=0
sh -c '. scripts/lib.sh; ordo_migration_dangling_atoms "$1" "$2"' sh \
    "$tmp/fixture" "$tmp/fixture/overlay" > "$tmp/atoms2" 2>&1 || rc=$?
assert_rc "$rc" 1 "fixture 的悬空 atom 被判红"
assert_contains "$(cat "$tmp/atoms2")" "app-crypt/libsecret::local" "抓到指向已删除 overlay 的 atom"
assert_contains "$(cat "$tmp/atoms2")" "app-misc/no-such-package" "抓到未声明的 atom"

case_name "A7 cleanup-build：先判 bootfs，再按池销毁"

cat > "$bin/id" <<'ID'
#!/bin/sh
printf '0\n'
ID
cat > "$bin/findmnt" <<'FM'
#!/bin/sh
exit 1
FM
cat > "$bin/zfs" <<'Z'
#!/bin/sh
printf 'zfs %s\n' "$*" >> "$CMD_LOG"
cmd=${1:-}; shift 2>/dev/null || true
case "$cmd" in
    list)
        cat "$DATASETS"
        ;;
    destroy)
        ds=""
        for a in "$@"; do case "$a" in -*) ;; *) ds=$a ;; esac; done
        printf 'DESTROY %s\n' "$ds" >> "$CMD_LOG"
        awk -v d="$ds" '$0 != d && index($0, d "/") != 1' "$DATASETS" > "$DATASETS.new"
        mv "$DATASETS.new" "$DATASETS"
        ;;
esac
exit 0
Z
cat > "$bin/zpool" <<'ZP'
#!/bin/sh
printf 'zpool %s\n' "$*" >> "$CMD_LOG"
printf '%s\n' "$BOOTFS"
ZP
chmod 755 "$bin/id" "$bin/findmnt" "$bin/zfs" "$bin/zpool"

printf 'POOL=rpool\nDATASET=rpool/root/ordo\nHOME_DATASET=rpool/home\nBUILD_DATASETS="rpool/ordo-build-* rpool/ordo-m2-build"\nTEST_BE=rpool/root/ordo-m2-hardware\n' \
    > "$tmp/dataset"
cat > "$tmp/datasets" <<'DS'
rpool/root/ordo
rpool/home
rpool/ordo-build-20260101
rpool/ordo-build-20260101/child
rpool/ordo-m2-build
rpool/root/ordo-m2-hardware
rpool/root/ordo-m2-hardware/child
DS

run_cleanup() {
    PATH="$bin:$PATH" CMD_LOG="$tmp/cmd.log" DATASETS="$tmp/datasets" \
    ORDO_CONFIG="$tmp/dataset" BOOTFS="$1" \
    LC_ALL= LANG=zh_CN.UTF-8 sh scripts/ordo-snap cleanup-build ${2:-}
}

: > "$tmp/cmd.log"
rc=0
run_cleanup rpool/root/ordo > "$tmp/co1" 2> "$tmp/ce1" || rc=$?
assert_rc "$rc" 0 "cleanup-build 退出 0"
assert_eq "$(awk '/^DESTROY/ {n++} END {print n+0}' "$tmp/cmd.log")" "3" \
    "只销毁 3 个顶层候选（子数据集随父递归，不单独再删）"
assert_contains "$(cat "$tmp/cmd.log")" "DESTROY rpool/ordo-build-20260101" "销毁构建缓存"
assert_contains "$(cat "$tmp/cmd.log")" "DESTROY rpool/ordo-m2-build" "销毁 m2 构建数据集"
assert_contains "$(cat "$tmp/cmd.log")" "DESTROY rpool/root/ordo-m2-hardware" "销毁测试 BE"
assert_not_contains "$(cat "$tmp/cmd.log")" "DESTROY rpool/root/ordo-m2-hardware/child" \
    "子数据集不单独销毁"
assert_not_contains "$(cat "$tmp/cmd.log")" "DESTROY rpool/root/ordo$" "不碰发行根"
_boot_line=$(grep -n 'zpool get' "$tmp/cmd.log" | head -1 | cut -d: -f1)
_destroy_line=$(grep -n '^DESTROY' "$tmp/cmd.log" | head -1 | cut -d: -f1)
assert_rc "$([ -n "$_boot_line" ] && [ -n "$_destroy_line" ] && [ "$_boot_line" -lt "$_destroy_line" ] && echo 0 || echo 1)" 0 \
    "bootfs 判据在第一次 destroy 之前"

case_name "A7 cleanup-build：bootfs 指向测试 BE 时整体拒绝"

cat > "$tmp/datasets" <<'DS'
rpool/root/ordo
rpool/home
rpool/ordo-build-20260101
rpool/root/ordo-m2-hardware
DS
: > "$tmp/cmd.log"
rc=0
run_cleanup rpool/root/ordo-m2-hardware > "$tmp/co2" 2> "$tmp/ce2" || rc=$?
assert_rc "$rc" 1 "bootfs 在候选中时退出 1"
assert_contains "$(cat "$tmp/ce2")" "拒绝清理" "明确拒绝"
assert_eq "$(awk '/^DESTROY/ {n++} END {print n+0}' "$tmp/cmd.log")" "0" "拒绝时不销毁任何数据集"

case_name "A7 cleanup-build：没有候选与 --dry-run 都零变更"

printf 'rpool/root/ordo\nrpool/home\n' > "$tmp/datasets"
: > "$tmp/cmd.log"
rc=0
run_cleanup rpool/root/ordo > "$tmp/co3" 2> "$tmp/ce3" || rc=$?
assert_rc "$rc" 0 "没有候选时退出 0"
assert_contains "$(cat "$tmp/co3")" "没有需要清理" "说明无需清理"

cat > "$tmp/datasets" <<'DS'
rpool/root/ordo
rpool/ordo-build-20260101
DS
: > "$tmp/cmd.log"
rc=0
run_cleanup rpool/root/ordo --dry-run > "$tmp/co4" 2> "$tmp/ce4" || rc=$?
assert_rc "$rc" 0 "dry-run 退出 0"
assert_eq "$(awk '/^DESTROY/ {n++} END {print n+0}' "$tmp/cmd.log")" "0" "dry-run 不销毁"
assert_contains "$(cat "$tmp/co4")" "将销毁 rpool/ordo-build-20260101" "dry-run 列出将要销毁的对象"

case_name "A7 安装收尾调用 cleanup-build"

assert_contains "$(cat install.sh)" "ordo-snap cleanup-build" "install.sh 收尾调用一次"
assert_contains "$(cat config/platform/m2/install-external.sh)" "ordo-snap cleanup-build" \
    "M2 外置安装收尾调用一次"

finish
