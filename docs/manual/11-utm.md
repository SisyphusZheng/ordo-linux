# 11 · 导入 ARM64 UTM 虚拟机

本页供已取得候选 ZIP 的测试者使用。源码归档无法导入 UTM。

在 Apple Silicon Mac 上用 UTM 打开 Ordo Linux 0.1.0。ZIP 和解压出的虚拟机各占约 3.1 GiB。

1. 在 Finder 双击 `Ordo Linux 0.1.0 ARM64.utm.zip`。
2. 打开解压出的 `Ordo Linux 0.1.0 (ARM64).utm`，在 UTM 中启动它。
3. 首次启动时按控制台提示为 `ordo` 设置密码。系统随后进入 Umbriel 和 Noctalia 桌面。下次登录和使用 `doas` 时输入这个密码。

如需核对下载，把 ZIP 和 `VM-ZIP-SHA256` 放在同一个目录，从该目录运行以下命令。

```sh
shasum -a 256 -c VM-ZIP-SHA256
```

此 ZIP 的 Luciole 配方需要补齐 Portage Manifest。运行完整系统升级前，请先应用随候选版提供的 Luciole 离线修复包。

后续升级与启动环境恢复见 [升级与回滚](06-upgrade-rollback.md)。
