#!/bin/sh
# Shared world declaration. The caller supplies the config directory and platform.
# $3 = 架构（config/arch 里的 ARCH）。bare-metal 的 vendor 包按架构分片声明：
# `world.bare-metal` 放架构中立包，`world.bare-metal.$ARCH` 放 vendor 相关包。
# 缺省按 arm64（L1 目标架构）判定，避免把 x86 微码写进 arm64 的 @ordo-core。
ordo_world() {
    _ordo_confdir=$1
    _ordo_arch=${3:-${ORDO_ARCH:-${ARCH:-arm64}}}
    case "$2" in
        m2) set -- "$_ordo_confdir/world" "$_ordo_confdir/platform/m2/world.base" ;;
        m2-native) set -- "$_ordo_confdir/world" "$_ordo_confdir/platform/m2/world.base" "$_ordo_confdir/platform/m2/world" ;;
        vm) set -- "$_ordo_confdir/world" ;;
        bare-metal)
            set -- "$_ordo_confdir/world" "$_ordo_confdir/world.bare-metal"
            if [ -f "$_ordo_confdir/world.bare-metal.$_ordo_arch" ]; then
                set -- "$@" "$_ordo_confdir/world.bare-metal.$_ordo_arch"
            fi
            ;;
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
