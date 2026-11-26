# 11 · 导入 ARM64 UTM 虚拟机

在 Apple Silicon Mac 上，用 UTM 打开 Ordo Linux 0.1.0。保存 ZIP 和解压出的虚拟机需要约 7 GiB 可用空间。

1. 下载 `Ordo-Linux-0.1.0-UTM-arm64.zip` 和 `UTM-SHA256SUMS`，把两个文件放在同一个目录。
2. 在 Finder 双击 ZIP 一次。解压后会得到 `Ordo Linux 0.1.0 (ARM64).utm`。双击这个文件导入 UTM，再启动虚拟机。
3. 首次启动时按控制台提示为 `ordo` 设置密码。随后会进入 Umbriel 和 Noctalia 桌面。下次登录和使用 `doas` 时输入这个密码。

可以在解压前从下载目录核对 ZIP 完整性。

```sh
shasum -a 256 -c UTM-SHA256SUMS
```

`UTM-SHA256SUMS` 由 `dev/vm/zip-bundle.py` 与 ZIP 同批生成；仓库不保存 ZIP，
所以摘要清单随发布产物提供。

新版虚拟机已包含 Luciole 的配方修复。若已导入早先发布的 `Ordo Linux 0.1.0 ARM64.utm.zip`，可在现有虚拟机内应用单独发布的 Luciole 离线修复包，保留已有账户和数据。

后续升级与启动环境恢复见 [升级与回滚](06-upgrade-rollback.md)。
