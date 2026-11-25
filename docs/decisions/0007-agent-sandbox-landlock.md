# ADR 0007 — Agent 执行环境沙箱：Landlock（不引入全局 MAC）

- 状态：已采纳（原则）；实现待 L2
- 日期：2026-11-19
- 关联：deviations #30（不启用系统级 MAC）

## 一、问题陈述

Ordo 定位为 Agent OS —— 让 AI agent 在系统上安全地执行任务。这带来一个**必须回答**的安全问题：

> agent 执行的代码，凭什么信任它只能碰该碰的东西？

传统答案是 SELinux/AppArmor 这类**全局强制访问控制（MAC）**。但 Ordo 已明确不引入（deviations #30），理由成立：

- 部分实施的 MAC 成本高于收益：自研栈（会话桥、Forge、ZFS、doas）的策略需全部自行维护，
  维护不全则产生审计噪音，最终被迫关闭
- 个人桌面威胁模型下边际收益低
- 与 thin 目标冲突

由此留下空白：智能体场景需要沙箱。本 ADR 给出方案。

## 二、决策：Landlock（进程级，非系统级）

**用 Landlock + seccomp + bwrap 组合，按进程授予最小权限，不做全局策略。**

### 实测依据

L1 系统的活动 LSM（`cat /sys/kernel/security/lsm`）：

```
lockdown,capability,landlock,yama,bpf,ima,evm
```

**`landlock` 已在内核中启用** —— 无需重新编译内核，无需安装策略包，无需 relabel。这是关键前提：零基础设施成本。

### 三个组件的分工

| 组件 | 管什么 | 为什么选它 |
|---|---|---|
| **Landlock** | 文件系统路径（读/写/执行）、TCP 端口绑定与连接 | 内核 5.13+ 原生 unprivileged API；**按进程**授予，无系统策略；另一进程完全不受影响 |
| **seccomp-bpf** | 系统调用白名单 | 内核原生；拦截危险 syscall（`mount`、`ptrace`、`kexec_load`…） |
| **bubblewrap** | 命名空间隔离（挂载/PID/网络/用户） | 成熟（Flatpak 的底座）、无 root 可用、Gentoo 主树有 |

**三者互补，缺一不可**：
- Landlock 管不了「进程看到哪些挂载点」→ bwrap 管
- bwrap 管不了「同一路径内的细粒度访问」→ Landlock 管
- 两者都管不了「直接 syscall 攻击」→ seccomp 管

## 三、具体的沙箱档位（按 agent 信任等级）

| 档位 | Landlock | seccomp | bwrap | 适用场景 |
|---|---|---|---|---|
| **read-only** | 只读挂载点白名单 | 严（禁网络、禁 exec） | 只挂 `/usr`、`/lib`、目标目录只读 | 分析代码、读日志 |
| **workspace** | 读写限定在工作目录 + `/tmp` | 中（禁 mount/ptrace，允许网络） | 挂工作区 + 基础系统 | 默认档；跑构建、改代码 |
| **trusted** | 接近全权限，仅限制危险路径 | 松 | 最小命名空间隔离 | 用户显式授权的自动化 |

默认档为最小权限（workspace 或更低），提升档位需用户显式操作。

## 四、与 Flatpak 的关系（重要边界）

**Flatpak 应用不走这套**。Flatpak 已有自己的沙箱（bubblewrap + portal），且它的权限模型是应用清单声明的。

本 ADR 管的是 **agent 直接执行的代码**：
- Agent 调用的 shell 命令
- Agent 生成的脚本
- MCP server 之类的外部进程

**不要试图统一两者** —— Flatpak 的沙箱是应用级的，agent 的动态任务需要的是**运行时按任务授权**，模型不同。强行统一会同时破坏两者。

## 五、实现路径（L2）

1. **POC**：写一个 `ordo sandbox run --profile=workspace -- <command>` 包装器
   - 用 Landlock 的 C API（或 `landlock-restrict` 之类的小工具）
   - seccomp 用 libseccomp 或手写 BPF
   - 先只做文件系统限制（Landlock 部分），验证可行
2. **集成**：agent harness（ADR 0004）调用时自动套沙箱
3. **可观测**：被拒绝的操作要**明确报错并记录**（不是静默失败）——这直接对应「失败要响亮」原则
4. **测试**：doctor 增加一项检查「Landlock 可用性」（`/sys/kernel/security/lsm` 含 landlock）

## 六、不做什么（明确边界）

- 不做全局策略：不写 SELinux policy，不安装 AppArmor profile
- 不做 relabel：ZFS 上 relabel 开销高且有风险
- 不追求默认全锁：先解决 agent 场景，不加固整个系统
- 不引入容器运行时（Docker/Podman）：对单用户桌面过重，bwrap 足够

## 七、代价与风险

1. **Landlock 的覆盖范围有限**：只管文件系统和网络，不管 IPC、信号、设备。需要 seccomp 补
2. **内核版本要求**：Landlock 的 ABI 版本随内核演进，6.18 的 ABI 与未来版本可能不兼容（要按 `LANDLOCK_ABI_VERSION` 探测）
3. **对 agent 的可用性有影响**：沙箱过严会让 agent 频繁失败。必须提供清晰的错误信息 + 易用的档位切换
4. **这不是「安全银弹」**：它防的是「agent 误操作」，不是「恶意内核级攻击者」

## 八、为什么这个决策符合 Ordo 哲学

| 公理 | 如何满足 |
|---|---|
| **thin** | 不引入策略包、不 relabel、不装守护进程；三个组件都是内核原生或极小工具 |
| **standard** | Landlock/seccomp 是 Linux 标准接口；bwrap 是 Flatpak 的官方底座；全部在主树 |
| **rollbackable** | 沙箱是**运行时**的，不影响系统状态；关掉包装器立刻恢复 |
| **只做该做的** | 解决 agent 场景的实际需求，不为了「安全」而加固整个系统 |

## 参考

- [Landlock 内核文档](https://docs.kernel.org/userspace-api/landlock.html)
- [bubblewrap](https://github.com/containers/bubblewrap)
- [seccomp](https://www.kernel.org/doc/html/latest/userspace-api/seccomp_filter.html)
- deviations.md #30（不启用系统级 MAC 的决策与本 ADR 的关系）
