#!/bin/sh
# 回归：发布源码锚点必须与 overlay 配方、Manifest 三方一致
#
# P1-02：Luciole 二进制事后无法锚回源码 commit；这里把版本号、提交与
# distfile 名绑定，任一处漂移都会红。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

_eb="$ROOT/overlay/gui-apps/luciole/luciole-0.1.0.ebuild"
_src="$ROOT/config/release/0.1.0/SOURCES"
_man="$ROOT/overlay/gui-apps/luciole/Manifest"

case_name "源码锚点随发布清单入库"

assert_rc "$([ -f "$_src" ] && echo 0 || echo 1)" 0 "SOURCES 存在"

_eb_commit="$(sed -n 's/^LUCIOLE_COMMIT="\([a-f0-9]\{40\}\)"$/\1/p' "$_eb")"
_src_commit="$(sed -n 's/^luciole_commit=\([a-f0-9]\{40\}\)$/\1/p' "$_src")"
_src_dist="$(sed -n 's/^luciole_distfile=\(.*\)$/\1/p' "$_src")"
_man_dist="$(sed -n 's/^DIST \([^ ]*\) .*/\1/p' "$_man")"

assert_rc "$([ -n "$_eb_commit" ] && echo 0 || echo 1)" 0 "ebuild 固定完整提交"
assert_eq "$_src_commit" "$_eb_commit" "SOURCES 的提交与 ebuild 一致"
assert_eq "$_src_dist" "$_man_dist" "SOURCES 的 distfile 与 Manifest 一致"

case_name "提交与 distfile 名互相对应"

assert_eq "$_man_dist" "luciole-0.1.0-${_eb_commit}.tar.gz" "distfile 名带完整提交"

finish
