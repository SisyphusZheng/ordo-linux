# 键位

`Mod` = Super（Windows 键 / Command 键）。

本文件是键位的唯一说明来源。改 `config/desktop/umbriel/config.toml`
的 `[keybinds]` 段后同步改这里。

## 应用

| 键 | 功能 |
|---|---|
| `Mod+Return` | 开终端（WezTerm） |
| `Mod+S` | 搜索（Noctalia 启动器：应用、文件、窗口） |
| `Mod+E` | 文件管理器（Luciole） |
| `Mod+V` | 剪贴板面板（`noctalia msg panel-toggle clipboard`） |
| `Mod+Q` | 关窗口 |
| `Mod+Escape` | 退出会话（需确认） |

## 导航

| 键 | 功能 |
|---|---|
| `Mod+←→↑↓` | 焦点移到相邻窗口 |
| `Mod+H/J/K` | 同上（Vim 风格；`Mod+L` 已被锁屏占用，向右聚焦只用方向键） |
| `Mod+1/2/3/4/5` | 跳工作区 |
| `Mod+Shift+1/2/3/4/5` | 把窗口移到工作区 |

## 尺寸

| 键 | 功能 |
|---|---|
| `Mod+A` | 列变窄 2% |
| `Mod+D` | 列变宽 2% |
| `Mod+R` | 循环预设宽度（33% / 50% / 67%） |
| `Mod+W` | 撑满可用区域 |

## 窗口

| 键 | 功能 |
|---|---|
| `Mod+F` | 全屏 |
| `Mod+Shift+F` | 浮动/平铺切换 |
| `Mod+O` | 总览 |
| `Mod+Shift+←→` | 移动列 |
| `Mod+Shift+↑↓` | 列内上下移动窗口 |

## 布局

| 键 | 功能 |
|---|---|
| `Mod+Ctrl+L` | 循环四种布局：scrolling → dwindle → master → stacking |

这是 Umbriel 相对 niri 的核心增量：niri 只有滚动布局，
没有垂直方向的窗口管理。

## 系统

| 键 | 功能 |
|---|---|
| `Mod+L` | 锁屏 |
| `Mod+I` | 中英切换 |
| `Print` | 区域截图到剪贴板 |
| `Mod+Print` | 全屏截图到剪贴板 |
| `XF86AudioRaiseVolume` / `LowerVolume` / `Mute` | 音量、静音（走 Noctalia 的 OSD） |
| `XF86AudioPlay` / `Next` / `Prev` | 播放、上下曲（走 playerctl；`noctalia msg media` 当前版本不可用） |
| `XF86MonBrightness*` | 亮度（走 Noctalia 的 OSD） |
| `Mod+Shift+F1/F2` | 降低／提高 M2 MacBook Air 的键盘背光，使用 F1、F2 功能键 |
| `XF86KbdBrightness*` | 键盘自带背光键时可直接使用 |

## 已知限制

| 想要 | 状态 |
|---|---|
| 写 `Enter` 键名 | Umbriel 的键名是 `Return`，写 `Enter` 无效 |
| `Ctrl+Shift` 单独作快捷键 | 修饰键不能作主键，必须带一个非修饰键 |
| 裸 `Caps_Lock` | 它是 XKB 的锁存状态，不是普通按键，bind 不触发 |
