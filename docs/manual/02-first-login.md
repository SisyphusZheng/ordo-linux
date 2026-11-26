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

## 连 Wi-Fi：在面板点一下即可

登录密码会自动创建并解锁系统中的 login keyring（Secret Service）。Noctalia 的
网络面板把 Wi-Fi 密码存进 keyring，之后开机自动重连，不需要额外命令。
**正常登录不会弹「新建密钥环」或「输入密钥环密码」对话框。**

旧镜像（还没有密钥服务）仍可用 helper 建系统级配置：

```sh
doas ordo-wifi "你的 Wi-Fi 名"
# 如果提示找不到命令（旧镜像还没有把它放进 PATH）：
doas /opt/ordo/scripts/ordo-wifi "你的 Wi-Fi 名"
```

它把密码存进 NetworkManager 的系统 keyfile，不依赖 keyring。已经用面板建过
同名连接也没关系，再运行一次即可改回系统存储。

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

Ordo 安装 GNOME Keyring。正常登录时 PAM 用登录密码自动创建/解锁 login keyring，
应用保存的密码跨会话可用。

首启自动登录（greetd 的 `[initial_session]`）没有 PAM 密码，该会话首次使用密钥
时可能提示一次；退出后正常登录即可。旧 home 里若已有用其它密码创建的 keyring，
应用访问时也会提示一次；备份后删除 `~/.local/share/keyrings/` 下的旧 keyring，
下次登录会按登录密码重建。
