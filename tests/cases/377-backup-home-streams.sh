#!/bin/sh
# 回归：A5 `ordo backup send` 默认包含 /home（D0-4）
#
# 缺陷证据：旧实现的 send 只 `zfs send $RUNNING_ROOT@snap`，手册唯一一条
# 备份命令得到的是不含 /home 的流 —— 项目、文档、keyring、Flatpak 数据
# 都不在内，而命令照样报「完成」。这条用例用假 zfs 跑完整的双流路径：
#   1) 目录目标 → 两个流文件 + 一份 manifest，两个快照都被 send；
#   2) verify 给目录 → 两个流分别 zfs receive -n 干跑；
#   3) /home 流发送失败 → 命令非零退出、已落盘的根流被删除、不写 manifest；
#   4) 单文件目标 → 默认拒绝（只能装一个流），--root-only 才放行。
set -eu
cd "$(dirname "$(readlink -f "$0")")/../.."
. "tests/lib/assert.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ordo-backup.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"
mkdir -p "$bin" "$tmp/dest" "$tmp/dest2" "$tmp/dest3"

cat > "$bin/zfs" <<'ZFS'
#!/bin/sh
printf '%s\n' "$*" >> "$ZFS_LOG"
cmd=${1:-}; shift 2>/dev/null || true
case "$cmd" in
    list)
        ds=""
        kind="dataset"
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -t) kind=$2; shift 2 ;;
                -o|-s) shift 2 ;;
                -*) shift ;;
                *) ds=$1; shift ;;
            esac
        done
        case "$ds" in
            *@*)
                for s in "$ROOT_DS@auto-hourly-1" "$HOME_DS@auto-hourly-1"; do
                    [ "$ds" = "$s" ] && { printf '%s\n' "$ds"; exit 0; }
                done
                exit 1
                ;;
            '')
                if [ "$kind" = snapshot ]; then
                    printf '%s\n%s\n' "$ROOT_DS@auto-hourly-1" "$HOME_DS@auto-hourly-1"
                else
                    printf '%s\n%s\n' "$ROOT_DS" "$HOME_DS"
                fi
                ;;
            "$ROOT_DS"|"$HOME_DS")
                if [ "$kind" = snapshot ]; then
                    printf '%s@auto-hourly-1\n' "$ds"
                else
                    printf '%s\n' "$ds"
                fi
                ;;
            *) exit 1 ;;
        esac
        ;;
    get)
        last=""
        for a in "$@"; do last=$a; done
        case "$last" in
            *@*) printf '1000\n' ;;
            *)   printf '1G\n' ;;
        esac
        ;;
    send)
        last=""
        for a in "$@"; do last=$a; done
        case "$SEND_FAIL" in
            '') ;;
            *) case "$last" in *"$SEND_FAIL"*) exit 1 ;; esac ;;
        esac
        printf 'ZFSSTREAM %s\n' "$last"
        ;;
    receive)
        cat >> "$RECV_LOG"
        printf 'would receive\n'
        ;;
    *) : ;;
esac
exit 0
ZFS

# require_root 只认 `id -u`；用例不写任何系统路径（日志也重定向到临时目录）。
cat > "$bin/id" <<'ID'
#!/bin/sh
printf '0\n'
ID
# 目标目录不是 ZFS 挂载点：跳过同池比较。
cat > "$bin/findmnt" <<'FM'
#!/bin/sh
exit 1
FM
chmod 755 "$bin/zfs" "$bin/id" "$bin/findmnt"

run_backup() {
    PATH="$bin:$PATH" \
    ZFS_LOG="$tmp/zfs.log" RECV_LOG="$tmp/recv.log" \
    ROOT_DS=rpool/root/ordo HOME_DS=rpool/home \
    ORDO_BACKUP_LOG="$tmp/backup.log" \
    LC_ALL= LANG=zh_CN.UTF-8 \
    "$@"
}

case_name "A5 目录目标：两个流 + manifest"

rc=0
run_backup sh scripts/ordo-backup send "$tmp/dest" > "$tmp/out1" 2> "$tmp/err1" || rc=$?
assert_rc "$rc" 0 "send 退出 0"
assert_contains "$(cat "$tmp/out1")" "备份 rpool/root/ordo@auto-hourly-1" "报了根快照"
assert_contains "$(cat "$tmp/out1")" "rpool/home@auto-hourly-1" "报了 /home 快照"

_manifest="$(ls "$tmp/dest"/*.manifest 2>/dev/null | head -1)"
assert_rc "$([ -n "$_manifest" ] && echo 0 || echo 1)" 0 "写了 manifest"
_root_file="$(ls "$tmp/dest"/rpool-root-ordo-auto-hourly-1-*.zfs.gz 2>/dev/null | head -1)"
_home_file="$(ls "$tmp/dest"/rpool-home-auto-hourly-1-*.zfs.gz 2>/dev/null | head -1)"
assert_rc "$([ -n "$_root_file" ] && echo 0 || echo 1)" 0 "根流文件存在"
assert_rc "$([ -n "$_home_file" ] && echo 0 || echo 1)" 0 "/home 流文件存在"

assert_active_line "$_manifest" "root_file rpool-root-ordo-auto-hourly-1" "manifest 记录根流"
assert_active_line "$_manifest" "home_file rpool-home-auto-hourly-1" "manifest 记录 /home 流"
assert_active_line "$_manifest" "root_snapshot rpool/root/ordo@auto-hourly-1" "manifest 记录根快照"
assert_active_line "$_manifest" "home_snapshot rpool/home@auto-hourly-1" "manifest 记录 /home 快照"

assert_contains "$(cat "$tmp/zfs.log")" "send -v rpool/root/ordo@auto-hourly-1" "根快照被 zfs send"
assert_contains "$(cat "$tmp/zfs.log")" "send -v rpool/home@auto-hourly-1" "/home 快照被 zfs send"

case_name "A5 verify 目录：两个流都 receive -n"

: > "$tmp/recv.log"
rc=0
run_backup sh scripts/ordo-backup verify "$tmp/dest" > "$tmp/out2" 2> "$tmp/err2" || rc=$?
assert_rc "$rc" 0 "verify 目录退出 0"
assert_eq "$(grep -c 'ZFSSTREAM' "$tmp/recv.log" 2>/dev/null || printf '0')" "2" \
    "两个流都被 zfs receive -n 干跑"
assert_contains "$(cat "$tmp/out2")" "验证通过" "给出验证通过结论"

case_name "A5 /home 流失败：根流删除且不写 manifest"

rc=0
run_backup env SEND_FAIL=rpool/home sh scripts/ordo-backup send "$tmp/dest2" \
    > "$tmp/out3" 2> "$tmp/err3" || rc=$?
assert_rc "$rc" 1 "/home 流失败时命令退出 1"
assert_contains "$(cat "$tmp/err3")" "已删除只有根流的" "点名删除半套备份的原因"
assert_rc "$(ls "$tmp/dest2"/*.manifest 2>/dev/null | head -1 | grep -q . && echo 0 || echo 1)" \
    1 "失败时不写 manifest"
assert_eq "$(ls -1 "$tmp/dest2" 2>/dev/null | wc -l | tr -d ' ')" "0" "失败时目录里没有残留流文件"

case_name "A5 单文件目标默认拒绝 / --root-only 放行"

rc=0
run_backup sh scripts/ordo-backup send "$tmp/one.zfs" > "$tmp/out4" 2> "$tmp/err4" || rc=$?
assert_rc "$rc" 1 "单文件目标默认退出 1"
assert_contains "$(cat "$tmp/err4")" "目标不是目录" "说清为什么拒绝"

: > "$tmp/zfs.log"
rc=0
run_backup sh scripts/ordo-backup send --root-only "$tmp/root-only.zfs" \
    > "$tmp/out5" 2> "$tmp/err5" || rc=$?
assert_rc "$rc" 0 "--root-only 单文件退出 0"
assert_rc "$([ -s "$tmp/root-only.zfs" ] && echo 0 || echo 1)" 0 "根流文件已写出"
assert_not_contains "$(cat "$tmp/zfs.log")" "send -v rpool/home@" "--root-only 不发送 /home"

case_name "A5 /home 没有快照时默认拒绝（不静默降级为只备根）"

_empty_home="$(cat "$bin/zfs")"
# 用环境变量让假 zfs 认为 /home 数据集存在但没有任何快照。
cat > "$bin/zfs" <<'ZFS'
#!/bin/sh
printf '%s\n' "$*" >> "$ZFS_LOG"
cmd=${1:-}; shift 2>/dev/null || true
case "$cmd" in
    list)
        ds=""
        kind="dataset"
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -t) kind=$2; shift 2 ;;
                -o|-s) shift 2 ;;
                -*) shift ;;
                *) ds=$1; shift ;;
            esac
        done
        case "$ds" in
            *@*) exit 1 ;;
            '')  printf '%s\n%s\n' "$ROOT_DS" "$HOME_DS" ;;
            "$ROOT_DS")
                if [ "$kind" = snapshot ]; then printf '%s@auto-hourly-1\n' "$ds"; fi
                printf '%s\n' "$ds"
                ;;
            "$HOME_DS")
                if [ "$kind" = dataset ]; then printf '%s\n' "$ds"; fi
                ;;
            *) exit 1 ;;
        esac
        ;;
    get) printf '1000\n' ;;
    *) : ;;
esac
exit 0
ZFS
chmod 755 "$bin/zfs"
rc=0
run_backup sh scripts/ordo-backup send "$tmp/dest3" > "$tmp/out6" 2> "$tmp/err6" || rc=$?
assert_rc "$rc" 1 "无一可用 /home 快照时退出 1"
assert_contains "$(cat "$tmp/err6")" "无法备份 /home" "点名 /home 无法备份"
assert_contains "$(cat "$tmp/out6" "$tmp/err6")" "--root-only" "给出显式降级选项"
printf '%s' "$_empty_home" > "$bin/zfs"
chmod 755 "$bin/zfs"

case_name "A5 没有独立 /home 数据集：根流即完整，manifest 标注"

mkdir -p "$tmp/dest4"
cat > "$bin/zfs" <<'ZFS'
#!/bin/sh
printf '%s\n' "$*" >> "$ZFS_LOG"
cmd=${1:-}; shift 2>/dev/null || true
case "$cmd" in
    list)
        ds=""
        kind="dataset"
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -t) kind=$2; shift 2 ;;
                -o|-s) shift 2 ;;
                -*) shift ;;
                *) ds=$1; shift ;;
            esac
        done
        case "$ds" in
            *@*) exit 1 ;;
            '')  printf '%s\n' "$ROOT_DS" ;;
            "$ROOT_DS")
                [ "$kind" = snapshot ] && printf '%s@auto-hourly-1\n' "$ds"
                printf '%s\n' "$ds"
                ;;
            *) exit 1 ;;   # /home 数据集在此布局中不存在
        esac
        ;;
    get) last=""; for a in "$@"; do last=$a; done
         case "$last" in *@*) printf '1000\n' ;; *) printf '1G\n' ;; esac ;;
    send) last=""; for a in "$@"; do last=$a; done; printf 'ZFSSTREAM %s\n' "$last" ;;
    receive) cat >> "$RECV_LOG" ;;
esac
exit 0
ZFS
chmod 755 "$bin/zfs"
: > "$tmp/zfs.log"
rc=0
run_backup sh scripts/ordo-backup send "$tmp/dest4" > "$tmp/out8" 2> "$tmp/err8" || rc=$?
assert_rc "$rc" 0 "无独立 /home 时 send 退出 0"
assert_contains "$(cat "$tmp/out8")" "/home 在根流内" "说明 /home 已在根流内"
_manifest4="$(ls "$tmp/dest4"/*.manifest 2>/dev/null | head -1)"
assert_active_line "$_manifest4" "home_in_root yes" "manifest 标注 /home 在根流内"
assert_rc "$(ls "$tmp/dest4"/rpool-home-* 2>/dev/null | head -1 | grep -q . && echo 0 || echo 1)" 1 \
    "不产生多余的 home 流文件"
: > "$tmp/recv.log"
rc=0
run_backup sh scripts/ordo-backup verify "$tmp/dest4" > "$tmp/out9" 2> "$tmp/err9" || rc=$?
assert_rc "$rc" 0 "verify 接受 home_in_root 的 manifest"
assert_eq "$(awk '/ZFSSTREAM/ {n++} END {print n+0}' "$tmp/recv.log")" "1" "只干跑根流"

case_name "A5 帮助与状态反映双流范围"

assert_contains "$(sh scripts/ordo-backup --help 2>&1)" "两个流" "帮助写明默认两个流"
run_backup sh scripts/ordo-backup status > "$tmp/out7" 2> "$tmp/err7" || true
assert_contains "$(cat "$tmp/out7")" "用户数据" "status 报告 /home 数据集"

finish
