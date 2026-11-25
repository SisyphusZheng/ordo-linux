#!/bin/sh
# Run as the logged-in Wayland user on a MacBook Air M2 (J413).
set -u

case "${1:-}" in ''|--capture-camera|--session-report) ;; *) exit 2 ;; esac
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
        timeout 45 sh "$(readlink -f "$0")" || report_status=$?
        case "$report_status" in 0|1|2) ;; *) report_status=2 ;; esac
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
    [ -n "$render" ] && [ -c "$render" ] || return 1
    command -v eglinfo >/dev/null && [ -n "${WAYLAND_DISPLAY:-}" ] || return 2
    egl=$(eglinfo -B 2>/dev/null) || [ -n "$egl" ] || return 2
    printf '%s\n' "$egl" | awk '
        /^Wayland platform:/ { wayland=1; next }
        /platform:$/ { wayland=0 }
        wayland && $0 ~ /EGL driver name: asahi/ { found=1 }
        END { exit !found }
    ' || return 1
    pid=$(pgrep -u "$(id -u)" -x umbriel) || return 2
    [ -r "/proc/$pid/environ" ] || return 2
    tr '\000' '\n' < "/proc/$pid/environ" | grep -Fxq "WLR_RENDER_DRM_DEVICE=$render"
}

audio() {
    pgrep -u speakersafetyd -x speakersafetyd >/dev/null 2>&1 || return 1
    command -v amixer >/dev/null && command -v pw-dump >/dev/null || return 2
    controls=$(amixer -c AppleJ413 controls 2>/dev/null) || return 2
    lock=$(printf '%s\n' "$controls" | sed -n "s/^numid=\([0-9][0-9]*\),.*name='Speaker Volume Unlock'$/\1/p")
    [ -n "$lock" ] || return 1
    state=$(amixer -c AppleJ413 cget "numid=$lock" 2>/dev/null) || return 2
    printf '%s\n' "$state" | grep -Eq '^[[:space:]]*: values=1$' || return 1
    routes=$(pw-dump 2>/dev/null) || return 2
    printf '%s\n' "$routes" | grep -Fq '"node.name": "audio_effect.j413-convolver"' &&
        printf '%s\n' "$routes" | grep -Fq '"node.name": "effect_output.j413-mic"'
}

keyboard() {
    command -v gdbus >/dev/null || return 2
    level=$(gdbus call --system --dest org.freedesktop.UPower --timeout 2 \
        --object-path /org/freedesktop/UPower/KbdBacklight \
        --method org.freedesktop.UPower.KbdBacklight.GetMaxBrightness 2>/dev/null) || return 1
    printf '%s\n' "$level" | grep -Eq '^\([1-9][0-9]*,\)$'
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

wireless() {
    for radio in /sys/class/ieee80211/phy*; do
        case "$(readlink "$radio/device/driver" 2>/dev/null)" in */brcmfmac) return 0 ;; esac
    done
    return 1
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

check '内屏已连接到 Apple DRM' display
check 'Broadcom 无线网卡已注册' wireless
check '蓝牙控制器已注册' bluetooth
check '内置键盘和触控板已注册' input
check 'Umbriel 会话和 Mesa Wayland EGL 使用 AGX' gpu
check 'J413 扬声器保护、扬声器 DSP 和麦克风 DSP' audio
check 'UPower 可访问键盘背光' keyboard
check '电池状态和容量' battery
check '内置摄像头读取帧（需 --capture-camera）' camera
[ "$failed" = 0 ] || exit 1
[ "$unknown" = 0 ] || exit 2
