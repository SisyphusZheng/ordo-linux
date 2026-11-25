# Ordo Linux

**0.1.0 · Ab Chao · 源码技术预览**

Ordo 是基于 Gentoo 的中文 Wayland 桌面发行版。Umbriel 负责窗口布局，Noctalia 提供桌面外壳，Luciole 管理文件。系统配置集中在纯文本文件中。升级前可以给 ZFS 根系统创建快照，回到旧版本时保留独立的用户目录。

## 从这里开始

本次公开提供系统定义、制盘工具、测试和手册。GitHub 自动提供的 ZIP 和 tar.gz 是源码归档。预构建的 UTM 虚拟机和 M2 安装包目前处于候选验收阶段，尚未提供公开镜像下载。

| 使用场景 | 0.1.0 验证范围 | 使用说明 |
|---|---|---|
| 在 Apple Silicon Mac 上体验桌面 | ARM64 镜像已导入 UTM。独立副本完成首次设密、进入桌面、实际软件包升级与回滚，并保留了升级后写入的用户文件。 | [UTM 导入指南](docs/manual/11-utm.md) |
| 在 2022 款 13 英寸 M2 MacBook Air（Mac14,2）上使用外接系统盘 | 在该机型的 macOS 上通过安装器预检。候选包已在模拟的空白 USB 盘完成安装并冷启动进入桌面。独立真机全新安装、AGX 加速及内屏稳定性仍待验证。 | [M2 外接盘安装指南](docs/manual/10-m2-external.md) |
| 修改或重建系统 | 从 Gentoo stage3 装配 ARM64 根系统，分别制作 UTM 磁盘或 M2 安装介质。其他 Mac 机型和 amd64 真机尚未通过本次验收。 | [ARM64 构建说明](dev/release/arm64-assembly.md) |

M2 真机采用 Asahi 引导。内置盘保留 macOS 和本机的引导入口，Ordo 安装在单独的外接 USB 盘。安装会清空选定的目标盘。Apple 固件由安装器从接收者自己的 Mac 提取。

## 系统如何组织

- **桌面与系统**由 Portage 管理，使用 OpenRC 启动。包集、USE 配置与桌面默认值在 [config](config/)。
- **应用**通过 Flatpak 分发。必装与可选应用见 [应用清单](config/apps.d/)。
- **升级与恢复**使用 ZFS 启动环境。回滚流程和用户数据的范围见[升级与回滚](docs/manual/06-upgrade-rollback.md)。

## 验证源码

在仓库根目录运行：

```sh
make check
```

这会执行静态检查、回归测试和命令行自检。真机硬件验收需要在目标系统上运行 `ordo doctor`。构建环境和提交流程见[贡献指南](CONTRIBUTING.md)。

[用户手册](docs/manual/00-index.md) · [设计决策](docs/decisions/README.md) · [已知偏离](docs/deviations.md) · [安全报告](SECURITY.md) · [许可](LICENSE)
