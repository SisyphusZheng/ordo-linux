#!/bin/sh
# elogind system-sleep 钩子：外接 USB 根池的睡前/醒后处理。
#
# elogind 以 root 同步调用：$1=pre|post，$2=suspend|hibernate|hybrid-sleep。
# 这里只做两件事：
#   pre —— 把根池脏数据刷到盘上，缩短拔盘瞬间的丢失窗口；
#   post —— 池不是 ONLINE 就留下持久标记并用 wall 播报。
#
# 【硬约束】无论哪一步失败都必须 exit 0。system-sleep 是同步钩子，post 卡住
# 会直接卡住唤醒（第四轮验收特别项）；zpool 命令全部套 timeout，通知失败只
# 尽力而为，不能把「唤醒」这个主流程拖死。
set -u

action=${1:-}
phase=${2:-}
run_dir=${ORDO_RUN_DIR:-/run/ordo}
pool=${ORDO_ROOT_POOL:-rpool}
marker=$run_dir/root-pool-failed

announce() { # $1 = 一句话说明
    _text=$1
    if command -v wall >/dev/null 2>&1; then
        printf '%s\n' "$_text" | timeout 5 wall 2>/dev/null || :
    fi
    # 有活动会话总线时补一条 critical 通知；只发第一个会话，避免多用户时
    # post 钩子被多少个会话就多阻塞多少秒。
    for _bus in /run/user/[0-9]*/bus; do
        [ -S "$_bus" ] || continue
        _uid=${_bus#/run/user/}
        _uid=${_uid%/bus}
        command -v notify-send >/dev/null 2>&1 || continue
        command -v runuser >/dev/null 2>&1 || continue
        timeout 5 runuser -u "$_uid" -- env \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$_bus" \
            XDG_RUNTIME_DIR="/run/user/$_uid" \
            notify-send -u critical -a ordo '外接系统盘异常' "$_text" \
            >/dev/null 2>&1 || :
        break
    done
    command -v logger >/dev/null 2>&1 && logger -t ordo-sleep "$_text" 2>/dev/null || :
    return 0
}

mark() { # $1 = 状态说明
    mkdir -p "$run_dir" 2>/dev/null || :
    _tmp=$marker.$$
    {
        printf 'pool=%s\n' "$pool"
        printf 'state=%s\n' "$1"
        printf 'action=%s\n' "${phase:-unknown}"
        printf 'time=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } >"$_tmp" 2>/dev/null && mv -f "$_tmp" "$marker" 2>/dev/null || :
    return 0
}

case "$action" in
    pre)
        # 池已 suspend 时 zpool sync 会一直等下去：timeout 后照常进入睡眠，
        # 由 post 的 status 检查负责报告故障。
        timeout 20 zpool sync "$pool" 2>/dev/null || :
        ;;
    post)
        status=$(timeout 5 zpool status -x "$pool" 2>/dev/null)
        rc=$?
        case "$rc" in
            0)
                case "$status" in
                    *"is healthy"*)
                        # 池恢复健康：旧标记的含义是「当前仍故障」，清掉。
                        rm -f "$marker" 2>/dev/null || :
                        ;;
                    *)
                        mark '非 ONLINE'
                        announce "Ordo: 唤醒后根池 $pool 不是 ONLINE，请勿直接断电；恢复步骤见手册 10"
                        ;;
                esac
                ;;
            124)
                mark 'zpool status 超时（池可能 suspended）'
                announce "Ordo: 唤醒后根池 $pool 状态读取超时（疑似 suspended），请勿直接断电"
                ;;
            *)
                mark "zpool status 退出码 $rc"
                announce "Ordo: 唤醒后无法读取根池 $pool 状态（退出码 $rc），请保留日志并保留救援盘"
                ;;
        esac
        ;;
esac

# 有意固定为 0：钩子失败不得阻塞唤醒（见文件头硬约束）。
exit 0
