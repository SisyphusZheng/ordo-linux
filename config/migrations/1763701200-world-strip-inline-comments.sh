#!/bin/sh
# world 去注释化（评审 P1-4）
#
# 旧版本的 config/world 带 31 条行内注释，install.sh 会原样 cp 进
# /var/lib/portage/world。Portage 不认行内注释，且 verify 会报
# 31 extra + 31 missing 的幻影漂移。
#
# 本迁移把已装机系统的 world 重写成裸 atom 列表。
set -eu

WORLD=/var/lib/portage/world
[ -f "$WORLD" ] || exit 0

# 备份一次（只备份一份，重复执行不覆盖）
[ -f "$WORLD.pre-ordo-migrate" ] || cp "$WORLD" "$WORLD.pre-ordo-migrate"

_tmp="$(mktemp)"
sed -e 's/#.*//' "$WORLD" | awk 'NF { print $1 }' | sort -u > "$_tmp"

if cmp -s "$_tmp" "$WORLD"; then
    rm -f "$_tmp"
    exit 0
fi

cp "$_tmp" "$WORLD"
rm -f "$_tmp"
echo "已重写 $WORLD（剥除行内注释并去重）"
