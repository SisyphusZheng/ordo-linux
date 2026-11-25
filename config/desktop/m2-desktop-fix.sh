#!/bin/sh
# Deploy desktop settings for the M2 installation in the target chroot.
set -eu
here=$(dirname "$(readlink -f "$0")")

install -Dm644 "$here/99imm" /etc/env.d/99imm
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
