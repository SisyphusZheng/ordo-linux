#!/bin/sh
# 门禁：桌面配置聚合在 config/desktop/，布局为 Noctalia 全家桶
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

case_name "桌面目录结构"

for d in umbriel noctalia greetd wallpapers skel; do
    assert_rc "$([ -d "$ROOT/config/desktop/$d" ] && echo 0 || echo 1)" 0 "config/desktop/$d 存在"
done

case_name "旧栈目录已不存在"

for old in niri themes lavalauncher animations; do
    assert_rc "$([ -e "$ROOT/config/desktop/$old" ] && echo 1 || echo 0)" 0 \
        "config/desktop/$old 已移除"
done

case_name "README 与实物一致"

_readme="$ROOT/config/desktop/README.md"
assert_rc "$([ -f "$_readme" ] && echo 0 || echo 1)" 0 "README 存在"

for kw in "五个组件" "唯一真相来源" "配色" "改完怎么生效" "已知限制"; do
    assert_contains "$(cat "$_readme")" "$kw" "README 含「${kw}」"
done

_missing=""
for f in umbriel/config.toml noctalia/config.toml greetd/config.toml \
         greetd/greetd.initd ordo-session-env keys.md; do
    [ -e "$ROOT/config/desktop/$f" ] || _missing="$_missing $f"
done
assert_eq "$_missing" "" "README 提到的文件都存在"

case_name "无残留旧栈路径引用"

_stale="$(cd "$ROOT" && grep -rn 'config/desktop/niri\|config/desktop/themes\|config/desktop/lavalauncher' \
    install.sh scripts/ docs/ 2>/dev/null | head -3)"
assert_eq "$_stale" "" "无指向旧栈目录的引用"

case_name "README 说明了部署与验收命令"

assert_contains "$(cat "$_readme")" "ordo config apply desktop" "说明部署命令"
assert_contains "$(cat "$_readme")" "ordo config verify" "说明验收命令"

finish
