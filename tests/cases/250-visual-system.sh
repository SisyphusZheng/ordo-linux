#!/bin/sh
# 门禁：视觉体系接线（配色 → 顶栏/桌面小组件 → 模板 → 合成器/终端）
#
# 2026-11-22：视觉契约从「macOS 岛式」切换为「复刻 noctalia v5 介绍视频
# （BV1suMc6vEam）」：通栏顶栏 + 音频频谱 + 桌面小组件 + Dock 停用 +
# 黑洞星环壁纸。此前断言 corner_radius=32 / opacity=0.55 与声明（22 / 0.88）
# 已经漂移，本次一并校准。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

_no="$ROOT/config/desktop/noctalia/config.toml"
_um="$ROOT/config/desktop/umbriel/config.toml"
_cfg="$(cat "$_no")"

case_name "配色：壁纸驱动 + 纯黑"

assert_contains "$_cfg" 'source = "wallpaper"' "配色来源是壁纸"
assert_contains "$_cfg" 'pure_black_dark = true' "暗色表面钉到纯黑"

# 自定义调色板在 5.6.0 下不可用（对所有路径都报 not found 并静默回退）
# 注释里可以提它作为反例，实际取值不能是 custom
_actual_src="$(grep -E '^source *=' "$_no" | head -1)"
assert_not_contains "$_actual_src" 'custom' "实际不用不可靠的 custom 源"
assert_not_contains "$_cfg" 'm3-fruit-salad' "不用多色乱配算法"

case_name "视频同款：黑洞星环壁纸（可复现生成）"

assert_contains "$_cfg" 'wallpaper-blackhole.png' "默认壁纸指向黑洞星环"
assert_rc "$([ -f "$ROOT/config/desktop/wallpapers/gen-blackhole.py" ] && echo 0 || echo 1)" 0 \
    "壁纸由生成脚本产出（可 diff 可复现）"
assert_rc "$([ -f "$ROOT/config/desktop/wallpapers/wallpaper-blackhole.png" ] && echo 0 || echo 1)" 0 \
    "生成的 PNG 在仓库内"

case_name "视频同款：通栏顶栏 + 音频频谱"

assert_contains "$_cfg" '[bar.main]' "配了 bar.main（不是 shell.panel）"
assert_contains "$_cfg" 'margin_ends = 0' "通栏贴边（不再是岛）"
assert_contains "$_cfg" 'radius = 0' "通栏无圆角"
assert_contains "$_cfg" 'capsule = false' "整条栏一个面板"
# 视频中段：时钟 + 天气 + 窗口标题 + 媒体 + 频谱
# （factory 注册名是下划线 active_window；文档页名是连字符，不可照抄）
assert_contains "$_cfg" \
    'center = ["clock", "weather", "active_window", "media", "audio-vis"]' \
    "中段 widget 编排与视频一致"
assert_contains "$_cfg" '[widget.audio-vis]' "有音频频谱 widget 声明"
assert_contains "$_cfg" 'type = "audio_visualizer"' "频谱类型正确"
assert_contains "$_cfg" 'show_wave = true' "平滑波形而非离散柱"

case_name "视频同款：桌面小组件铺桌面"

assert_contains "$_cfg" '[desktop_widgets]' "有桌面小组件段"
assert_contains "$_cfg" 'schema_version = 2' "schema 版本显式声明"
assert_contains "$_cfg" 'widget_order' "widget 清单显式声明"
for t in '"clock"' '"media_player"' '"weather"' '"sysmon"'; do
    assert_contains "$_cfg" "type = $t" "小组件类型 $t"
done

case_name "视频同款：Dock 停用（参数保留可一键回开）"

assert_contains "$_cfg" '[dock]' "有 dock 段"
_dock="$(sed -n '/^\[dock\]/,/^\[shell\.panel\]/p' "$_no")"
assert_contains "$_dock" 'enabled = false' "dock 已停用"
assert_contains "$_dock" 'magnification = true' "放大参数保留"

case_name "毛玻璃与高斯模糊"

assert_contains "$_cfg" 'compositor_blur = true' "顶栏/Dock 走合成器模糊"
assert_contains "$_cfg" 'transparency_mode = "glass"' "浮层为 glass"
assert_contains "$_cfg" '[backdrop]' "有背景模糊段"
assert_contains "$_cfg" 'blur_intensity' "背景模糊强度"
assert_contains "$_cfg" 'blurred_desktop = true' "锁屏用桌面快照"

case_name "模板：用 Noctalia 官方内置模板"

# 官方在 /usr/share/noctalia/assets/templates/builtin.toml 里注册了 21 个模板，
# 每个自带 input_path / output_path / post_hook，不需要我们手写路径。
assert_contains "$_cfg" '[theme.templates]' "有模板配置段"
assert_contains "$_cfg" 'enable_builtin_templates = true' "启用内置模板"
for id in umbriel wezterm luciole gtk3 gtk4 qt; do
    assert_contains "$_cfg" "\"$id\"" "启用 $id 模板"
done
# 自写模板已删除：官方模板覆盖了同样的组件
assert_rc "$([ -d "$ROOT/config/desktop/noctalia/templates" ] && echo 1 || echo 0)" 0 \
    "不再自带 templates 目录"

case_name "合成器加载生成的颜色"

assert_contains "$(cat "$_um")" '[include.optional]' "umbriel 有可选 include"
assert_contains "$(cat "$_um")" 'noctalia.toml' "包含官方模板产物"

case_name "终端用官方色名而非自写配色"

_wz0="$(cat "$ROOT/config/desktop/skel/.config/wezterm/wezterm.lua")"
assert_contains "$_wz0" "color_scheme = 'Noctalia'" "声明 Noctalia 色名"
assert_not_contains "$_wz0" 'colors.lua' "不再加载自写配色文件"

case_name "终端不硬编码颜色"

_wz="$(cat "$ROOT/config/desktop/skel/.config/wezterm/wezterm.lua")"
# 硬编码会覆盖模板值
assert_not_contains "$_wz" "background = '#0a0e0a'" "不再硬编码终端底色"

case_name "2K 输出与全圆角"

_umcfg="$(cat "$_um")"
# Virtual-1 通告的模式里没有 2560x1440，Umbriel 当自定义模式尝试
assert_contains "$_umcfg" '[output.Virtual-1]' "配置了输出分辨率"
assert_contains "$_umcfg" 'mode = "2560x1440@60"' "2K 分辨率"
# 没有直角（声明值 22，2026-11-22 校准——旧断言 32 与声明漂移）
assert_contains "$_umcfg" 'corner_radius = 22' "合成器全局圆角 22"
assert_not_contains "$_umcfg" 'corner_radius = 0' "不出现直角"

case_name "终端透明由合成器承担"

# wezterm 自己的 window_background_opacity 在 Umbriel 下实测不生效，
# 透明必须写在窗口规则里（声明值 0.88，2026-11-22 校准——旧断言 0.55 漂移）
assert_contains "$_umcfg" 'opacity = 0.88' "终端窗口透明度在合成器侧"
assert_contains "$_umcfg" 'match.app_id = "^org\\.wezfurlong\\.wezterm$"' "规则匹配终端 app_id"
assert_contains "$_umcfg" 'blur = true' "终端背后高斯模糊"

case_name "Luciole 基础配置"
_lc="$ROOT/config/desktop/luciole/config.toml"
assert_rc "$([ -f "$_lc" ] && echo 0 || echo 1)" 0 "luciole 基础配置存在"
_lct="$(cat "$_lc")"
assert_contains "$_lct" 'schema_version' "有 schema_version"
assert_contains "$_lct" 'corner_radius_scale' "放大圆角"
assert_contains "$_lct" 'use_ssd = true' "让合成器画装饰（统一圆角）"

case_name "部署不再需要模板目录"

_apply="$(sed -n '/^_apply_desktop/,/^}/p' "$ROOT/scripts/ordo-config")"
assert_not_contains "$_apply" 'for _sub in palettes templates' \
    "不再软链 templates（改用官方内置模板）"

finish
