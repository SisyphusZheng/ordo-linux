#!/bin/sh
# UPower mediates access to the keyboard LED for this session.
set -eu

case "${1:-}" in
    up) direction=1 ;;
    down) direction=-1 ;;
    *) exit 2 ;;
esac

kbd_call() {
    method=$1
    shift
    gdbus call --system --dest org.freedesktop.UPower \
        --object-path /org/freedesktop/UPower/KbdBacklight --timeout 2 \
        --method "org.freedesktop.UPower.KbdBacklight.$method" "$@"
}

max=$(kbd_call GetMaxBrightness) || exit 2
current=$(kbd_call GetBrightness) || exit 2
max=$(printf '%s\n' "$max" | sed -n 's/^(\([0-9][0-9]*\),)$/\1/p')
current=$(printf '%s\n' "$current" | sed -n 's/^(\([0-9][0-9]*\),)$/\1/p')
[ -n "$max" ] && [ "$max" -gt 0 ] && [ -n "$current" ] || exit 2

step=$(((max + 9) / 10))
new=$((current + direction * step))
[ "$new" -ge 0 ] || new=0
[ "$new" -le "$max" ] || new=$max
kbd_call SetBrightness "$new" >/dev/null
