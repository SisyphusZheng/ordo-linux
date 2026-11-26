# Ordo Linux

**Ordo Linux 是一个基于 Gentoo、支持启动时回滚的中文桌面发行版。**

0.1.0 候选版面向两种使用方式。真机目标是 2022 款 13 英寸 M2 MacBook Air
（Mac14,2），Ordo 系统放在外接 USB 盘，Mac 内置盘保留该机专属引导入口。
虚拟机目标是 Apple Silicon 上的 ARM64 UTM 桌面。两者共用 OpenRC、Umbriel 和
ZFS 系统快照。具体机型和验收范围见下表。

- 仓库根目录即完整系统定义：`config/` 描述目标状态，`install.sh` 从零构建，`scripts/` 提供运维命令
- 根数据集为 ZFS，可回滚到任意快照启动的环境
- `core` 层只含纯文本配置；应用层由 Flatpak 分发

版本见 [`version`](version)。许可见 [`LICENSE`](LICENSE)。

---

## 一、定位

面向需要 ZFS 开机回滚与完整文本化系统定义的进阶用户。中文环境为默认配置。

### 与其他方案的形式差异

| 方案 | 回滚机制 | 系统定义形态 | 差异 |
|---|---|---|---|
| NixOS | 声明式代际 | Nix 语言 | 不引入新语言 |
| Fedora Silverblue / Bluefin | ostree 镜像 | 不可变镜像 | 保留可变系统与源码编译 |
| openSUSE Aeon | btrfs + snapper | systemd | 无 systemd；ZFS BE 为引导机制 |
| Ordo | ZFS boot environment | shell + 纯文本配置 | — |

### 明确的边界

- 只覆盖一种桌面形态，不适配通用场景
- 不引入 Nix 或其它声明式语言
- 不提供 SLA
- 首要目标是作者自用

---

## 二、设计约束

实现上只允许一种做法，不提供并行的可选路径。

| 约束 | 含义 |
|---|---|
| 一个入口 | 操作经 `ordo`：`sysup` / `snap` / `backup` / `config` / `app` / `doctor` |
| 一份配置 | `config/` 是系统定义。`/etc` 由它部署生成 |
| 一种分发 | 系统层 Portage；应用层 Flatpak |
| 一种回滚 | ZFS boot environment |
| 一处文档 | 文档与代码同仓、同版本 |

不提供的形态：

- 同时支持 systemd 与 OpenRC
- btrfs 与 ZFS 两条安装路径
- 源码编译与二进制的模糊边界
- `ordo` 承载业务逻辑

---

## 三、实现

### 1. ZFS 根

- `rpool/root/ordo`（系统）与 `rpool/home`（用户数据）为分离数据集；布局定义在 `config/dataset`
- 回滚系统不影响用户数据
- 数据集属性：`compression=zstd`、`atime=off`、`xattr=sa`

### 2. Boot Environments

- `sysup` 升级前创建快照并 hold；失败中止并输出回滚路径
- 根数据集不可在线回滚（ZFS 拒绝回滚已挂载数据集），回滚须经 ZFSBootMenu 引导快照后执行
- ZFSBootMenu 直接引导快照（以临时克隆启动），在该环境中执行 `ordo snap rollback <tag>`
- 引导失败自动回滚未实现

### 3. 配置即代码

- `config/` 为唯一事实来源：`arch`、`world`、`package.use/`、`desktop/`、`apps.d/`
- 从零构建：`install.sh`
- 增量部署：`ordo config apply <world|desktop>`；版本间结构变更由 `config/migrations/` 处理
- 验收：`ordo config verify`（声明漂移）、`ordo doctor`（约束一致性）

### 4. Flatpak 应用层

- 可在 Flatpak 中运行的应用不进 `world`
- 系统层内容：内核、ZFS、init、桌面外壳、字体、输入法、驱动、音频栈
- 应用清单定义在 `config/apps.d/`
- 判定标准：需要审计或修改的进 core，否则走 Flatpak

---

## 四、技术栈

| 层 | 组件 | 说明 |
|---|---|---|
| 底座 | Gentoo | Portage、OpenRC、ZFS 原生支持 |
| init | OpenRC | 文本配置 |
| 文件系统 | OpenZFS | 快照、回滚、压缩 |
| 引导 | ZFSBootMenu | 引导时选择 boot environment |
| 桌面 | Umbriel | Wayland 合成器，四种布局 |
| 桌面外壳 | Noctalia Shell | 顶栏/启动器/锁屏/通知/壁纸，同一程序 |
| 登录 | greetd + Noctalia Greeter | 图形界面，无 GTK/Qt 依赖 |
| 文件管理 | Luciole | 图形文件管理器 |
| 应用 | Flatpak + Flathub | 沙箱、独立更新 |
| 镜像 | USTC | 覆盖 Portage 与 distfiles |

---

## 五、包策略

| 类别 | 安装方式 | 示例 |
|---|---|---|
| 内核 / ZFS / init | Portage | `sys-kernel/*`, `sys-fs/zfs`, `sys-apps/openrc` |
| 桌面外壳 | Portage | `gui-wm/umbriel`, `gui-apps/noctalia`, `gui-apps/luciole`, `gui-libs/greetd`, `gui-apps/noctalia-greeter`, `xdg-desktop-portal-*` |
| 字体 / 输入法 | Portage | `media-fonts/noto-cjk`, `app-i18n/fcitx` + `fcitx-rime` + `fcitx-gtk` |
| 应用 | Flatpak | Firefox、LibreOffice、Telegram、VS Code、GIMP |
| 开发工具链 | Portage / 容器 | 系统级安装；项目依赖走容器 |

`world` 中不允许出现应用级包。判定方式：查 Flatpak 仓库是否提供。

---

## 六、验收标准

1. **单命令安装**：`install.sh` 完成 ZFS 根 + OpenRC + Umbriel + 中文 + Flatpak
2. **回滚可用**：`install.sh` 安装 `/etc/cron.d/ordo-snapshot`；回滚流程为 ZBM 引导快照后在快照环境执行 `ordo snap rollback <tag>`
3. **可复刻**：换机器重复安装得到相同系统。当前从零编译约 24 小时；该时间依赖尚未实现的 L2 binhost
4. **无 systemd**：`world` 与运行时均不含 systemd
5. **系统层可编译**：记录实测数据，不设时间上限
6. **中文开箱**：登录后为中文界面、可输入中文、时区正确、镜像指向 USTC
7. **可验证**：`make check` 执行 lint 与回归测试；退出码 `0` 全绿 / `1` 有问题 / `2` 无法判定

### L1 实测记录（2026-11-18）

| 项目 | 数值 |
|---|---|
| 安装包数 | 678（含依赖） |
| 全量编译耗时 | 约 24 小时（6 vCPU / 8 GB arm64 VM，含 4 轮重试） |
| 最大单包 | webkit-gtk（-j1 下约 6 小时）、llvm ×2（各 1–2 小时） |
| 启动链 | ZBM → 内核 → OpenRC → greetd → Umbriel |
| 已知偏离 | [docs/deviations.md](docs/deviations.md) |

---

## 七、非目标

- 不作为通用发行版，不提供 SLA
- 不自研包管理器与沙箱（使用 Portage 与 Flatpak）
- L1 阶段不产出 ISO 与 binhost

---

## 八、路线图

| 平台 | 当前验证范围 | 入口 |
|---|---|---|
| M2 Air 13″ (2022)，Mac14,2 | 候选包在此机型的 macOS 上通过签名、完整性和制盘预检；在 ARM64 模拟目标上从空白 USB 测试盘安装，再从默认 EFI 冷启动进入 Umbriel 和 Noctalia。先前构建已在 M2 真机进入桌面。本候选版仍待独立真机验证全新安装、AGX、内屏和回滚。 | [M2 外接盘手册](docs/manual/10-m2-external.md) |
| Apple Silicon 上的 ARM64 虚拟机 | UTM 5.0.8 已导入 0.1.0 候选盘并冷启动到首次设置密码。同一镜像的独立副本已进入 Umbriel 桌面。 | [下载包的导入步骤](docs/manual/11-utm.md) |
| amd64 PC | 参数化完成，未实测 | [x86 安装手册](docs/manual/09-x86-install.md) |

架构数据集中在 `config/arch`：stage3 地址、profile、`-march`、`VIDEO_CARDS`、
`ACCEPT_KEYWORDS` 由该文件注入。真机安装需设 `ORDO_PLATFORM=bare-metal`。

| 阶段 | 内容 | 时间 |
|---|---|---|
| L1 | VM 内完成 ZFS + OpenRC + Umbriel + 中文 + 回滚 | 2026-11-18 完成 |
| L2 | 自建 ISO；binhost（仅系统层）；`ordo` 完整 | 2–4 周 |
| L3 | x86 真机验证；Asahi 移植评估 | 1–3 个月 |

---

## 九、目录结构

```
.
├── config/                     # 系统定义（唯一事实来源）
│   ├── arch                    # 架构：stage3 URL / -march / VIDEO_CARDS
│   ├── dataset                 # 数据集布局
│   ├── world                   # 包集（裸 atom）
│   ├── world.notes             # 包的选择理由（不参与 Portage）
│   ├── world.bare-metal        # 真机追加包
│   ├── oneshot-packages        # 不进 world 的引导工具白名单
│   ├── forbidden-world         # 禁入 world 的应用级包
│   ├── apps.d/                 # Flatpak 应用清单
│   ├── migrations/             # 已装机系统的增量升级脚本
│   ├── desktop/                # 桌面配置（见该目录 README）
│   │   ├── umbriel/            # 合成器与会话脚本
│   │   ├── noctalia/           # 桌面外壳
│   │   ├── greetd/             # 登录屏配置与服务
│   │   ├── wallpapers/         # 壁纸（配色由它生成）
│   │   └── skel/               # 用户配置模板
│   ├── package.use/            # USE flag
│   ├── package.accept_keywords/
│   ├── package.mask/
│   ├── make.conf.example
│   └── zfs-arc.start           # ARC 上限（防编译期内存回收停滞）
├── scripts/                    # POSIX sh
│   ├── lib.sh                  # 公共机制：路径解析、退出码、工具检查
│   ├── ordo                    # 统一入口（委托层）
│   ├── sysup                   # 快照 → 升级 → 迁移 → 可用性校验
│   ├── doctor                  # 约束一致性与漂移检查
│   ├── ordo-config             # 配置入口
│   ├── ordo-migrate            # 迁移执行器
│   ├── ordo-selfcheck          # CLI 表与实现一致性检查
│   ├── ordo-snap(-auto)        # 快照
│   └── ordo-backup             # zfs send 离线备份
├── tests/                      # 静态检查与回归用例
├── install.sh                  # 从官方 ISO 安装
├── Makefile                    # 开发入口
├── docs/
│   ├── manual/                 # 用户手册
│   ├── decisions/              # ADR
│   └── deviations.md           # 偏离账本
├── CONTRIBUTING.md
├── SECURITY.md
├── CHANGELOG.md
├── LICENSE / LICENSE-NOTES.md
└── version
```

---

## 十、文档

| 目录 | 读者 | 内容 |
|---|---|---|
| `docs/manual/` | 使用者 | 安装、配置、运维、排障 |
| `docs/decisions/` | 需了解选型依据者 | ADR |
| `docs/deviations.md` | 审计者 | 偏离项与收回条件 |
| `docs/upstream/` | 上游贡献者 | 待提交给 Gentoo 的缺陷材料 |
| `CONTRIBUTING.md` | 修改本仓者 | 提交门禁、目录职责 |

本仓只包含系统定义。工作日志、进度记录、截图不入库。

---

## 十一、命名

**Ordo**（拉丁语：秩序）。取自 *Ordo ab chao*。

- 写法：**Ordo Linux**
- CLI / 包名 / 仓库：`ordo`、`ordo-linux`
- 版本代号：`0.1 "Ab Chao"`、`0.2 "Fons"`、`0.3 "Umbra"`

名称中不出现 Gentoo，仅在上游关系处标注 *based on Gentoo*。

---

## 许可

代码、构建工具与 `config/`：**GPL-2.0-or-later**（含 `dev/`、`tests/`、`overlay/`）。
`docs/`、根目录 Markdown、`assets/branding/` 与桌面壁纸：**CC BY-SA 4.0**。
完整文本见 [`licenses/`](licenses/)，逐路径划分见 [LICENSE-NOTES.md](LICENSE-NOTES.md)。
