# Ordo 用户手册

> 面向**使用者**，不是贡献者。想知道系统怎么造出来的，看 [`docs/`](../) 与 ADR；
> 想改它，看 [`CONTRIBUTING.md`](../../CONTRIBUTING.md)。

## 从这里开始

| 章 | 内容 |
|---|---|
| [01 安装](01-install.md) | 从 ISO 装到桌面，含参数说明与失败处理 |
| [02 第一次登录](02-first-login.md) | 密码在哪、桌面长什么样、先做什么 |
| [03 快捷键](03-hotkeys.md) | 全部键位一张表 |
| [04 中文输入](04-input-method.md) | fcitx5 + rime，候选框不出来怎么办 |
| [05 应用与商店](05-apps.md) | Flatpak 装应用、Warehouse 商店、为什么不用 pacman |
| [06 升级与回滚](06-upgrade-rollback.md) | `ordo sysup`、快照、以及"升级炸了怎么办" |
| [07 配置与主题](07-config-theme.md) | `ordo config`、配色与壁纸、改成你喜欢的样子 |
| [08 故障排查](08-troubleshooting.md) | 黑屏/无输入法/无声音/进不去系统 |
| [09 x86 真机安装](09-x86-install.md) | 在 Intel/AMD 机器上装（走官方 ISO 路径）|
| [10 M2 外接盘安装](10-m2-external.md) | 重建安装介质、首启桌面和回滚 |
| [11 导入 ARM64 UTM 虚拟机](11-utm.md) | 在 Apple Silicon Mac 上打开发布 ZIP 与设置首启密码 |

## 三条常用命令

```sh
ordo doctor        # 我的系统健康吗？（0 全绿 / 1 有问题 / 2 无法判定）
ordo sysup         # 升级（自动快照，失败给回滚路径）
ordo config verify # 仓库声明和机器实际状态一致吗？
```

## 设计原则（用户版）

- **一切皆文件**：系统层配置都是纯文本，能 diff、能 vim、能进 git。
- **只有一种做法**：不提供「可选 A 可选 B」的分叉，减少你要做的决定。
- **开机菜单即后悔药**：ZFS Boot Environment 让你随时回到上一个能用的系统。

## 不支持的功能

- 不承诺适配所有硬件（当前 L1 只在 arm64 VM 验证过，x86 参数化就绪但未实测）
- 不提供 SLA
- 没有防火墙默认规则（见 [SECURITY.md](../../SECURITY.md)）
