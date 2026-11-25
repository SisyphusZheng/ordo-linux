# ADR 0011 — 桌面栈：Noctalia 全家桶（Umbriel + Shell + Luciole + Greeter）

- 状态：已采纳（Umbriel 与 Shell 实机验证通过）
- 日期：2026-11-22
- 取代：ADR 0009（桌面栈终审 niri）
- 关联：deviations #40–#49、#50–#52

## 一、问题陈述

ADR 0009 选定的栈是六个独立组件拼起来的：

```
niri（合成器）+ ashell（顶栏）+ lavalauncher（dock）+ tofi（启动器）
+ dunst（通知）+ swaylock（锁屏）+ swaybg（壁纸）+ cliphist（剪贴板）
+ wlsunset（夜间）+ xwayland-satellite（X11）
```

每个组件有独立的配置格式、坐标系和更新节奏。后果有三：

| 问题 | 具体表现 |
|---|---|
| 视觉无法统一 | 换一套配色要手工改 6 个文件，且没有任何机制保证它们一致 |
| 没有图形设置 | 调顶栏高度要改 TOML 再重启；用户无从下手 |
| 布局能力受限 | niri 只有滚动布局，无法向下扩张窗口 |

ADR 0009 的核心约束是「纯 Wayland、无 GTK/Qt、轻量」。这三条在新方案下必须保住。

## 二、候选

| 方案 | 零 GTK/Qt | 单一体系 | 布局 | 结论 |
|---|---|---|---|---|
| 维持 niri 栈 | 是 | 否（六组件） | 仅滚动 | 不解决问题 |
| Hyprland 全家桶 | **否**（Qt） | 部分 | dwindle | 违反硬约束 |
| **Noctalia 全家桶** | **是** | **是**（一份 TOML） | **四种** | 采纳 |

## 三、决策

采用 Noctalia 全家桶五件套：

| 组件 | 版本 | 职责 |
|---|---|---|
| Umbriel | 0.1.0 | 合成器（wlroots + umbrielfx） |
| Noctalia Shell | v5.6.0 | 顶栏、启动器、控制中心、通知、锁屏、壁纸、剪贴板、OSD、托盘 |
| Luciole | 0.1.0 | 文件管理器，同时作为门户的文件选择器 |
| Noctalia Greeter | 9999 | 图形登录屏 |
| xdg-desktop-portal-umbriel | pre | 截图、录屏、文件选择 |

## 四、实测数据

依赖代价远小于预期：

| 包 | 新增依赖 | 下载量 | GTK/Qt 链接 |
|---|---|---|---|
| noctalia | 4 个 | 26 MB | 0 |
| umbriel | 5 个 | 2.3 MB | 0 |
| luciole | 0 个（依赖已满足） | 2.7 MB | 0 |

`ldd /usr/bin/noctalia | grep -ci 'libgtk\|libQt'` → `0`。
`ldd /usr/bin/umbriel` 同样为 0。**硬约束保住。**

## 五、关键机制：壁纸驱动配色

```toml
[theme]
source = "wallpaper"
wallpaper_scheme = "m3-content"
pure_black_dark = true
```

换壁纸即换整套配色，不需要逐组件改色值。这是「一个体系」的技术支点，
也是删掉旧的「主题目录 + 主题派生脚本」那一套的原因 ——
配色不再是一份需要人工同步的文件。

**踩过的坑**：首次启动向导默认选 `m3-fruit-salad`（多色乱配），
会把整个界面染成暗红。已在配置里注明。

## 六、代价

| 代价 | 说明 |
|---|---|
| Umbriel 是 pre-release | 版本号 `0.0.0_pre`，配置键名可能在小版本间变动 |
| 配置需重写 | niri 的 KDL 全部翻译为 TOML，键位逐条映射 |
| Luciole 无发布 tag | ebuild 用 `archive/main` 快照 |
| 无法远程截 greeter | 自带合成器不支持 screencopy 协议 |

## 七、被否决的替代路径

**只换 Shell、保留 niri**（Noctalia 支持 niri 后端）：
风险最低，但保不住布局能力，且 niri 的配置与 Noctalia 的外壳是两套语言，
「一个体系」不成立。用户明确要求全家桶而非单品，故否决。

## 八、验收

- `umbriel config validate` → `config: ok`
- Noctalia 在 Umbriel 会话内启动，顶栏渲染正常
- `noctalia-greeter sessions` 正确列出会话
- 旧栈 12 个包全部卸载，`command -v niri` 等均为空
- `make check` 全绿
