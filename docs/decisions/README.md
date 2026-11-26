# 架构决策记录（ADR）

> 记录「为什么这么选」，不是「怎么用」。用法看 [`../manual/`](../manual/00-index.md)。

## 索引

| # | 标题 | 状态 | 一句话 |
|---|---|---|---|
| [0001](0001-底座选型.md) | 底座选型 | 已采纳 | 为什么是 Gentoo 而不是 Arch/NixOS |
| [0002](0002-内核与引导.md) | 内核与引导 | 已采纳 | ZFS root + dracut + ZFSBootMenu 的完整链 |
| [0003](0003-选型公理与binhost.md) | 选型公理与 binhost | 已采纳 | 公理：能落成数据的不落成代码 |
| [0004](0004-agent-os-harness.md) | Agent OS harness | 已采纳 | 面向智能体时代的操作系统设计 |
| [0005](0005-gnome50-openrc集成.md) | GNOME 50 + OpenRC | 已采纳 | 登录框不可见问题的定位与修复（GNOME 已退场） |
| [0006](0006-桌面栈选型KDE.md) | 桌面栈选型 KDE | **被 0009 取代** | 当时选 KDE 的理由与后续证伪 |
| [0007](0007-agent-sandbox-landlock.md) | Agent 沙箱 | 已采纳（原则） | landlock + bubblewrap，实现待 L2 |
| [0008](0008-oneconfig-分层包管理.md) | OneConfig 分层包管理 | 已采纳 | core=Portage / app=Flatpak 的边界 |
| [0009](0009-桌面栈终审-niri.md) | 桌面栈终审 niri | **被 0011 取代** | KWin 三缺陷 → niri + ashell 定案 |
| [0010](0010-会话总线与输入法环境.md) | 会话总线与输入法环境 | 已采纳 | Gentoo 双 dbus、GTK_IM_MODULE=wayland、VM 必须带 GL |
| [0011](0011-桌面栈-Noctalia全家桶.md) | 桌面栈 Noctalia 全家桶 | 已采纳 | 六组件拼装 → 五件套同源；壁纸驱动配色 |
| [0012](0012-平台扩展-AppleSiliconM2.md) | 平台扩展 Apple Silicon M2 | 提案（立档未实施） | 四支柱裸机双引导；阶段 B 准入：磁盘 ≥60GB |
| [0013](0013-阶段B-引导链最小验证.md) | 阶段 B 准入重估 | 提案 | 60GB 只管完整安装；引导链验证降到 ~18GB，四条判据阶梯 |
| [0014](0014-binpkg签名策略.md) | 二进制包签名策略 | 已采纳 | 远端 binhost 必须验签；离线介质由签名发布清单锚定，禁用项限定在本地 merge |

## 写法约定

每篇必须有：

```markdown
# ADR NNNN — 标题

- 状态：已采纳 | 提案 | 被 ADR XXXX 取代 | 已废弃
- 日期：YYYY-MM-DD
- 取代 / 关联：ADR XXXX、deviations #N

## 一、问题陈述
## 二、候选评估（表格）
## 三、决定
## 四、后果（好的与坏的）
## 五、证据（实测输出/截图/复现命令）
```

**关键**：`## 五、证据` 不能省。没有证据的 ADR 只是意见。
被后续 ADR 取代时，**必须**回到旧 ADR 改状态行——否则读者会以为它还有效。

## 与偏离账本的分工

| | ADR | deviations.md |
|---|---|---|
| 记什么 | 「选了什么、为什么」 | 「哪里妥协了、何时收回」 |
| 生命周期 | 长期有效（除非被取代） | 有明确收回条件 |
| 例子 | 为什么选 niri | 全局 `~arm64` keyword |

一个决策可能同时出现在两处：ADR 0011 定了 Umbriel（决策），
deviations #44 记着 Hyprland 不可用（限制）。
