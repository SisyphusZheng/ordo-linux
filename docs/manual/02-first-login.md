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

## 旧镜像升级后的一次性检查

2026-11-26 这一轮修的是「旧镜像已安装、但缺运行时接线」的问题。升级后按顺序
检查一次。命令在桌面会话里执行：标了 `doas` 的用 root，其余以 `ordo` 用户运行
（`ordo doctor` 的密钥服务与门户项需要会话总线，加 `doas` 会丢掉总线变量）。

```sh
# 1. 总检：新增密钥服务往返、门户、syslog、睡眠策略、维护 cron、wezterm 属主
ordo doctor

# 2. wezterm 配置必须是可写的真实文件（不是软链）
ls -l ~/.config/wezterm/wezterm.lua    # 期望 -rw-...，不是 lrwx...
# 仍是软链：退出重新登录（会话入口自动落副本），或
ordo config apply desktop

# 3. 门户后端（登录时会话入口自动部署用户级副本）
grep -n 'umbriel' ~/.config/xdg-desktop-portal/portals.conf

# 4. 默认关联（新装由 /etc/skel 落；旧 home 手动补）
[ -f ~/.config/mimeapps.list ] || install -Dm644 /etc/skel/.config/mimeapps.list ~/.config/mimeapps.list

# 5. 定时快照与每月 scrub
doas ordo-maintenance status

# 6. 日志：没有 syslog 的系统看不到 /var/log/messages
tail -n 50 /var/log/messages
```

第 2、3、4 项由登录会话自动完成，重登录一次即可；第 5 项缺件时运行
`doas ordo-maintenance enable`。第 6 项在旧镜像上可能没有文件，需要重装或按
[08 故障排查](08-troubleshooting.md) 的 syslog 一节处理。
