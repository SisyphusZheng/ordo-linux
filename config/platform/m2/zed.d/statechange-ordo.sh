#!/bin/sh
# ZED zedlet：外接根池状态变化时留下持久标记并双通道播报（D0-3）。
#
# 掉盘后桌面会因为根文件系统 I/O 阻塞而整机卡死，屏幕上没有一个字；下一次
# 启动必须能知道「东西少了一截」的原因。这里只做三件事：
#   1. 非 ONLINE 状态写 /run/ordo/root-pool-failed（池名 / 状态 / 时间）；
#   2. wall 通知所有终端（桌面卡死时这是唯一一定可见的通道）；
#   3. 有用户会话总线时补一条 critical 通知（尽力而为，失败不影响退出码）。
# ONLINE 时清掉标记：标记表示「当前仍故障」，不是历史记录。
#
# zed 会把每个事件都送进来，正常状态必须零输出（第四轮验收特别项）。
set -u

run_dir=${ORDO_RUN_DIR:-/run/ordo}
pool=${ORDO_ROOT_POOL:-rpool}
marker=$run_dir/root-pool-failed
event_pool=${ZEVENT_POOL:-}
# zed 的事件类只有 statechange；健康状态在 *_STR 变量里（数字形式不可读）。
# 子类/变量名与上游 statechange-notify.sh 对齐：ZEVENT_VDEV_STATE_STR。
state=${ZEVENT_VDEV_STATE_STR:-${ZEVENT_POOL_STATE_STR:-${ZEVENT_POOL_STATE:-}}}
case "$state" in
    ONLINE|DEGRADED|FAULTED|REMOVED|UNAVAIL|OFFLINE|SUSPENDED|UNKNOWN) ;;
    *) state= ;;
esac

# 不是根池的事件直接走开；手工执行（无 ZEVENT_*）时按 rpool 继续。
[ -z "$event_pool" ] || [ "$event_pool" = "$pool" ] || exit 0

# 带池状态的事件直接处理（statechange / pool 等子类都会带 ZEVENT_POOL_STATE）。
# 没有状态的事件只接受 statechange 或手工执行；io/data/history 与掉盘无关，
# 放行它们会每来一条事件就 fork 一次 zpool。
if [ -z "$state" ]; then
    case "${ZEVENT_SUBCLASS:-}" in
        ''|statechange) ;;
        *) exit 0 ;;
    esac
fi

announce() { # $1 = 一句话说明
    _text=$1
    if command -v wall >/dev/null 2>&1; then
        printf '%s\n' "$_text" | timeout 5 wall 2>/dev/null || :
    fi
    for _bus in /run/user/[0-9]*/bus; do
        [ -S "$_bus" ] || continue
        _uid=${_bus#/run/user/}
        _uid=${_uid%/bus}
        _user=$(getent passwd "$_uid" 2>/dev/null | cut -d: -f1)
        [ -n "$_user" ] && _uid=$_user
        command -v notify-send >/dev/null 2>&1 || continue
        command -v runuser >/dev/null 2>&1 || continue
        timeout 5 runuser -u "$_uid" -- env \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$_bus" \
            XDG_RUNTIME_DIR="/run/user/$_uid" \
            notify-send -u critical -a ordo '外接系统盘异常' "$_text" \
            >/dev/null 2>&1 || :
        break
    done
    command -v logger >/dev/null 2>&1 && logger -t ordo-zed "$_text" 2>/dev/null || :
    return 0
}

mark() { # $1 = 状态说明
    mkdir -p "$run_dir" 2>/dev/null || :
    _tmp=$marker.$$
    {
        printf 'pool=%s\n' "$pool"
        printf 'state=%s\n' "$1"
        printf 'time=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        [ -z "${detail:-}" ] || printf 'detail=%s\n' "$detail"
    } >"$_tmp" 2>/dev/null && mv -f "$_tmp" "$marker" 2>/dev/null || :
    return 0
}

if [ -n "$state" ]; then
    case "$state" in
        ONLINE) healthy=1 ;;
        *) healthy=0 ;;
    esac
else
    # 有些事件只带 ZEVENT_POOL 不带状态，用 zpool status -x 兜底。
    # 池 suspended 时该命令会挂住，timeout 后按故障处理。
    detail=$(timeout 5 zpool status -x "$pool" 2>/dev/null) || detail=
    case "$detail" in
        *"is healthy"*) state=ONLINE; healthy=1 ;;
        *) state=UNKNOWN; healthy=0 ;;
    esac
fi

if [ "$healthy" = 1 ]; then
    rm -f "$marker" 2>/dev/null || :
    exit 0
fi

mark "$state"
announce "Ordo: 系统盘根池 $pool 状态为 $state；不要直接断电，恢复步骤见手册 10"
# 有意固定为 0：播报是尽力而为，zed 不该因为本 zedlet 重复报错。
exit 0
