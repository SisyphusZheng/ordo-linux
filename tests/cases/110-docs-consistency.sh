#!/bin/sh
# 回归：文档里提到的脚本/文件必须真实存在
#
# 曾经：README 的目录树列了不存在的 config/etc/；
# 安装指南让人设 ORDO_REAL_HARDWARE（代码里根本没这个变量）；
# ADR 0008 教人跑 `ordo config apply kde`（目录已删）。
# 这一条把「文档是否可执行」变成机器检查。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

case_name "所有文档引用的 scripts/ 文件都存在"

missing=""
for doc in "$ROOT"/README.md "$ROOT"/AGENTS.md "$ROOT"/CONTRIBUTING.md \
           "$ROOT"/docs/*.md "$ROOT"/docs/manual/*.md "$ROOT"/docs/decisions/*.md; do
    [ -f "$doc" ] || continue
    # 抓形如 sh scripts/xxx 或 ./scripts/xxx 或 scripts/xxx 的引用
    for ref in $(grep -oE '(sh |\./)?scripts/[a-z][a-z0-9-]*' "$doc" 2>/dev/null \
                 | sed -e 's/^sh //' -e 's|^\./||' | sort -u); do
        [ -e "$ROOT/$ref" ] || missing="$missing $(basename "$doc"):$ref"
    done
done
assert_eq "$missing" "" "没有指向不存在脚本的引用"

case_name "文档里的 make 目标都存在"

targets="$(grep -oE 'make [a-z-]+' "$ROOT"/README.md "$ROOT"/AGENTS.md "$ROOT"/CONTRIBUTING.md \
           "$ROOT"/docs/manual/*.md 2>/dev/null | awk '{print $2}' | sort -u)"
bad_targets=""
for t in $targets; do
    grep -qE "^$t:" "$ROOT/Makefile" || bad_targets="$bad_targets $t"
done
assert_eq "$bad_targets" "" "make 目标都在 Makefile 里"

case_name "文档里的环境变量都在代码里被读取"

bad_var=""
for v in ORDO_ARCH ORDO_PLATFORM ORDO_USER_PASSWORD ORDO_ROOT_PASSWORD \
         ORDO_DOAS_NOPASS ORDO_SSH ORDO_STAGE3_GPG_FPR; do
    # 变量可能由 install.sh 直接读，也可能由 config/arch（被 install.sh source）读
    grep -q "$v" "$ROOT/install.sh" "$ROOT/config/arch" 2>/dev/null || bad_var="$bad_var $v"
done
assert_eq "$bad_var" "" "安装器读取了文档承诺的所有环境变量"

bad_var=""
case_name "README 目录树里提到的目录都存在"

for d in config/arch config/dataset config/apps.d config/migrations \
         config/desktop/noctalia config/desktop/umbriel config/desktop/greetd \
         config/desktop/wallpapers config/package.use config/desktop/skel \
         scripts tests docs/decisions docs/manual; do
    [ -e "$ROOT/$d" ] || bad_var="$bad_var $d"
done
assert_eq "${bad_var:-}" "" "README 列出的目录真实存在"

case_name "已删除的模块不再出现在文档命令里"

bad_doc=""
for stale in 'apply kde' 'ordo rollback' 'ORDO_REAL_HARDWARE' \
             'Mod+Space' '中文 GDM' 'ordo-wallpaper' 'ordo-portal-start' \
             'warehouse-launch' 'nautilus'; do
    hits="$(grep -rln "$stale" "$ROOT"/README.md "$ROOT"/docs/manual "$ROOT"/CONTRIBUTING.md 2>/dev/null)"
    [ -n "$hits" ] && bad_doc="$bad_doc ${stale}→$hits"
done
assert_eq "$bad_doc" "" "用户文档不再教失效命令"

case_name "发布手册包含验签步骤"

assert_contains "$(cat "$ROOT/docs/manual/10-m2-external.md")" "ssh-keygen -Y verify" \
    "M2 手册教 ssh-keygen 验签"
assert_contains "$(cat "$ROOT/docs/manual/10-m2-external.md")" "allowed_signers" \
    "M2 手册给出信任锚"
assert_contains "$(cat "$ROOT/docs/manual/11-utm.md")" "UTM-SHA256SUMS" \
    "UTM 手册给出摘要清单"

case_name "版本号单一来源"

_ver="$(cat "$ROOT/version" 2>/dev/null | tr -d '[:space:]')"
assert_rc "$([ -n "$_ver" ] && echo 0 || echo 1)" 0 "version 文件存在且非空"

# CHANGELOG 最新版本应与 version 一致
_changelog_ver="$(grep -m1 -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$ROOT/CHANGELOG.md" 2>/dev/null | tr -d '[]# ')"
assert_eq "$_changelog_ver" "$_ver" "CHANGELOG 最新版本与 version 一致"

# 代码里不得硬编码版本号
_hard="$(grep -rnE "0\.[0-9]\.[0-9]" "$ROOT/scripts/" 2>/dev/null | grep -v 'readlink' | head -3)"
assert_eq "$_hard" "" "脚本不硬编码版本号"

finish
