# 04 · 中文输入

Ordo 用 **fcitx5 + rime**，且只有这一条路径（ibus 已移除）。

## 应该是什么体验

1. 登录后直接按 `Mod+S` 打开启动器，输入 `zhongwen`
2. 应该出现拼音候选框，能选字

候选框不出现，先做这两件事：

```sh
# 1. 进程在不在
pgrep -x fcitx5 || echo "fcitx5 没跑"

# 2. 环境变量对不对（只认下面表里的三项）
env | grep -E 'GTK_IM_MODULE|XMODIFIERS|SDL_IM_MODULE'
```

期望输出：

```
GTK_IM_MODULE=wayland
XMODIFIERS=@im=fcitx
SDL_IM_MODULE=fcitx
```

## 环境变量表（唯一来源）

| 变量 | 值 | 谁用 | 为什么 |
|---|---|---|---|
| `GTK_IM_MODULE` | `wayland` | GTK 3/4 应用 | 走合成器的 text-input-v3 协议 |
| `XMODIFIERS` | `@im=fcitx` | X11 应用 | Umbriel 内置 XWayland，没有 text-input-v3，只能走 XIM |
| `SDL_IM_MODULE` | `fcitx` | SDL2 应用 | SDL 的 fcitx 后端 |
| `QT_IM_MODULE` | **不设** | Qt 5/6 应用 | Qt 的 Wayland 插件直接走 text-input-v3；设成 `fcitx` 会去找未安装的 fcitx-qt 插件 |

Umbriel 实现了 `text-input-v3` 协议。GTK 与 Qt 应用都**直接**通过这个协议和
合成器通信，fcitx5 作为合成器的输入法前端工作。走 `fcitx` 的 immodule 路径时，
应用会绕过合成器自己找输入法，而纯 Wayland 会话里找不到。

**X11 例外**：X11 应用由 Umbriel 内置的 XWayland 承载，拿不到 v3 协议，
它们靠 `XMODIFIERS=@im=fcitx`。`xwayland-satellite` 已随 ADR 0011 退场，
当前不安装。

## 环境变量在哪定义

| 文件 | 作用 |
|---|---|
| `config/world` | 装 `app-i18n/fcitx` / `fcitx-rime`（不需要 gtk/qt immodule） |
| `config/desktop/99imm` | 安装时部署到 `/etc/env.d/99imm`，经 `env-update` 进入登录环境 |
| `config/desktop/ordo-session-env` | 会话入口再导出一次，并同步进 D-Bus activation environment |
| `config/desktop/umbriel/config.toml` | `[general] autostart` 含 `fcitx5` |
| `/etc/xdg/fcitx5/profile` | 默认输入法 = rime，唯一引擎 |

检查环境变量有没有真的编译进登录环境：

```sh
grep -E 'GTK_IM_MODULE|XMODIFIERS' /etc/profile.env
```

如果是空的 → `env-update` 没跑（`install.sh` 会跑；手动装的话要自己跑）。

## 候选框不出来

按顺序排查：

```sh
# 1. rime 引擎装了吗
fcitx5-remote -m      # 应该打印当前输入法名
ls /usr/share/rime-data/ 2>/dev/null | head

# 2. 是不是只有 GTK 应用不行（X11 应用另说）
wezterm                                # 在终端里试
flatpak run org.mozilla.firefox        # 在 GTK 应用里试（首启已装）

# 3. rime 的 schema 有没有部署
fcitx5 -d --replace --verbose 2>&1 | head -30
```

常见原因：
- `env.d/99imm` 写了但没 `env-update`（变量只在当前 shell 有效）
- 会话里没有 `fcitx5` 进程（检查 Umbriel 的 autostart）
- Flatpak 应用没有 Wayland socket（`flatpak run --socket=wayland ...`）
- rime 首次启动要“部署”几秒，这时候按键没反应是正常的

## 为什么不用 ibus / chinese-addons

- **ibus**：GNOME 原生，但它的配置方式是 dconf；本桌面栈没有进程读它。
  留着就是两套事实来源，改哪套生效说不清（`deviations` 已登记收回）。
- **fcitx5-chinese-addons**：没有 arm64 keyword（`deviations #6`）。
  rime 在 arm64 上能编，功能也更强。
