#!/bin/sh
# Shared world declaration. The caller supplies the config directory and platform.
ordo_world() {
    case "$2" in
        m2) set -- "$1/world" "$1/platform/m2/world.base" ;;
        m2-native) set -- "$1/world" "$1/platform/m2/world.base" "$1/platform/m2/world" ;;
        vm) set -- "$1/world" ;;
        bare-metal) set -- "$1/world" "$1/world.bare-metal" ;;
        *) return 2 ;;
    esac
    LC_ALL=C awk '
        { sub(/#.*/, ""); if (NF > 1) invalid=1; if (NF && !seen[$1]++) print $1 }
        END { if (invalid) exit 1 }
    ' "$@"
}

ordo_platform() {
    if [ -r /etc/ordo/platform ]; then
        cat /etc/ordo/platform
    elif [ -e /etc/ordo/platform ]; then
        return 2
    elif [ -r /proc/device-tree/compatible ] && tr '\000' '\n' < /proc/device-tree/compatible | grep -Fxq apple,j413; then
        printf '%s\n' m2
    elif [ -e /etc/portage/package.use/real-hardware ]; then
        printf '%s\n' bare-metal
    else
        printf '%s\n' vm
    fi
}
