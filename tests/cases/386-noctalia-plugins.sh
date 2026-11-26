#!/bin/sh
# 回归：C5 Noctalia 插件降级与 storage-key 处置
#
# D3-2：插件源在离线/受限网络下不可达，bar 里硬挂 community 插件只会得到
# 一个无法实例化的 widget；通知历史的 storage key 文件缺失时 Noctalia 每次
# 启动都报 [storage-key] failed。
#
# 本用例锁住可闭环的部分：插件不硬挂、配置仍可解析、08 手册给出可执行步骤；
# key 文件本身的生成依赖上游公开键名（见报告 blocked/部分）。
set -eu
repo=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)
. "$repo/tests/lib/assert.sh"

case_name "Noctalia 配置可解析"

PYTHONDONTWRITEBYTECODE=1 python3 - "$repo/config/desktop/noctalia/config.toml" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    tomllib.load(f)
print("  ok   config.toml 是合法 TOML")
PY

case_name "C5 番茄钟插件不硬挂"

PYTHONDONTWRITEBYTECODE=1 python3 - "$repo/config/desktop/noctalia/config.toml" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    cfg = tomllib.load(f)
bar = cfg.get("bar", {}).get("main", {})
end = bar.get("end", [])
assert "thepunkoff/pomodoro:widget" not in end, f"bar.main.end 仍硬挂插件：{end}"
plugins = cfg.get("plugins", {})
enabled = plugins.get("enabled")
assert enabled == [], f"[plugins].enabled 应为空（离线降级）：{enabled!r}"
# 插件仍然可被显式启用：配置里保留开关说明，而不是把插件彻底删除。
text = open(sys.argv[1], encoding="utf-8").read()
assert "thepunkoff/pomodoro" in text, "配置需保留联网后手动启用的说明"
assert "离线" in text or "联网" in text, "注释需说明离线降级/联网启用"
print("  ok   bar 不硬挂、plugins.enabled 为空、保留启用说明")
PY

case_name "C5 08 手册给出 storage-key 的可执行步骤"

manual="$(cat "$repo/docs/manual/08-troubleshooting.md")"
assert_contains "$manual" "[storage-key] failed to open configured storage key file" \
    "08 引用真实日志签名"
assert_contains "$manual" "notification_history.enc" "08 指明历史文件"
assert_contains "$manual" "仓库不猜键名" "08 明确不猜上游键名"
assert_contains "$manual" "~/.cache/noctalia/noctalia.log" "08 给出验收日志路径"

finish
