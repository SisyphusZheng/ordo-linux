# 08 · 故障排查

> 通用第一步：`ordo doctor`。它按「0 全绿 / 1 有问题 / 2 无法判定」给结论，
> 而 `2` 表示**环境不全、它没法判断**——不是"没事"。

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
ls /usr/share/backgrounds/ordo/       # 图片在不在
/usr/local/bin/ordo-wallpaper; echo $?  # 手动跑，看报错
```

`ordo-wallpaper` 找不到图时输出错误并退出，不静默跳过。

## 中文打不出来

见 [`04-input-method.md`](04-input-method.md)。常见原因：

```sh
grep GTK_IM_MODULE /etc/profile.env    # 环境变量编译进去了吗
ls /usr/lib/fcitx5/ | grep -i gtk      # fcitx-gtk 模块装了吗
```

## 没有声音

```sh
pgrep -x wireplumber || echo "会话管理器没跑"
wpctl status | head -20                # 看设备
systemctl --user status 2>/dev/null    # （没有 systemd，这条会失败，正常）
```

OpenRC 下 pipewire 由会话脚本或 D-Bus 激活拉起。如果 `wpctl` 报连不上，
先确认 `/run/user/$(id -u)/pulse/native` 存在。

## Flatpak 应用主题是灰色

portal 的 Settings 接口没通：

```sh
pgrep -f xdg-desktop-portal
cat ~/.config/xdg-desktop-portal/portals.conf    # 应该 default=gtk
```

`ordo-portal-start` 会在会话里拉起它；如果它没跑，Flatpak 应用拿不到
系统主题，全部回退默认灰色。

## 磁盘满了 / 快照占太多

```sh
zfs list -t snapshot -o name,used -s used | tail -20
ordo snap delete <太占空间的>
zfs get usedbysnapshots rpool/root/ordo
```

`ordo doctor` 会在快照占用 >50% 时警告、>70% 时报错。

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
