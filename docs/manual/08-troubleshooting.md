# 08 · 故障排查

> 通用第一步：`ordo doctor`。它按「0 全绿 / 1 有问题 / 2 无法判定」给结论，
> 而 `2` 表示**环境不全、它没法判断**——不是"没事"。

## 先看日志

系统日志在 `/var/log/messages`（sysklogd 提供，`rc-service sysklogd status`
应为 started）。内核与硬件问题看 `dmesg`：

```sh
doas tail -n 100 /var/log/messages
doas dmesg --level=err,warn | tail -n 50
```

旧镜像没有 syslog 时这个文件不存在；先按本节末尾的「syslog 没跑」处理。

## 进不去系统

1. 开机按 ZFSBootMenu 的键进菜单
2. 选上一个能用的 BE（或 `pre-update-*` 快照）
3. 进去后 `ordo doctor` 看是什么坏了

如果 ZBM 本身都进不去：用 Gentoo minimal ISO 启动，`zpool import -f rpool`，
然后 `zfs get all rpool/root/ordo | grep bootfs` 看启动项指向哪里。

## 黑屏 / 只有壁纸没有栏

```sh
# 1. 合成器起来了吗
pgrep -x umbriel

# 2. 外壳呢（顶栏/启动器/锁屏都是它）
pgrep -x noctalia || echo "noctalia 没跑"

# 3. 手动起一下看报错
noctalia
```

Noctalia 的常见坑：

| 现象 | 原因 |
|---|---|
| 整屏暗红 | `wallpaper_scheme = "m3-fruit-salad"` 多色乱配；改成 `m3-content` |
| 启动报 `config.toml File could not be opened` | 软链目标权限不对（须 644，属主 root 也可，但要 o+r） |
| 顶栏不出现 | Noctalia 没连上合成器；看它日志里的 `connected compositor=` |

## 没有壁纸

```sh
ls /usr/share/backgrounds/ordo/                 # 图片在不在
grep -n '^path' ~/.config/noctalia/config.toml  # 默认壁纸指向哪张
```

壁纸由 Noctalia 管理，换壁纸见 [07 配置与主题](07-config-theme.md)。图片缺失说明
安装时没有铺到 `/usr/share/backgrounds/ordo/`，从仓库 `config/desktop/wallpapers/`
取对应文件。

## 中文打不出来

见 [`04-input-method.md`](04-input-method.md)。先核对环境变量（只有三项）：

```sh
grep -E 'GTK_IM_MODULE|XMODIFIERS' /etc/profile.env
pgrep -x fcitx5 || echo "fcitx5 没跑"
```

`QT_IM_MODULE` 不应设置：Qt 的 Wayland 插件直接走 text-input-v3，
`fcitx-qt` 没有安装。X11 应用由 Umbriel 内置的 XWayland 承载，走
`XMODIFIERS=@im=fcitx`。

## 没有声音

```sh
pgrep -x wireplumber || echo "会话管理器没跑"
wpctl status | head -20                # 看设备
systemctl --user status 2>/dev/null    # （没有 systemd，这条会失败，正常）
```

OpenRC 下 pipewire 由会话脚本或 D-Bus 激活拉起。如果 `wpctl` 报连不上，
先确认 `/run/user/$(id -u)/pulse/native` 存在。

## Flatpak 应用主题是灰色 / 文件选择器不对

设置接口（主题）没通：

```sh
pgrep -af xdg-desktop-portal
busctl --user introspect org.freedesktop.portal.Desktop /org/freedesktop/portal/desktop
```

门户后端由 `portals.conf` 决定：FileChooser / Screenshot / ScreenCast 指向
umbriel，其余接口走 gtk。声明在 `config/desktop/portals.conf`；登录时会话入口
落成 `~/.config/xdg-desktop-portal/portals.conf`，M2 安装器另落一份
`/etc/xdg-desktop-portal/portals.conf`。检查：

```sh
grep -n umbriel ~/.config/xdg-desktop-portal/portals.conf
```

文件缺失或三项不全时，文件选择器会落回 gtk，Luciole 不再是门户选择器。
重新登录一次让会话入口部署，或执行 `doas install -Dm644
/opt/ordo/config/desktop/portals.conf /etc/xdg-desktop-portal/portals.conf`。
`ordo doctor` 会做内容检查与 `busctl` 内省；没有会话总线时报「无法判定」，
不是通过。

## 磁盘满了 / 快照占太多

```sh
zfs list -t snapshot -o name,used -s used | tail -20
ordo snap delete <太占空间的>
zfs get usedbysnapshots rpool/root/ordo
```

`ordo doctor` 会在快照占用 >50% 时警告、>70% 时报错。

## 合盖或睡眠后黑屏

外接 USB 盘做根池时，睡眠会让 USB 重新枚举、根池 suspend，桌面会卡在根 I/O。
系统应安装 `HandleLidSwitch=ignore` 等四项与 `system-sleep` 钩子：

```sh
ls /etc/elogind/logind.conf.d/10-ordo-external-root.conf
ls /lib/elogind/system-sleep/50-ordo-root-pool.sh
```

缺一即说明安装器没有落睡眠策略。从 `/opt/ordo/config/desktop/elogind/` 手工部署
（`install -Dm644 … /etc/elogind/logind.conf.d/`、`install -Dm755 … /lib/elogind/system-sleep/`），
**不要**重跑 `install-external.sh`——它会 `wipefs` 目标盘。**也不要**用
`loginctl suspend` 或手动写 `/sys/power/state`。唤醒后的复检步骤见
[10 号手册的「唤醒之后」](10-m2-external.md)。

## 外接盘掉线（池 suspended）

症状是桌面卡死、`zpool status` 报 suspended。恢复流程、必须保留独立救援 U 盘
的要求、以及 wtmp/zedlet 证据收集，见
[10 号手册的「外接盘掉线」](10-m2-external.md)，本节不重复。

## 快照 / scrub 没有跑

```sh
doas ordo-maintenance status    # 0 完整 / 1 缺件 / 2 无法判定
doas ordo-maintenance enable    # 缺件时重建两个 cron 文件
ls -l /etc/cron.d/ordo-snapshot /etc/cron.monthly/zfs-scrub
rc-service cronie status
```

## syslog 没跑

```sh
rc-service sysklogd status
rc-update show default | grep sysklogd
doas tail -n 50 /var/log/messages
```

未安装时 `doas emerge app-admin/sysklogd` 并 `doas rc-update add sysklogd default`；
有服务但没有 `/var/log/messages` 时检查 `/etc/syslog.conf` 是否有
`*.* /var/log/messages`。

## 密钥服务不可用（Wi-Fi 密码存不住）

在桌面会话里以 `ordo` 用户运行（不要 `doas`，它会把会话总线变量清掉）：

```sh
printf 'probe' | secret-tool store --label=probe service ordo-probe key 1
secret-tool lookup service ordo-probe key 1    # 应输出 probe
secret-tool clear service ordo-probe key 1
```

失败时先看 `pgrep -a gnome-keyring-daemon`。`ordo doctor` 的这一项在缺
`secret-tool` 或无会话总线时报「无法判定」，不是通过。旧镜像的 PAM 与会话
脚本见 [02 号手册的「旧镜像升级后的一次性检查」](02-first-login.md)。

## wezterm 配色 hook 报权限不够

现象是登录日志出现 `touch: 无法 touch '/home/ordo/.config/wezterm/wezterm.lua':
权限不够`，Noctalia 的 wezterm 模板因此写不进配色。

```sh
ls -l ~/.config/wezterm/wezterm.lua   # 期望 -rw-... 的普通文件，不是 lrwx...
```

仍是软链时退出重新登录（会话入口会落成用户副本），或运行
`ordo config apply desktop`。

## Noctalia 报 storage-key 失败

启动日志出现：

```
[storage-key] failed to open configured storage key file: 没有那个文件或目录
```

含义是 Noctalia 找不到通知历史加密用的 key 文件。上游没有公开该配置键与默认
路径，仓库不猜键名。可执行步骤：

1. 确认历史文件：`ls -l ~/.local/state/noctalia/notification_history.enc`。
2. 不需要历史时删掉该文件后重启 Noctalia（放弃已加密内容，等上游重建）；
   若重启后仍报同一行，说明上游仍启用加密历史，按第 3 步等上游文档。
3. 需要历史时先从备份恢复 key 文件；上游文档给出键名后再固定到
   `config/desktop/noctalia/config.toml`。
4. 验收：`grep '\[storage-key\]' ~/.cache/noctalia/noctalia.log` 不再出现
   `failed`。

## 我改了配置但没生效

```sh
ordo config verify        # 看是不是漂移了
ordo config apply desktop # 重新部署（符号链接）
umbriel config validate   # 校验 TOML
# 保存即生效，Umbriel 与 Noctalia 都热重载
```

如果配色没跟着壁纸变，检查 `[theme] source` 是不是 `wallpaper`，
以及 `wallpaper_scheme` 是不是被设置界面改成了别的值
（运行时覆盖在 `~/.local/state/noctalia/settings.toml`）。

## 报告问题

给三样：**能复现的命令** + **实际输出** + **期望输出**。
提交前先查阅 `docs/deviations.md`，其中记录了已确认的非常规行为。

## 外接盘和空家目录

在终端运行 `ls -a` 可看到当前目录的隐藏文件，`ls /` 可查看系统根目录。
Luciole 通过 GIO 的 UDisks 卷监视器列出可识别的外接卷。插盘后用 `lsblk -f` 核对。若设备已出现但卷标或挂载入口缺失，用 `udisksctl status` 检查桌面存储服务。

M2 Air 的会话硬件报告位于 `~/.local/state/ordo/m2-hardware.log`。它记录 NetworkManager 接口状态和蓝牙控制器的电源状态。扫描蓝牙设备时，配件需要进入配对模式。
