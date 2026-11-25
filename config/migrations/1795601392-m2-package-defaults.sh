#!/bin/sh
set -eu
compatible=/proc/device-tree/compatible
if [ -r "$compatible" ] && tr '\000' '\n' < "$compatible" | grep -Fxq apple,j413; then
    here=$(dirname "$(readlink -f "$0")")
    python3 "$here/../platform/m2/repair-package-defaults.py"
fi
