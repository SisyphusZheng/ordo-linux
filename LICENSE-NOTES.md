# 许可说明

[LICENSE](LICENSE) 列出了 Ordo 原创代码、系统定义、文档和品牌素材的许可。第三方内容保留其原始许可和署名。

| 内容 | Ordo 原创部分的许可 |
|---|---|
| 安装器、CLI、开发工具、测试、CI、系统配置、overlay 配方 | GPL-2.0-or-later |
| 用户手册、设计文档、品牌图形及生成的桌面壁纸 | CC BY-SA 4.0 |

## 第三方来源

- `overlay/` 中 ebuild 的代码和它下载的软件是独立作品。查看配方中的 `LICENSE`、固定源码版本及上游随附的许可。
- M2 的 OpenZFS、UPower 和电源服务默认配置随文件提供来源与许可。OpenZFS 包含 CDDL 许可的代码。[默认配置来源](config/platform/m2/package-defaults/README.md)
- M2 的 Linux 驱动构建说明和补丁见 [display](dev/m2/display/README.md) 与 [power](dev/m2/power/README.md)。此源码预览不附带旧版编译模块、Apple 专有固件、主机密钥或安装磁盘。
- 桌面壁纸可用 [壁纸生成器](dev/gen-wallpaper.py) 和[桌面背景生成器](config/desktop/wallpapers/gen-blackhole.py) 生成。项目标记见 [品牌目录](assets/branding/)。

## 为什么不是 MIT

项目为原创系统代码选用 GPL-2.0-or-later，为原创文档和图形选用 CC BY-SA 4.0。修改和分发时请保留相应的署名、许可与版权声明。[许可全文](licenses/)

## 曾经的错误

早期私有历史里收录过上游项目截图。公开源码从经过审阅的独立快照建立，旧截图不在公开版本中。
