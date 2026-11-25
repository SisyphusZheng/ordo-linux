#!/bin/sh
# 门禁：OneConfig 用符号链接部署，不是拷贝
#
# 语义：改仓库里的配置文件，用户配置目录立即反映，无需重新 apply。
# 若用 cp，就会出现两份副本 —— 那就不是 OneConfig。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

case_name "apply 使用符号链接"

_apply="$(sed -n '/^_apply_desktop/,/^}/p' "$ROOT/scripts/ordo-config")"
assert_contains "$_apply" "ln -sfn" "用 ln -sfn 建链"

case_name "部署后软链指向仓库"

_tmp="$(mktemp -d "${TMPDIR:-/tmp}/ordo-link.XXXXXX")"
trap 'rm -rf "$_tmp"' EXIT

HOME="$_tmp" XDG_CONFIG_HOME="$_tmp/.config" sh "$ROOT/scripts/ordo-config" apply desktop >/dev/null 2>&1

for f in umbriel/config.toml noctalia/config.toml ordo/keys.md; do
    _p="$_tmp/.config/$f"
    if [ -L "$_p" ]; then
        _tgt="$(readlink "$_p")"
        case "$_tgt" in
            "$ROOT"*) assert_rc 0 0 "$f 是指向仓库的软链" ;;
            *) assert_eq "$_tgt" "(仓库内路径)" "$f 软链目标在仓库内" ;;
        esac
    else
        assert_rc 1 0 "$f 应为软链"
    fi
done

case_name "改仓库文件立即反映到已部署路径"

cp -R "$ROOT/config" "$_tmp/source"
ORDO_CONF_DIR="$_tmp/source" HOME="$_tmp" XDG_CONFIG_HOME="$_tmp/.config" \
    sh "$ROOT/scripts/ordo-config" apply desktop >/dev/null
printf '\n<!-- probe -->\n' >> "$_tmp/source/desktop/keys.md"
assert_contains "$(cat "$_tmp/.config/ordo/keys.md")" "probe" "软链端立即看到声明改动"

case_name "已有目录挡住目标链接时，部署失败"
mkdir -p "$_tmp/blocked/luciole/config.toml"
out=$(HOME="$_tmp" XDG_CONFIG_HOME="$_tmp/blocked" \
    sh "$ROOT/scripts/ordo-config" apply desktop 2>&1)
assert_rc "$?" 1 "部署失败必须返回 1"
assert_contains "$out" "创建软链失败" "输出指出失败位置"
assert_not_contains "$out" "已链接" "失败路径不打印成功汇总"

case_name "软链目标必须对目标用户可读"

# 【真实事故 2026-11-22】install.sh 用 cp 部署 config，把源文件的 0600 权限
# 带了过去。ordo-config 把 ~/.config/umbriel/config.toml 软链到 /opt/ordo/config，
# 结果 Umbriel 启动报 "config.toml File could not be opened for reading"。
_install="$(cat "$ROOT/install.sh")"
assert_contains "$_install" "chmod -R a+rX /opt/ordo/config" \
    "install.sh 保证 config 对所有人可读"

case_name "键位说明已入库"

assert_rc "$([ -f "$ROOT/config/desktop/keys.md" ] && echo 0 || echo 1)" 0 "keys.md 存在"

finish
