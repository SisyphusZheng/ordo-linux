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

也可以从桌面启动器（`Mod+Space`）搜索应用名。

## 图形化商店：Warehouse

```sh
warehouse-launch      # 或从启动器搜 "Warehouse"
```

能浏览、搜索、安装 Flatpak 应用。

> **为什么需要 `warehouse-launch` 这个包装脚本**：直接 `flatpak run` 时，
> bwrap 找不到相对命令名，必须用 `--command=/app/bin/warehouse` 绝对路径；
> 而且它必须在标准会话总线（`/run/user/1000/bus`）上跑才能激活
> `org.freedesktop.Flatpak` 服务。这两个坑都写在包装脚本里了。

## 首启装了哪些

`config/apps.d/00-core.list` 里的三件事：

| 应用 | 为什么在 core |
|---|---|
| Firefox | 没有浏览器的系统不算能用 |
| Luciole | 图形文件管理（系统层，随桌面一起装） |
| Warehouse | 宪法要求"可视化 Flatpak 商店" |

可选应用在 `config/apps.d/01-optional.list`，按需 `ordo app install`。

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
