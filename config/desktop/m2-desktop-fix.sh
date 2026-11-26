#!/bin/sh
# Deploy desktop settings for the M2 installation in the target chroot.
set -eu
here=$(dirname "$(readlink -f "$0")")

install -Dm644 "$here/99imm" /etc/env.d/99imm
# 门户后端选择（C2）：系统级先落一份；登录时会话入口还会写用户级副本。
# 落位失败只告警：doctor 会报缺 portals.conf，不能让 chroot 收尾整体失败。
install -Dm644 "$here/portals.conf" /etc/xdg-desktop-portal/portals.conf 2>/dev/null \
    || printf '%s\n' 'm2-desktop-fix: 无法部署 /etc/xdg-desktop-portal/portals.conf（doctor 会报缺件）' >&2
env-update

# This installer runs the same Asahi kernel as the target.
# An absent configuration cannot establish that the service is unsupported.
if [ -r /proc/config.gz ] &&
   gzip -dc /proc/config.gz | grep -Fx '# CONFIG_BINFMT_MISC is not set' >/dev/null; then
    for service in /etc/runlevels/*/binfmt; do
        [ -L "$service" ] || continue
        runlevel=${service%/*}
        rc-update del binfmt "${runlevel##*/}"
    done
fi
