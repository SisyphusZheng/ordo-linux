-- Ordo Linux WezTerm 配置
-- 玻璃质感：半透明（GNOME/mutter 无模糊，透明即为上限）
-- 主题与壁纸同源：深蓝底 + 蓝紫渐变

local wezterm = require 'wezterm'
local config = wezterm.config_builder()

-- 配色由 Noctalia 的官方 wezterm 模板管理：
--   渲染 → ~/.config/wezterm/colors/Noctalia.toml
--   apply.sh → 把这个色名写进本文件
-- 色名在这里声明，apply.sh 检测到已正确就不会改本文件
-- （本文件是软链，写它等于改仓库，必须避免）。

-- ============================================================
-- 字体选择：改这一行即可切换（重启 WezTerm 生效）
--   'Fira Code'      连字最完整（calt），字形方正
--   'JetBrains Mono' 连字完整，字形圆润
--   'Cascadia Code'  微软出品，连字+图标
--   'Hack'           无连字，纯等宽，最干净
-- ============================================================
local FONT_FAMILY = 'JetBrainsMono NF'
local LIGATURES = true      -- false 则关闭连字

-- 外观
-- 颜色来自 Noctalia 官方 wezterm 模板渲染的 color scheme（见文件顶部）。
-- 配色方案由 Noctalia 模板渲染（~/.config/wezterm/colors/Noctalia.toml）
config.color_scheme = 'Noctalia'
-- 内边距：文字不贴边
config.window_padding = { left = 16, right = 16, top = 12, bottom = 12 }
-- 不用背景图：透明靠 window_background_opacity + 合成器模糊。

-- 字体：主字体 + 中文 + 图标
local main_font = { family = FONT_FAMILY }
if LIGATURES then
  main_font.harfbuzz_features = { 'calt=1', 'liga=1', 'clig=1' }
end

config.font = wezterm.font_with_fallback {
  main_font,
  { family = 'Noto Sans Mono CJK SC' },
  { family = 'Symbols Nerd Font' },
}
config.font_size = 12.5
if LIGATURES then
  config.harfbuzz_features = { 'calt=1', 'liga=1', 'clig=1' }
end

-- tab bar 已关闭（见下方 enable_tab_bar = false），不再单独配色。

-- Wayland 背景模糊：让合成器把窗口背后的壁纸糊掉，
-- 配合半透明底色才有「毛玻璃」而不是「半透明黑」。
config.wayland_window_background_blur = true

-- 内容区透明：窗口背景取 72% 不透明度，其余靠合成器高斯模糊。
-- 注意：只设不透明度，不要用 rgba() 底色 —— 本机实测 wezterm 的
-- rgba() 渲染不准（rgba(10,14,10,0.5) 渲成 (20,73,32)），
-- #RRGGBBAA 会退化成纯黑。底色保持纯 #RRGGBB，透明度交给这个键。
config.window_background_opacity = 0.55

-- 窗口装饰
config.window_decorations = 'INTEGRATED_BUTTONS|RESIZE'
config.integrated_title_buttons = { 'Hide', 'Maximize', 'Close' }
config.integrated_title_button_style = 'Gnome'
config.integrated_title_button_alignment = 'Right'
config.integrated_title_button_color = 'Auto'


-- 启动尺寸：1920x1200 下 190x50 约等于满屏（避免默认 120x32 只占 1/4）
config.initial_cols = 190
config.initial_rows = 50
config.default_prog = { '/bin/zsh' }

-- 标签栏
-- 完全关闭 tab bar：平铺 WM 下窗口标题由 Noctalia 顶栏显示。
-- 单 tab 时隐藏不够——多 tab 时那条满宽色块仍会压掉内容行。
-- 需要切 tab 用 Mod+Shift+[/] 之类的键（见下方 keybinds）。
config.enable_tab_bar = false
-- 必须为 false：integrated_title_buttons 绘制在 tab bar 上，
-- 单 tab 时隐藏 tab bar：平铺 WM 下窗口标题已由 Noctalia 顶栏显示，
-- 再挂一条 tab bar 只会压掉终端内容行。多 tab 时才出现。
config.hide_tab_bar_if_only_one_tab = true
config.use_fancy_tab_bar = true

-- 光标
config.default_cursor_style = 'BlinkingBar'

-- 快捷键（GNOME 习惯：Ctrl+Shift 系列）
config.keys = {
  { key = 't', mods = 'CTRL|SHIFT', action = wezterm.action.SpawnTab 'CurrentPaneDomain' },
  { key = 'w', mods = 'CTRL|SHIFT', action = wezterm.action.CloseCurrentPane { confirm = true } },
  { key = 'c', mods = 'CTRL|SHIFT', action = wezterm.action.CopyTo 'Clipboard' },
  { key = 'v', mods = 'CTRL|SHIFT', action = wezterm.action.PasteFrom 'Clipboard' },
  { key = 'd', mods = 'CTRL|SHIFT', action = wezterm.action.SplitHorizontal { domain = 'CurrentPaneDomain' } },
  { key = 'e', mods = 'CTRL|SHIFT', action = wezterm.action.SplitVertical { domain = 'CurrentPaneDomain' } },
  { key = 'LeftArrow', mods = 'CTRL|SHIFT', action = wezterm.action.ActivatePaneDirection 'Left' },
  { key = 'RightArrow', mods = 'CTRL|SHIFT', action = wezterm.action.ActivatePaneDirection 'Right' },
  { key = 'UpArrow', mods = 'CTRL|SHIFT', action = wezterm.action.ActivatePaneDirection 'Up' },
  { key = 'DownArrow', mods = 'CTRL|SHIFT', action = wezterm.action.ActivatePaneDirection 'Down' },
}

-- ============================================================
-- 渲染后端
-- ============================================================
-- OpenGL：硬件加速路径。
-- 【注意】早期在 virtio-gpu 无加速时，OpenGL 会导致显示器挂起。
-- VM 交付镜像使用 virtio-ramfb-gl；宿主不提供 virgl 时合成器会回退软件渲染，
-- 若再次出现 "Display output is not active"，改回 'Software'。
config.front_end = 'OpenGL'

return config
