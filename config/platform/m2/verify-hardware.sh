#!/bin/sh
# Run as the logged-in Wayland user on a MacBook Air M2 (J413).
set -u

case "${1:-}" in ''|--capture-camera|--session-report|--resume) ;; *) exit 2 ;; esac
capture=${1:-}
if [ ! -r /proc/device-tree/compatible ] ||
   ! tr '\000' '\n' < /proc/device-tree/compatible | grep -Fxq apple,j413; then
    printf '%s\n' '无法判定：此检查需要 MacBook Air M2 J413 的设备树。' >&2
    exit 2
fi

# Run from Umbriel after it has created the Wayland socket. Keep the latest
# measurement in the user's state directory, including failures and timeouts.
if [ "$capture" = --session-report ]; then
    umask 077
    state=${XDG_STATE_HOME:-"$HOME/.local/state"}/ordo
    mkdir -p "$state" || exit 2
    tmp=$(mktemp "$state/.m2-hardware.XXXXXX") || exit 2
    trap 'rm -f -- "$tmp"' EXIT
    report_status=0
    {
        date -u
        uname -r
        printf 'WLR_RENDERER=%s\n' "${WLR_RENDERER:-auto}"
        printf 'WLR_RENDER_DRM_DEVICE=%s\n' "${WLR_RENDER_DRM_DEVICE:-auto}"
        if [ "${ORDO_ASAHI_RENDER_NODE_TIMEOUT:-0}" = 1 ]; then
            printf '%s\n' '登录时等待可读写的 Asahi 渲染节点超时'
        fi
        if command -v nmcli >/dev/null 2>&1; then
            printf 'NetworkManager devices (type,state):\n'
            LC_ALL=C timeout 5 nmcli -t -f TYPE,STATE device status || :
        fi
        if command -v bluetoothctl >/dev/null 2>&1; then
            printf 'BlueZ controller state:\n'
            LC_ALL=C timeout 5 bluetoothctl show |
                awk '/^[[:space:]]*(Powered|PowerState|Discovering):/ {print}' || :
        fi
        # 外接盘掉线/池 suspend 时 zedlet 会留下持久标记。会话启动（Umbriel
        # autostart 调用本模式）必须把它弹出来，否则用户只会看到「东西少了一截」。
        if [ -r /run/ordo/root-pool-failed ]; then
            printf '根池故障标记：\n'
            sed 's/^/  /' /run/ordo/root-pool-failed 2>/dev/null || :
            printf '异常  外接根池故障（%s）\n' "$(sed -n '1p' /run/ordo/root-pool-failed 2>/dev/null)"
            # critical 通知不会自动消失：池没修好之前每次登录都提示。
            if command -v notify-send >/dev/null 2>&1; then
                timeout 5 notify-send -u critical -a ordo '外接系统盘故障' \
                    "$(sed -n '1,3p' /run/ordo/root-pool-failed 2>/dev/null)" 2>/dev/null || :
            fi
        fi
        timeout 45 sh "$(readlink -f "$0")" || report_status=$?
        case "$report_status" in 0|1|2) ;; *) report_status=2 ;; esac
        # 标记仍在 = 池当前仍故障；硬件项即使全绿也不能打通过（doctor 是消费者）。
        if [ -e /run/ordo/root-pool-failed ] && [ "$report_status" = 0 ]; then
            report_status=1
        fi
        printf 'exit=%s\n' "$report_status"
    } > "$tmp" && mv -f -- "$tmp" "$state/m2-hardware.log" || exit 2
    exit "$report_status"
fi

display() {
    for connector in /sys/class/drm/card*-eDP-*; do
        [ -r "$connector/status" ] && [ "$(cat "$connector/status")" = connected ] || continue
        card=${connector##*/}
        case "$(readlink "/sys/class/drm/${card%%-*}/device/driver" 2>/dev/null)" in
            */apple-drm) return 0 ;;
        esac
    done
    return 1
}

gpu() {
    render=
    for node in /sys/class/drm/renderD*; do
        case "$(readlink "$node/device/driver" 2>/dev/null)" in
            */asahi) render=/dev/dri/${node##*/}; break ;;
        esac
    done
    if [ -z "$render" ] || [ ! -c "$render" ]; then
        printf '  原因：没有绑定 asahi 驱动的渲染节点（AGX 未接管 GPU）\n' >&2
        return 1
    fi
    if ! command -v eglinfo >/dev/null; then
        printf '  原因：缺少 eglinfo（media-libs/mesa-progs），无法判定 EGL 后端\n' >&2
        return 2
    fi
    if [ -z "${WAYLAND_DISPLAY:-}" ]; then
        printf '  原因：不在 Wayland 会话内（WAYLAND_DISPLAY 未设置）\n' >&2
        return 2
    fi
    egl=$(eglinfo -B 2>/dev/null) || [ -n "$egl" ] || {
        printf '  原因：eglinfo -B 无输出\n' >&2
        return 2
    }
    if ! printf '%s\n' "$egl" | awk '
        /^Wayland platform:/ { wayland=1; next }
        /platform:$/ { wayland=0 }
        wayland && $0 ~ /EGL driver name: asahi/ { found=1 }
        END { exit !found }
    '; then
        # 报告必须能自己说明为什么红：留下 Wayland EGL 的关键行（P1-06）
        printf '  原因：Mesa 的 Wayland EGL 驱动不是 asahi；eglinfo -B 关键行：\n' >&2
        printf '%s\n' "$egl" | awk '
            /^Wayland platform:/ { wayland=1; next }
            /platform:$/ { wayland=0 }
            wayland && /EGL driver name:|EGL vendor string:/ { printf "    %s\n", $0 }
        ' >&2
        return 1
    fi
    pid=$(pgrep -u "$(id -u)" -x umbriel) || {
        printf '  原因：当前用户没有 umbriel 进程\n' >&2
        return 2
    }
    [ -r "/proc/$pid/environ" ] || {
        printf '  原因：读不到 umbriel 的环境（权限不足）\n' >&2
        return 2
    }
    if ! tr '\000' '\n' < "/proc/$pid/environ" | grep -Fxq "WLR_RENDER_DRM_DEVICE=$render"; then
        printf '  原因：Umbriel 的 WLR_RENDER_DRM_DEVICE 不是 %s（可能回落 pixman）\n' "$render" >&2
        return 1
    fi
}

# 扬声器保护缺失标记：install-hardware.sh 用 tmpfiles 建 /run/ordo（root:ordo 0770），
# 会话里的 ordo 用户可写。写不进去也不影响检查结论，所以全部尽力而为。
marker_dir=${ORDO_RUN_DIR:-/run/ordo}
speaker_missing() {
    mkdir -p "$marker_dir" 2>/dev/null || :
    printf '%s\n' "$1" > "$marker_dir/speaker-protection-missing" 2>/dev/null || :
}
speaker_ok() {
    rm -f "$marker_dir/speaker-protection-missing" 2>/dev/null || :
}

audio() {
    pgrep -u speakersafetyd -x speakersafetyd >/dev/null 2>&1 || {
        speaker_missing 'speakersafetyd 未运行'
        return 1
    }
    command -v amixer >/dev/null && command -v pw-dump >/dev/null || return 2
    controls=$(amixer -c AppleJ413 controls 2>/dev/null) || {
        speaker_missing '读不到 AppleJ413 的 ALSA 控制'
        return 1
    }
    lock=$(printf '%s\n' "$controls" | sed -n "s/^numid=\([0-9][0-9]*\),.*name='Speaker Volume Unlock'$/\1/p")
    [ -n "$lock" ] || {
        speaker_missing '缺少 Speaker Volume Unlock 控制'
        return 1
    }
    state=$(amixer -c AppleJ413 cget "numid=$lock" 2>/dev/null) || {
        speaker_missing '读不到扬声器音量锁状态'
        return 1
    }
    printf '%s\n' "$state" | grep -Eq '^[[:space:]]*: values=1$' || {
        speaker_missing '扬声器音量锁未启用'
        return 1
    }
    routes=$(pw-dump 2>/dev/null) || {
        speaker_missing '读不到 PipeWire 音频路由'
        return 1
    }
    if ! printf '%s\n' "$routes" | grep -Fq '"node.name": "audio_effect.j413-convolver"' ||
       ! printf '%s\n' "$routes" | grep -Fq '"node.name": "effect_output.j413-mic"'; then
        speaker_missing '缺少 J413 扬声器/麦克风 DSP 节点'
        return 1
    fi
    speaker_ok
    return 0
}

keyboard() {
    command -v gdbus >/dev/null || return 2
    level=$(gdbus call --system --dest org.freedesktop.UPower --timeout 2 \
        --object-path /org/freedesktop/UPower/KbdBacklight \
        --method org.freedesktop.UPower.KbdBacklight.GetMaxBrightness 2>/dev/null) || return 1
    printf '%s\n' "$level" | grep -Eq '^\([1-9][0-9]*,\)$'
}

# 屏幕背光：Fn 键最终落到 Noctalia 的 brightness-*，但面板是否存在必须有人验收。
# /sys/class/backlight 为空或 max_brightness=0 时 Fn 键什么也改不了（D2-3）。
backlight() {
    for _device in /sys/class/backlight/*; do
        [ -d "$_device" ] || continue
        if [ ! -r "$_device/max_brightness" ]; then
            printf '  待验：背光设备的 max_brightness 不可读（%s）\n' "$_device" >&2
            return 2
        fi
        _max=$(cat "$_device/max_brightness" 2>/dev/null) || return 2
        case "$_max" in
            ''|*[!0-9]*) return 2 ;;
        esac
        [ "$_max" -gt 0 ] && return 0
    done
    printf '  原因：没有可用的屏幕背光设备（/sys/class/backlight 为空或 max_brightness=0）\n' >&2
    return 1
}

# 桌面小组件输出：Noctalia 配置里的每个 output 名字必须能在 /sys/class/drm
# 找到且已连接。写死 Virtual-1 在 M2 真机（eDP）上只会不显示或错位（D3-1）；
# 不写 output（走默认输出）视为通过。
widgets() {
    _config=${XDG_CONFIG_HOME:-"$HOME/.config"}/noctalia/config.toml
    if [ ! -r "$_config" ]; then
        printf '  待验：找不到 Noctalia 配置（%s）\n' "$_config" >&2
        return 2
    fi
    _connected=
    for _connector in /sys/class/drm/card*-*; do
        [ -r "$_connector/status" ] || continue
        [ "$(cat "$_connector/status" 2>/dev/null)" = connected ] || continue
        _name=${_connector##*/card}
        _connected="$_connected ${_name#*-}"
    done
    _missing=
    while IFS= read -r _output; do
        [ -n "$_output" ] || continue
        case " $_connected " in
            *" $_output "*) ;;
            *) _missing="$_missing $_output" ;;
        esac
    done <<EOF
$(sed -n 's/^[[:space:]]*output[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$_config" 2>/dev/null)
EOF
    if [ -n "$_missing" ]; then
        printf '  原因：小组件引用了未连接/不存在的输出：%s（默认输出请省略 output 键）\n' "$_missing" >&2
        return 1
    fi
    return 0
}

battery() {
    for supply in /sys/class/power_supply/*; do
        [ -r "$supply/type" ] && [ "$(cat "$supply/type")" = Battery ] || continue
        [ -r "$supply/capacity" ] && [ -r "$supply/status" ] || return 1
        case "$(cat "$supply/status")" in Charging|Discharging|Full|'Not charging') ;; *) return 1 ;; esac
        awk 'NF == 1 && $1 ~ /^[0-9]+$/ && $1 <= 100 { ok=1 } END { exit !ok }' "$supply/capacity"
        return $?
    done
    return 1
}

camera() {
    command -v v4l2-ctl >/dev/null || return 2
    device=
    for video in /sys/class/video4linux/video*; do
        case "$(readlink "$video/device/driver" 2>/dev/null)" in
            */apple-isp) device=/dev/${video##*/}; break ;;
        esac
    done
    [ -n "$device" ] && [ -c "$device" ] || return 1
    if [ "$capture" = --capture-camera ]; then
        timeout 10 v4l2-ctl -d "$device" --stream-mmap=3 --stream-count=3 --stream-to=/dev/null >/dev/null
    else
        v4l2-ctl -d "$device" --get-fmt-video >/dev/null || return 1
        return 2
    fi
}

failed=0
unknown=0
check() {
    label=$1
    if "$2"; then
        printf '通过  %s\n' "$label"
    else
        case $? in
            2) unknown=1; printf '待验  %s\n' "$label" ;;
            *) failed=1; printf '异常  %s\n' "$label" ;;
        esac
    fi
}

# 映射表的第三处消费方：驱动请求名必须真的落在系统里（P1-03）。
# 只按“源文件名存在”验收会让 boot-sync 假绿，这里按请求名逐个核对。
firmware_ready() {
    map=
    for candidate in /opt/ordo/config/platform/m2/wireless-firmware /etc/ordo/wireless-firmware; do
        [ -r "$candidate" ] && { map=$candidate; break; }
    done
    if [ -z "$map" ]; then
        printf '  待验：找不到 wireless-firmware 映射表，无法核对请求名\n' >&2
        return 2
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%%#*}
        case "$line" in
            *[![:space:]]*) ;;
            *) continue ;;
        esac
        # shellcheck disable=SC2086 # 映射用空白分隔
        set -- $line
        shift
        for wanted in "$@"; do
            if [ ! -s "/lib/firmware/vendorfw/$wanted" ] && [ ! -s "/lib/firmware/$wanted" ]; then
                printf '  原因：缺少驱动请求名对应的固件：%s\n' "$wanted" >&2
                return 1
            fi
        done
    done < "$map"
    return 0
}

wireless() {
    firmware_ready || return $?
    radio=
    for node in /sys/class/ieee80211/phy*; do
        case "$(readlink "$node/device/driver" 2>/dev/null)" in
            */brcmfmac) radio=$node; break ;;
        esac
    done
    if [ -z "$radio" ]; then
        printf '  原因：没有 brcmfmac 注册的无线网卡（固件没被请求到）\n' >&2
        return 1
    fi
    # 固件请求失败后 brcmfmac 不会重试，只有内核日志能证明它真的起来了（P1-03）。
    if ! kernel_log=$(dmesg 2>/dev/null) || [ -z "$kernel_log" ]; then
        printf '  待验：读不到内核日志（dmesg），无法排除固件请求失败\n' >&2
        return 2
    fi
    # 板型后缀链（-TPHN-u-4.7-X2 → … → -TPHN）逐条 -2 是正常探测序列：
    # 内核最后会加载无后缀的兜底名 apple,hokkaido{.bin,.txt,.clm_blob}。
    # 真机 dmesg 里这些兜底名加载成功、Wi-Fi 正常；只有兜底名也 -2 才是坏。
    if printf '%s\n' "$kernel_log" |
       grep -Eq 'brcmfmac.*apple,hokkaido\.(bin|txt|clm_blob).*failed with error -2'; then
        printf '  原因：内核日志记录兜底固件 apple,hokkaido.* 请求失败（error -2）\n' >&2
        return 1
    fi
    return 0
}

bluetooth() {
    for adapter in /sys/class/bluetooth/hci[0-9]*; do
        case ${adapter##*/} in *:*) continue ;; esac
        [ -d "$adapter" ] && return 0
    done
    return 1
}

input() {
    grep -Fxl 'Apple MTP keyboard' /sys/class/input/input*/name >/dev/null 2>&1 &&
        grep -Fxl 'Apple MTP multi-touch' /sys/class/input/input*/name >/dev/null 2>&1
}

if [ "$capture" = --resume ]; then
    # 唤醒后只复检这三项：GPU/EGL 与电池状态由合成器和 UPower 自己恢复，
    # eglinfo 在 resume 后常因 DRM 节点重枚举给出假红（D0-2）。
    check 'Broadcom 无线网卡已注册' wireless
    check 'J413 扬声器保护、扬声器 DSP 和麦克风 DSP' audio
    check '内置键盘和触控板已注册' input
else
    check '内屏已连接到 Apple DRM' display
    check 'Broadcom 无线网卡已注册' wireless
    check '蓝牙控制器已注册' bluetooth
    check '内置键盘和触控板已注册' input
    check 'Umbriel 会话和 Mesa Wayland EGL 使用 AGX' gpu
    check 'J413 扬声器保护、扬声器 DSP 和麦克风 DSP' audio
    check 'UPower 可访问键盘背光' keyboard
    check '屏幕背光设备可用于亮度调节' backlight
    check '电池状态和容量' battery
    check '桌面小组件输出在已连接的显示器上' widgets
    # 摄像头默认不参与例行检查：apple-isp 还没进 platform-modules，恒红会把
    # 真异常和“未支持”混在一起（D2-1）。显式 --capture-camera 时才读取三帧。
    if [ "$capture" = --capture-camera ]; then
        check '内置摄像头读取帧' camera
    fi
fi
[ "$failed" = 0 ] || exit 1
[ "$unknown" = 0 ] || exit 2
