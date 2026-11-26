# 许可说明

本仓库**不采用单一许可证**。不同性质的内容走不同的许可，因为它们的用途不同。

## 按内容划分

表按从上到下匹配，首条生效；`**` 跨目录，`*` 不跨目录。LICENSE 与本表逐项一致。

| 路径 | 许可证 | 为什么 |
|---|---|---|
| `config/desktop/wallpapers/*.png` | **CC BY-SA 4.0** | 由脚本生成的桌面图像，允许复用但需署名 |
| `assets/branding/**`（logo、SVG 壁纸、ASCII 画） | **CC BY-SA 4.0** | 同上；品牌资产允许在衍生发行版中复用，但需署名 |
| `docs/**` 与根目录的 `*.md`（README、AGENTS、CONTRIBUTING、CHANGELOG、SECURITY、LICENSE-NOTES） | **CC BY-SA 4.0** | 文档希望被传播与翻译，但要求署名、且衍生文档同样开放 |
| `licenses/**` | 各许可原文，随原许可 | 许可证全文本身不重新授权 |
| `config/release/**` | **GPL-2.0-or-later**；随附的上游签名/摘要材料随原始来源分发 | 锚点文件由本仓维护；Gentoo 的签名与摘要不重新授权 |
| `config/**` | **GPL-2.0-or-later** | 这是系统本体。GPL 保证「改过的系统定义也必须开放」，与 Gentoo 底座同向，也保护 README 里「可拥有」这个承诺。第三方 M2 软件包默认配置沿用其原始许可，见 `config/platform/m2/package-defaults/README.md` |
| `install.sh`、`scripts/**`、`tests/**`、`Makefile`、`.github/**`、`dev/**`、`overlay/**`、`version`、`.gitignore` | **GPL-2.0-or-later**；`overlay/app-crypt/libsecret` 补丁随上游 **LGPL-2.1** | 系统本体与配套工具同源；配方是构建定义；补丁是上游 LGPL 代码的衍生物 |

`SPDX-License-Identifier` 逐文件标注不现实（本仓大量是 KDL/TOML/PNG 等无注释能力的格式），
因此以上表为准。

## 为什么不是 MIT

MIT 允许有人把 `config/` + `scripts/` 做成闭源产品。对这个项目来说，那不是"更自由"，
而是让「这套系统可以被你完全拥有」的承诺对下游失效 —— 拿到 fork 的人不再能拥有它。

单人项目执行 copyleft 的能力确实有限（没有法律实体，实际不会起诉）。
但许可首先是**对下游的声明**，其次才是武器。

## 第三方组件

第三方内容随文件的原始许可分发。

- 品牌素材由 `dev/gen-branding.sh` 生成；桌面壁纸 `wallpaper-seven.png` 由
  `dev/gen-wallpaper.py` 生成，`wallpaper-blackhole.png` 与 `deco-ring.png` 由
  `config/desktop/wallpapers/gen-blackhole.py` 生成。均为自产，无第三方来源
- `overlay/app-crypt/libsecret/files/*.patch` 是上游 libsecret 的补丁，随上游 **LGPL-2.1** 分发，全文见 `licenses/LGPL-2.1.txt`
- `overlay/gui-apps/luciole` 只分发配方与校验清单，上游源码按 **MIT** 授权，全文见 `licenses/MIT.txt`
- 调色板 `config/desktop/themes/*.conf` 的色值取自公开色彩规范（Catppuccin 的调色板本身以 MIT 发布，
  色值不受版权保护；我们只使用色号，不复制其代码或文档）
- 文档中提及 Omarchy、niri、ashell 等仅作技术对照，不附带其代码或素材
- `config/platform/m2/package-defaults/` 随 M2 安装器独立分发 OpenZFS 2.4.4、Gentoo 电源配置服务和 UPower 1.91.3 的默认文件。各文件许可及来源见该目录的 README；CDDL-1.0 全文见 `licenses/CDDL-1.0.txt`。
- `dev/m2/display/modules.tar.gz` 与 `dev/m2/power/macsmc-power.ko` 由同目录的
  `rebuild.sh` 在 7.0.9-asahi-2 源码树产出；构建步骤见
  `dev/m2/display/README.md` 与 `dev/m2/power/README.md`，
  SHA-256 见 `config/release/0.1.0/SOURCES`

**曾经的错误**：2026-11-21 之前，本仓的 `docs/screenshots/` 里有 5 张 Omarchy 官方截图
和 35 张开发过程截图，且被一个 MIT 许可证笼统覆盖。该目录已整体删除（commit 见 CHANGELOG）。

## 运行时依赖（不随本仓分发，各依其自身许可）

| 组件 | 许可 | 备注 |
|---|---|---|
| Gentoo 基础系统（Portage / OpenRC / baselayout） | GPL-2 | 由用户自行 `emerge` |
| OpenZFS | **CDDL-1.0** | 与 GPL 不兼容，但它是**独立可执行程序/内核模块**，不与本仓代码构成派生作品（与 Debian 分发 OpenZFS 的做法一致） |
| Flatpak 应用 | 各自 | 由用户在运行时安装 |

**L2 binhost 的额外义务**：分发 binpkg 时须随附该包的许可全文（`licenses/` 已含
GPL-2、LGPL-2.1、CDDL-1.0、MIT）；若分发 `sys-kernel/gentoo-kernel-bin`，还需按
GPL-2 提供对应源码或书面报价。
