# ADR 0008 — OneConfig：单一配置入口 + 分层包管理

- 状态：已采纳
- 日期：2026-11-19
- 关联：ADR 0003（选型公理）、ADR 0006（桌面栈选型）

## 一、问题陈述

Ordo 的配置分散在多个入口：`install.sh`（安装）、`config/world`（包集）、
`config/portage/*`（USE/keyword）、`config/kde/`（桌面外观）、`config/desktop/skel/`（用户
dotfiles）、`scripts/`（系统工具）。这带来两个问题：

1. **用户心智负担**：想改一个东西，得先知道它归哪个目录
2. **漂移风险**：同一个语义在两处定义（如 world 里 grub 与 ZBM 并存的历史问题）

同时，"核心包用 Portage 编译、应用走 Flatpak"这条分层原则，此前只写在
宪法的一句话里，没有明确的边界判据——什么算"核心"、什么算"应用"，靠感觉。

## 二、决策

### 2.1 OneConfig：一个入口，一个真相

**所有可配置项收敛到 `config/` 下，由 `ordo config` 统一读写。**

```
config/
├── world                    # 系统包集（Portage）
├── arch                     # 架构/CPU/显卡
├── dataset                  # ZFS 布局（POOL/DATASET/HOME_DATASET）
├── portage/                 # USE / keyword / mask
├── kde/                     # 桌面外观（配色/面板/快捷键/壁纸）
├── skel/                    # 用户默认 dotfiles
├── greetd/                  # 登录管理器配置与服务
└── forbidden-world          # 应用级包黑名单（防 Portage/Flatpak 越界）
```

**规则**：
- **单一真相源**：任何配置只有一个定义处，其他地方只能引用
- **可验证**：`ordo config verify` 检查配置与运行系统是否漂移
- **可回滚**：所有配置在 ZFS BE 内，回滚系统 = 回滚配置
- **幂等应用**：`ordo config apply <模块>` 可重复执行，结果一致

**`ordo config` 子命令（L2 落地）**：

| 命令 | 作用 |
|---|---|
| `ordo config show` | 显示当前生效的完整配置 |
| `ordo config verify` | 检查配置 vs 实际系统的漂移 |
| `ordo config apply theme` | 从调色板派生各组件颜色 |
| `ordo config apply desktop` | 部署 niri / ashell 配置到家目录 |
| `ordo config apply world` | 同步包集到 Portage |
| `ordo config diff` | 对比仓库配置与系统实际状态 |

### 2.2 分层包管理：明确的边界判据

**判据不是"大小"，而是"是否需要与系统深度耦合"。**

| 层 | 载体 | 判据 | 例子 |
|---|---|---|---|
| **核心** | **Portage（源码编译）** | 需要内核模块、init 脚本、系统服务、PAM、或与 ZFS/BE 生命周期耦合 | zfs、openrc、elogind、greetd、tuigreet、fcitx5、chrony、字体 |
| **应用** | **Flatpak** | 纯用户态、有自己的更新节奏、不需要系统集成 | Chrome、VS Code、Spotify、Obsidian、Steam |
| **禁止** | 两者都不进 | 违反 thin/standard 的 | 见 `config/forbidden-world` |

**为什么核心必须编译**（不是偏好，是技术要求）：

1. **USE flag 决定能力**：`plasma-desktop` 的 `flatpak` USE 决定 Discover 能否管理 Flatpak；Flatpak 版无法改
2. **内核耦合**：ZFS 模块必须对着本机内核编译，Flatpak 做不到
3. **init 集成**：OpenRC 服务、PAM 栈、logind 会话——都是系统层
4. **BE 一致性**：核心包进 BE 快照，回滚时一起回退；Flatpak 应用在 `/var` 之外，回滚不涉及

**为什么应用必须 Flatpak**：

1. **回滚独立性**：应用更新失败不影响系统，反之亦然
2. **更新节奏**：浏览器每周更新，不该触发系统重编译
3. **隔离**：Flatpak 自带沙箱（bubblewrap + portal）
4. **一致性**：同一份 Flatpak 在 Ordo/其他发行版行为一致

### 2.3 自由回滚：三层回滚能力

| 层 | 机制 | 回滚粒度 | 命令 |
|---|---|---|---|
| **系统** | ZFS BE + ZBM | 整个系统（内核+用户态+配置） | `ordo snap rollback` / ZBM Ctrl+X |
| **配置** | 配置在 BE 内 | 跟随系统回滚 | 自动 |
| **应用** | Flatpak 自身 | 单个应用版本 | `flatpak update --commit=<hash>` |

**关键设计**：配置放在 BE 内（`/etc`、`/usr`），应用数据在 `/home` 与
`/var/lib/flatpak`——所以**回滚系统不影响用户数据和已装应用**，
这正是 ADR 0002 §5「回滚 BE 不回滚 /home」的延伸。

## 三、与既有 ADR 的关系

- **ADR 0003（选型公理）**：OneConfig 是"thin"的具体化——一个入口比七个薄
- **ADR 0006（桌面栈）**：`config/kde/` 是 KDE 外观的落地位置
- **ADR 0002（内核与引导）**：配置在 BE 内，随 BE 回滚

## 四、落地路径

| 阶段 | 内容 | 状态 |
|---|---|---|
| L1 | `config/` 目录结构 + `install.sh` 读取 | 已有，分散 |
| L1.5 | `config/kde/` 主题包 + `apply.sh` | 待做 |
| L2 | `ordo config` 子命令（show/verify/apply/diff） | 待做 |
| L2 | `config verify` 进 doctor | 待做 |

## 五、不做什么

- 不做 GUI 配置中心：桌面环境自带的设置已覆盖，Ordo 只管理发行版级配置
- 不接管应用配置：`~/.config/` 归用户，Ordo 只提供 skel 默认值
- 不做配置版本控制服务：git 已足够，ZFS 快照作为后备
- 不追求所有配置热应用：需要重启的场景明确标注

## 六、代价

1. **`ordo config` 是新增抽象**：多一层就多一层出错可能（缓解：先只做 apply/verify，不做花哨功能）
2. **配置与代码的边界**：有些"配置"其实是代码（如面板布局 JS），需要明确标注
3. **迁移成本**：现有分散配置要逐步收敛，不是一次到位

## 参考

- 宪法（README.md）"config-as-code" 与 "Flatpak-first"
- ADR 0003（thin · stable · standard · rollbackable）
- `config/forbidden-world`（边界执行机制）
