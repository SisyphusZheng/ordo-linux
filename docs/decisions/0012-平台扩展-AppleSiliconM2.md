# ADR 0012 — 平台扩展：Apple Silicon（M2）原生目标

- 状态：提案（立档；阶段 B 准入条件未满足，见证据节）
- 日期：2026-11-22
- 关联：ADR 0001（Gentoo 底座）、ADR 0002（内核与引导：ZFS/ZBM）、ADR 0011（Noctalia 全家桶）、deviations #49（/boot-on-ESP）、#64（部署规程）
- 立场：本机（MacBook Air M2）为首个裸机靶机；UTM VM 保留为 aarch64 验证机

## 一、问题陈述

「Ordo on M2」已存在两种形态。虚拟层（UTM VM，aarch64）已完整验收——本轮三方对抗后 doctor 仅余偏离 #49 两项红。用户提出裸机原生目标：Ordo 以双引导形态装进 M2 Mac 本机（DHH「Omarchy for Apple Silicon 4.5+」的同款形态），要求四支柱（Gentoo / OpenZFS / OpenRC / Noctalia）在消费级 ARM 硬件上不缩水。

## 二、候选评估

| 路线 | 地基 | 四支柱 | 工作量 | 判定 |
|---|---|---|---|---|
| A. 继续 UTM VM | 现状 | 全绿（本轮验收） | 0 | 已达成；保留为 aarch64 编译/验证机 |
| **B. Asahi UEFI-only + Gentoo Project:Asahi** | Asahi 2026 对 M2 系 "just work"（Mesa GPU/WiFi/NVMe/键盘音频全绿）+ 官方可引导介质 + OpenRC 专项指南 + Installer UEFI-only 模式 | Gentoo ✓ OpenRC ✓ OpenZFS ～（ZBM 启动链待验）Noctalia ～（Mesa 加速待验） | 中：先手工最小验证，再声明化 | **选定** |
| C. Omarchy Mac 式整体接管 | Omacom 安装器（同 Asahi 地基） | Arch/systemd/Hyprland——三项支柱全换 | — | 驳回：等于放弃四支柱 |

## 三、决定

1. **定位缩窄（2026-11-22 二次裁定）**：Ordo 定位收敛为 **Apple Silicon MacBook 专属系统定义**——双引导 + 外置便携盘（桩装过的 M1/M2 Mac 之间系统盘即插即用）为唯一产品形态；x86_64 通用发行线（amd64 ISO/bootstrap）冻结不做，直到 MacBook 形态验证完成。
2. Apple Silicon（M2）列为 Ordo 第二目标平台；首靶 MacBook Air M2（`hw.model=Mac14,2`）。
3. 三阶段推进，本文档只立档不实施：
   - 阶段 A（已完成）：UTM VM = aarch64 验证机（本轮对抗验收）
   - 阶段 B：Asahi Installer「UEFI-only」模式 + Project:Asahi/Guide 手工最小安装，验证 **ZFS root + ZFSBootMenu 在 m1n1→U-Boot→ESP 启动链下的形态**——全项目最大技术未知数，此关不过则回 C 前先重估
   - 阶段 C：`install.sh --target asahi` 声明化（config/arch aarch64 分支、asahi-sources 替代 gentoo-kernel-bin、固件包、偏离 #49 的 ESP 设计在 Asahi 语境重做、doctor 平台判据读 /proc/device-tree 识别机型）
4. Noctalia 全家桶零改动：纯 Wayland + wlroots 系，Asahi Mesa 加速为常规形态；aarch64 编译问题已在 VM 验证过。
5. 维护面承认翻倍（x86_64 + aarch64 两条 world/内核线），binhost 策略（ADR 0003）随之需第二构建目标——阶段 C 再议。

## 四、后果（好的与坏的）

好的：四支柱站上消费级 ARM 硬件；VM 验证机资产直接复用；Noctalia 与桌面声明零改动带走；与 Omarchy Mac 同台对比有了实证基础。
坏的：ZBM 启动链不确定（B 阶段核心风险）；维护面翻倍；内核/固件跟随 Asahi 节奏（跟不上就停在旧内核）；M4+ 暂不在 Asahi 支持内。

## 五、证据

- Asahi M2 支持矩阵：https://asahilinux.org/docs/platform/feature-support/m2 （官方口径 "M2 series machines just work"，2026）
- Gentoo Project:Asahi/Guide（2026-03 更新，官方可引导介质与 asahi-sources）：https://wiki.gentoo.org/wiki/Project:Asahi/Guide
- Asahi Installer「UEFI environment only」选项（专为 Gentoo 类发行版设计）：Asahi Progress Report: Linux 7.0（2026-04）
- 本机身份与磁盘实况（2026-11-22）：`hw.model=Mac14,2`（MacBook Air M2）；`df -h /System/Volumes/Data` → 228Gi 总量 / 已用 179Gi / **可用 6.2Gi（97% 满）**
- **阶段 B 准入未满足**：裸机安装需 ≥60GB 独立分区，当前磁盘必须先清理或改用外置 NVMe 介质——在此之前本 ADR 不进入实施
- **已有基线（2026-11-22 实查）**：VM 引导链为 edk2 → `\EFI\ZBM\vmlinuz.EFI`（efibootmgr Boot0006 "Ordo Linux"）——**aarch64 ZBM 的构建与引导 ZFS root 已被本 VM 实证**，阶段 B 的未知数收敛为纯硬件三条：U-Boot EFI 与 edk2 的实现差异、ZBM 以 asahi 内核重生成、kexec 切换 asahi 内核时的 Apple DTB 传递
- install.sh 未做任何 asahi 分支改动（立档不实施）；VM 侧本轮已完成全部 aarch64 用户体验验证（对抗轮 16 commit）
