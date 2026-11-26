# Ordo 桌面

Noctalia 全家桶。五个组件同一来源、同一套视觉、同一份配置语言。

## 五个组件

| 层 | 组件 | 配置 |
|---|---|---|
| 合成器 | **Umbriel** | `umbriel/config.toml` |
| 外壳 | **Noctalia Shell** | `noctalia/config.toml` |
| 文件管理器 | **Luciole** | 无配置（读系统图标与门户） |
| 登录屏 | **Noctalia Greeter** | `greetd/config.toml` |
| 门户 | **xdg-desktop-portal-umbriel** | `portals.conf`（后端选择） |

外壳包含顶栏、启动器、控制中心、通知、锁屏、壁纸、剪贴板历史、OSD、
系统托盘、桌面小组件 —— 这些以前是六个独立组件，现在是同一份 TOML。

## 唯一真相来源

```
config/desktop/{umbriel,noctalia,greetd}/*.toml
    ↓  ordo config apply desktop（符号链接）
~/.config/{umbriel,noctalia}/config.toml
```

**默认没有第二份副本。** 改仓库文件即等于改生效配置，不需要重新 apply。

唯一例外是 `~/.config/wezterm/wezterm.lua`：它按手册要由用户原地编辑，
且 Noctalia 的 wezterm 模板会往里写色名。`ordo config apply desktop`
（以及会话入口 `ordo-umbriel-session`，用于修复旧系统里的软链）把它落成
属主是桌面用户的真实副本；其余文件仍是软链。`~/.config/xdg-desktop-portal/portals.conf`
是会话入口从 `portals.conf` 生成的用户级副本（门户的 XDG 查找规则要求这个
文件不能是软链指向 `/opt`），内容以本目录的声明为准。

## 密钥服务契约

`gnome-base/gnome-keyring` 提供 `org.freedesktop.secrets`（即 `virtual/secret-service`），
`app-crypt/libsecret` 是客户端库，两者都随系统安装。登录时 PAM（`sys-auth/pambase`
的 `gnome-keyring` USE + `greetd/pam.d-greetd` 的 auth/session 两行）用登录密码
自动创建/解锁 `login` keyring；会话入口在 D-Bus 就绪后、Noctalia 之前确保
`gnome-keyring-daemon --components=secrets` 运行。**正常登录不弹「新建密钥环 /
输入密钥环密码」对话框。**

| 消费方 | 约定 |
|---|---|
| Noctalia 网络面板 | 点一下即可连接并保存密码：PSK 交给 Secret Service，跨会话自动重连 |
| NetworkManager | 面板连接使用 keyring；需要系统级 keyfile 时仍可用 `doas ordo-wifi "<SSID>"`（`psk-flags=0`） |
| 依赖钥匙环的应用 | 使用登录时已解锁的 login keyring 保存凭据 |

**首启自动登录限制**：greetd 的 `[initial_session]` 自动登录没有 PAM 密码，
login keyring 不会被创建/解锁；该会话首次使用密钥时可能提示一次。正常登录
（输入密码）不受影响。

**旧 home 的残留 keyring**：`~/.local/share/keyrings/` 里若已有用其它密码创建的
keyring，PAM 无法用登录密码解锁，应用访问时会提示一次。备份后删除旧的
`login.keyring`/`default.keyring`，下次登录会按登录密码重建。

验收：`sh config/desktop/keyring-policy.sh check`（0 声明与接线齐备 / 1 缺件 /
2 无法判定）。它检查 world、`config/package.mask`、greetd PAM 两行与会话启动行；
有会话总线时再做一次 `secret-tool` 往返。

## 门户契约

`portals.conf` 把三个接口固定到 umbriel 门户，其余接口 `default=gtk`：

| 接口 | 后端 | 消费者 |
|---|---|---|
| FileChooser | umbriel | Luciole（文件选择器） |
| Screenshot | umbriel | 截图/录屏 |
| ScreenCast | umbriel | 录屏 |
| 其余 | gtk | 主题/通知等 |

部署路径有两条：会话入口 `ordo-umbriel-session` 每次登录写用户级
`~/.config/xdg-desktop-portal/portals.conf`（优先于系统级）；M2 安装器经
`m2-desktop-fix.sh` 写系统级 `/etc/xdg-desktop-portal/portals.conf`。
`ordo doctor` 会检查生效文件的三项后端，并对会话总线上的
`org.freedesktop.portal.Desktop` 做 `busctl --user introspect`。

## 为什么是这一套

上一版是 niri + ashell + lavalauncher + dunst + swaylock + swaybg + tofi
+ cliphist 拼起来的：六份配置、六种格式、六个坐标系，视觉只能靠手工对齐。

现在五个组件由同一个团队设计，共用壁纸、调色板与字体。
核心机制是 `theme.source = "wallpaper"` —— **换壁纸就是换整套配色**，
不需要逐组件改色值。

## 配色

由 Noctalia 从壁纸提取，不在配置文件里硬编码任何色值。

```toml
[theme]
mode = "dark"
source = "wallpaper"
wallpaper_scheme = "m3-content"   # 从壁纸取主色，保留色相关系
pure_black_dark = true            # 深色表面钉到纯黑
```

可选提取算法（克制 → 花哨）：

| 值 | 效果 |
|---|---|
| `m3-monochrome` | 完全去色 |
| `m3-tonal-spot` | 只取一个色相做单色系 |
| **`m3-content`** | 从壁纸取主色，保留色相关系（当前） |
| `muted` | 低饱和 |
| `vibrant` | 高饱和 |
| `m3-fruit-salad` | 多色乱配 —— **会把界面染成暗红，别用** |

## 材质与几何

```toml
[shell.panel]
transparency_mode = "glass"   # solid | soft | glass（半透明 + 模糊）
borders = false

[appearance]
corner_radius = 20
border_width = 2              # 焦点环
```

## 键位

见 `keys.md`。改键位改 `umbriel/config.toml` 的 `[keybinds]` 段。

## 改完怎么生效

```sh
ordo config apply desktop   # 首次部署或换机器
ordo config verify          # 确认无漂移（三态：0/1/2）
```

Umbriel 与 Noctalia 都支持热重载，保存即生效。

## 布局

Umbriel 支持四种布局，`Mod+Ctrl+L` 循环切换：

| 布局 | 特征 |
|---|---|
| `scrolling` | 无限横向条带（默认，与原 niri 一致） |
| `dwindle` | 经典二分平铺 |
| `master` | 主窗 + 侧栏 |
| `stacking` | 堆叠 |

这解决了原 niri 只能滚动、无法「向下扩张」的限制。

## 已知限制

| 限制 | 原因 |
|---|---|
| Umbriel 为 pre-release | 配置键名可能在小版本间变动，升级前先看上游 changelog |
| Luciole 无发布 tag | ebuild 固定源码提交并随附 Manifest，升级时同步更新两者 |
| Greeter 不创建 `greeter` 用户 | GURU 的 ebuild 只装 tmpfiles.d，实际用 `greetd` 用户 |
| 无法远程截图 greeter | 它的合成器不支持 screencopy 协议 |

## 部署到实机（2026-11-22 起的唯一合法规程）

声明改完后分两步：先 rsync 到临时目录，再由 root 落位（rsync 直接写
`/opt/ordo` 需要对端 root 权限，经 ordo 的 doas 免密走这一跳）。

```sh
# 1) 推到临时目录（两个目录都推）
rsync -az config/  ordo@<host>:/tmp/ordo-config-new/
rsync -az scripts/ ordo@<host>:/tmp/ordo-scripts-new/

# 2) root 落位：属主 root，目录 755 / 文件 644
#    --chmod 解决两个历史坑：cp/rsync 带回源文件 0600（偏离 #64），
#    以及软链目标对桌面用户不可读导致 Umbriel 起不来。
ssh ordo@<host> 'doas rsync -a --chown=root:root \
    --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r /tmp/ordo-config-new/ /opt/ordo/config/'
# scripts/ 里的执行体要保住 755：Fu=rw,Fgo=r 会剥掉可执行位
# （2026-11-22 实测：doctor 直接 Permission denied），必须用 rwx。
ssh ordo@<host> 'doas rsync -a --chown=root:root \
    --chmod=Du=rwx,Dgo=rx,Fu=rwx,Fgo=rx /tmp/ordo-scripts-new/ /opt/ordo/scripts/'

# 3) 验收
ssh ordo@<host> 'ordo config verify; ordo doctor'
```

为什么是两条 rsync：`config/`（声明层）与 `scripts/`（doctor / ordo-config
等执行体）必须一起走——声明升级而判据脚本不升级，verify 的结论就是旧规则的。
