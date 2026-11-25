#!/bin/sh
# 回归：P1-1..4 假绿灯 —— 「查不到」绝不能输出绿勾
#
# 曾经：findmnt 缺失 → verify 打印「✔ 一致」；ashell 配置缺失 →
# ordo-theme 打印「✔ 全组件颜色一致」；/var/lib/portage/world 不可读 →
# doctor 打印「✔ world 无应用级大件」。三处都在开发机上可复现。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fakebin.sh"

case_name "P1-1 verify 在 findmnt 缺失时不得报一致"

# 用一个空 PATH 目录让 findmnt 不可见，但保留基本工具
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ordo-fg.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"; mkdir -p "$bin"
for t in sh awk sed grep sort comm mktemp rm cat dirname basename readlink tr wc; do
    p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$bin/$t"
done

out="$(PATH="$bin" sh "$ROOT/scripts/ordo-config" verify 2>&1)"; rc=$?
assert_rc "$rc" 2 "findmnt 缺失时退出码为 2（无法判定）"
assert_contains "$out" "无法判定" "输出了「无法判定」"
assert_not_contains "$out" "一致" "不输出「一致」"

case_name "P1-2 桌面配置未部署时不得报通过"

# 用一个空的 HOME：~/.config/umbriel/config.toml 不存在，
# verify 必须报「无法判定」而不是「有效」。
fakehome="$tmp/home"; mkdir -p "$fakehome"
out="$(HOME="$fakehome" XDG_CONFIG_HOME="$fakehome/.config" \
       sh "$ROOT/scripts/ordo-config" verify 2>&1)"; rc=$?
assert_rc "$rc" 2 "配置全缺时退出码为 2"
# 开发机上 umbriel 二进制不存在 → 报「命令不可用」；
# 装了 umbriel 但没部署配置 → 报「未部署」。两者都必须标明「不是通过」。
assert_contains "$out" "不是通过" "明确标注无法判定"
assert_not_contains "$out" "Umbriel 配置有效" "不输出「配置有效」"

case_name "P1-3 doctor 在 world 不可读时不得报无越界"

out="$(sh "$ROOT/scripts/doctor" 2>&1)"; rc=$?
# 开发机上 /var/lib/portage/world 不存在
assert_not_contains "$out" "✔ world 无应用级大件" "不输出「world 无应用级大件」"
assert_contains "$out" "无法检查应用层边界" "明确说明无法检查"
# doctor 有真问题（niri/flatpak 等不在开发机上）→ 1；纯无法判定才是 2
case "$rc" in
    1|2) assert_rc "$rc" "$rc" "退出码为 1 或 2（不是 0）" ;;
    *)   assert_rc "$rc" "1|2" "退出码为 1 或 2（不是 0）" ;;
esac

finish
