#!/bin/sh
# Install the indices and display modules built for the kernel on the M2 media.
set -eu
tree=${1:?module directory}
overlay=${2:?display module archive}
test -f "$tree/extra/zfs.ko"
tar -xzf "$overlay" -C "$tree"
while IFS= read -r builtin; do
    case "$builtin" in kernel/*.ko) ;; *) exit 1 ;; esac
    if [ -f "$tree/$builtin" ]; then rm -f "$tree/$builtin"; fi
done < "$tree/modules.builtin"
