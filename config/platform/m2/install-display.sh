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

# modules.dep 必须只索引实际存在的模块：覆盖层里被删掉的 .ko 若还留在依赖表里，
# modprobe 会按死路径加载失败（介质上曾出现 1010 条不存在的路径，P1-01）。
pruned=$(mktemp "$tree/.modules.dep.XXXXXX")
trap 'rm -f "$pruned"' EXIT
: > "$pruned"
dead=0
while IFS= read -r line; do
    module=${line%%.ko:*}
    module=$module.ko
    if [ -f "$tree/$module" ]; then
        printf '%s\n' "$line" >> "$pruned"
    else
        dead=$((dead + 1))
    fi
done < "$tree/modules.dep"
mv -f "$pruned" "$tree/modules.dep"
trap - EXIT
if [ "$dead" -gt 0 ]; then
    printf '模块索引已按实际成员重建：移除 %s 条失效路径\n' "$dead" >&2
fi
