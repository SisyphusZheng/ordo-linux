# 02 · 第一次登录

## 密码在哪

安装时如果没有设 `ORDO_USER_PASSWORD`，脚本会生成随机密码并**只打印一次**，
在安装日志里长得像：

```
==> 已生成随机用户密码（请立即记录，只显示这一次）：

    ordo / x7Kp2mQ9vLrT4nWz
```

用户名固定是 `ordo`。

忘了怎么办：

```sh
# 从 ZBM 引导进救援环境，chroot 后重设
passwd ordo
```

## 桌面长什么样

- 合成器 **Umbriel**（默认滚动平铺，可切 dwindle/master/stacking）
- 外壳 **Noctalia**（顶栏、启动器、控制中心、通知、锁屏、壁纸，同一个程序）
- 文件管理器 **Luciole**
- 启动器 `Mod+S`（Noctalia 的启动器，搜应用、文件、窗口）
- 终端 `Mod+Return`（WezTerm）

## 先做这三件事

```sh
# 1. 看系统健康
ordo doctor

# 2. 确认中文能打（按 Mod+S 打开启动器，输入拼音试试）
#    如果候选框不出来 → docs/manual/04-input-method.md

# 3. 看看有哪些应用，装一个浏览器
ordo app list
ordo app install org.mozilla.firefox
```

## 你的配置在哪里

| 路径 | 内容 | 该不该手改 |
|---|---|---|
| `~/.config/umbriel/config.toml` | 窗口/键位/布局 | 是 可以改，但改完回写仓库 |
| `~/.config/noctalia/config.toml` | 顶栏/启动器/锁屏/配色 | 是 同上 |
| `~/.config/wezterm/wezterm.lua` | 终端 | 是 |
| `~/.zshrc` | shell 配置 | 是 |

配色不在这两个文件里硬编码 —— Noctalia 从壁纸提取调色板，
换壁纸（或在设置里选壁纸）就是换整套配色。

**重要**：仓库里的 `config/` 才是事实来源。手改 `~/.config` 后，
`ordo config verify` 会告诉你漂移了，`ordo config apply desktop` 可以从仓库重新部署。

## 应用保存的密码

Ordo 默认不安装 GNOME Keyring。程序可使用自己的账号登录和存储功能。依赖系统 Secret Service 的程序可能需要重新输入凭据或只在当前会话记住登录。
