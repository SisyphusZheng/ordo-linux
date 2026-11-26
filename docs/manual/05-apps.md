# 05 · 应用与商店

## 为什么要装应用还要分两种方式

Ordo 的规则很简单：**系统层用 Portage，应用层用 Flatpak**。

| 层 | 装法 | 例子 | 为什么 |
|---|---|---|---|
| 系统层 | Portage（`emerge`） | 内核、ZFS、Umbriel、字体、输入法 | 需要编译进系统、开机就要用 |
| 应用层 | Flatpak | 浏览器、办公、IM、编辑器 | 沙箱、独立更新、不污染系统 |

判断标准只问一句：**这东西需要我审计、需要我改吗？**
需要 → 系统层（纯文本配置）；只是用 → Flatpak。

## 装应用

```sh
ordo app install org.mozilla.firefox     # 装一个
ordo app list                            # 看装了哪些
flatpak run org.mozilla.firefox          # 运行
```

也可以从桌面启动器（`Mod+S`）搜索应用名。

## 图形化商店：Warehouse

```sh
flatpak run io.github.flattool.Warehouse   # 或从启动器（Mod+S）搜 "Warehouse"
```

能浏览、搜索、安装 Flatpak 应用。

## 首启装了哪些

`config/apps.d/00-core.list` 里的两件事：

| 应用 | 为什么在 core |
|---|---|
| Firefox | 没有浏览器的系统不算能用 |
| Warehouse | 宪法要求"可视化 Flatpak 商店" |

Luciole 不在应用清单里：它是系统层的 `gui-apps/luciole`（见 `config/world`），
随桌面一起装，同时承担门户的文件选择器。

可选应用在 `config/apps.d/01-optional.list`，按需 `ordo app install`。

## 查看器与默认关联

新用户的 `~/.config/mimeapps.list` 由 `/etc/skel` 预置，打开 PDF、图片、视频
会落到下表的 Flatpak 应用：

| 内容 | 默认应用 | Flatpak id |
|---|---|---|
| PDF / 文档 | Papers | `org.gnome.Papers` |
| 图片 | Loupe | `org.gnome.Loupe` |
| 视频 | mpv | `io.mpv.Mpv` |

先安装应用，默认关联才会生效：

```sh
ordo app install org.gnome.Papers
ordo app install org.gnome.Loupe
ordo app install io.mpv.Mpv
```

旧 home 没有这份文件时手动补一次：

```sh
install -Dm644 /etc/skel/.config/mimeapps.list ~/.config/mimeapps.list
```

## 打印与扫描

当前**不支持**打印与扫描：系统层没有 CUPS/SANE，Flatpak 应用也没有可用的打印
后端。需要时先在 issue 里提出，不要自行 `emerge` 后忘记同步 `config/world`
（`ordo doctor` 会报漂移）。

## 更新应用

Flatpak 应用由 `/etc/cron.weekly/flatpak-update` 每周自动更新
（`install.sh` 装的）。也可以手动：

```sh
flatpak update -y
```

## 我需要的软件不在 Flathub

三条路，按推荐顺序：

1. **找 Flathub 上的替代品**（90% 的情况）
2. **AppImage / 官方 tarball**：放 `~/.local/bin`，不污染系统
3. **确实需要系统级**：提 issue 讨论，不要自己 `emerge` 后忘了同步 `config/world`

> 「忘了同步」是真实风险：`ordo doctor` 会报 world 漂移，
> 而 `emerge --depclean` 可能把你手装的包拆掉。

## 为什么不用 pacman/AUR

Ordo 底座是 Gentoo。这不是审美选择：Portage 的 USE flag 让我能精确控制
"编译进什么、不编译进什么"，而 AUR 是预编译二进制 + PKGBUILD 脚本，
在 arm64 上大量包根本没有现成产物。
