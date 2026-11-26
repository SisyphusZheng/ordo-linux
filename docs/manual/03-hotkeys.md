# 03 · 快捷键

> `Mod` = Super（Windows 键 / Command 键）。
> 本文与 `config/desktop/keys.md` 保持同步；改键位请改
> `config/desktop/umbriel/config.toml` 的 `[keybinds]` 段，然后同步 keys.md。
> `tests/lint.sh` 会核对 keys.md 与 `[keybinds]`，以及本文的 `Mod+` 组合都已绑定。

## 应用

| 键 | 作用 |
|---|---|
| `Mod+Return` | 打开终端（WezTerm） |
| `Mod+S` | 启动器：搜应用、文件、窗口 |
| `Mod+E` | 打开 Luciole（文件管理器） |
| `Mod+V` | 剪贴板历史面板（选一条即粘贴） |
| `Mod+Q` | 关闭当前窗口 |
| `Mod+Escape` | 退出 Umbriel 会话（有确认框） |

## 窗口焦点与移动

| 键 | 作用 |
|---|---|
| `Mod+←→↑↓` | 焦点移到相邻窗口 |
| `Mod+H` / `Mod+J` / `Mod+K` | 焦点左 / 下 / 上（Vim 风格；`Mod+L` 已被锁屏占用） |
| `Mod+Shift+←→` | 当前列左移 / 右移 |
| `Mod+Shift+↑↓` | 当前列内窗口上移 / 下移 |

## 列宽

| 键 | 作用 |
|---|---|
| `Mod+A` | 列变窄 2% |
| `Mod+D` | 列变宽 2% |
| `Mod+R` | 循环预设宽度（33% → 50% → 67%） |
| `Mod+W` | 当前列撑满可用区域 |

## 窗口状态

| 键 | 作用 |
|---|---|
| `Mod+F` | 全屏切换 |
| `Mod+Shift+F` | 浮动 / 平铺切换 |
| `Mod+O` | 总览（所有工作区缩略图） |

## 工作区

| 键 | 作用 |
|---|---|
| `Mod+1` … `Mod+5` | 切到工作区 1–5 |
| `Mod+Shift+1` … `Mod+Shift+5` | 把当前窗口移到工作区 1–5 |

## 布局

| 键 | 作用 |
|---|---|
| `Mod+Ctrl+L` | 循环四种布局：scrolling → dwindle → master → stacking |

## 系统与媒体

| 键 | 作用 |
|---|---|
| `Mod+L` | 锁屏（Noctalia 锁屏；输入密码解锁） |
| `Mod+I` | 中英输入切换（fcitx5） |
| `Print` | 区域截图 → 剪贴板（先拖选区域） |
| `Mod+Print` | 全屏截图 → 剪贴板 |
| `XF86AudioRaiseVolume` / `XF86AudioLowerVolume` | 音量 ±（Noctalia OSD 显示） |
| `XF86AudioMute` | 静音切换 |
| `XF86AudioPlay` / `XF86AudioNext` / `XF86AudioPrev` | 播放 / 下曲 / 上曲（playerctl） |
| `XF86MonBrightnessUp` / `XF86MonBrightnessDown` | 屏幕亮度（Noctalia OSD 显示） |
| `Mod+Shift+F1/F2` | 降低／提高 M2 MacBook Air 的键盘背光 |

> 笔记本键盘上亮度键通常还要按住 `Fn` 才发出生成 `XF86MonBrightness*` 信号。

## 已知限制

| 想要 | 状态 |
|---|---|
| `Mod+Enter` | Umbriel 的键名是 `Return`，写成 `Enter` 无效 |
| `Ctrl+Shift` 单独作快捷键 | 修饰键不能作主键，必须带一个非修饰键 |
| 裸 `Caps_Lock` | 它是 XKB 的锁存状态，不是普通按键，bind 不触发 |
| `noctalia msg media` 媒体键 | 当前版本对所有 action 返回 unknown command，媒体控制走 playerctl |

## 改了键位怎么办

1. 改仓库里的 `config/desktop/umbriel/config.toml`（不是 `~/.config/umbriel/config.toml`）
2. 同步 `config/desktop/keys.md`（lint 有判据）
3. `umbriel config validate` 校验后保存即生效（Umbriel 热重载 TOML）
