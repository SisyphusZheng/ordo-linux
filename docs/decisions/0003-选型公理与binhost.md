# ADR 0003 — 选型公理、未决槽位与 binhost 定案

- 状态：已采纳
- 日期：2026-11-18

## 一、选型公理

已定选型遵循同一规则：

> 每一层选择该类别中框架性最低的组件：文本可读优于二进制状态，
> 单一工具优于组合套件，上游标准优于自研。

引入新组件前须通过三项判断：

1. 能否用数据表达（配置、清单、掩码），而非代码逻辑
2. 能否委托现有工具（zfs、emerge、flatpak、cron），而非自建守护进程
3. 失败时行为是否可预期（报错并给出路径，而非静默吞掉）

### 已定选型的公理对账

| 层 | 选型 | 为什么符合 |
|---|---|---|
| 底座 | Gentoo | 源码透明，构建过程即文档 |
| init | OpenRC | 纯文本 init 脚本，一个服务一个文件 |
| FS | OpenZFS | 该类别唯一自带 BE 语义的标准件 |
| 引导 | ZFSBootMenu | 无 grub.cfg——开机自己扫 pool，零配置文件 |
| 脚本 | POSIX sh | 无语言依赖，任何 Unix 上可读 |
| 权限 | doas | OpenBSD 出品，单行配置 |
| 输入法 | ibus | GNOME 原生集成（fcitx5 不在树中，见 deviations #6） |
| 应用 | Flatpak | 该类别唯一成标准的沙箱 |
| 音频 | pipewire | GNOME 50 默认，取代 pulseaudio |

### 公理的适用边界

NTP 选型时曾考虑 openntpd（与 doas 同属 OpenBSD 项目）。
本系统运行于 VM，时钟漂移幅度较大，openntpd 仅能 slew 微调，无法跟上。
chrony 针对该场景设计。

结论：选 chrony。来源一致性不构成选型依据，工程匹配才是。
公理是「上游标准优于自研偏好」，不是「同源家族优先」。

## 二、未决槽位（现在定案，避免 L2/L3 临场乱拍）

| 槽位 | 定案 | 理由 |
|---|---|---|
| cron | **cronie** | 支持 `/etc/cron.d` 丢弃式任务 + **补跑错过的任务**（binhost 机器会重启/睡眠，补跑是刚需） |
| 日志 | **sysklogd + logrotate** | 目标只是别丢内核/崩溃消息；syslog-ng 的配置语言是"为 1% 需求背 100% 复杂度" |
| NTP | **chrony** | VM 时钟漂移专治（见上文反例） |
| L2 ISO 构建 | **复用 install.sh**，不引入 catalyst | ISO = 可引导最小环境 + 仓库 tarball，进去跑同一条 install.sh；构建/安装/验收走同一条代码路径 |
| binhost 传输 | **rsync 推送 + 静态 http 拉取** | `PORTAGE_BINHOST` 只认 http(s)；rsync 负责同步，http 负责分发，角色分离 |
| 真机固件 | **linux-firmware + wpa_supplicant + power-profiles-daemon** | 见 `config/package.use/real-hardware`（L3 启用） |

## 三、binhost 定案

### 通道：GitHub Releases，tag 钉住

```
binhost = GitHub Releases
├── 每轮重建发布为带版本 tag 的 release（如 binhost-0.1.0+20260115）
├── 用户 BINHOST= 指向 tag 固定 URL（immutable，永远自洽）
└── sysup 解析最新 tag 并改一行配置（委托给 gh/sed）
```

**为什么不用 `/releases/latest/download/`**：该 URL 是活的——重建瞬间切到新
release，emerge 正在拉包时会拿到"半套旧 + 半套新"。tag 固定 URL 消除此风险。

**为什么不用 CF R2 / 对象存储**：国内可达性问题用户已接受（deviations #12）。
哑管道结构保留——哪天需要，目录搬过去即可。

### 管线（cronie，双周）

```
cron（双周）
  → emerge --sync && emerge -uDN @world   # FEATURES=buildpkg 顺手产 binpkg
  → rsync 到 staging 目录                  # 先编后发，不半途暴露
  → gh release upload（新 tag）            # 原子发布
```

### 客户端

```sh
# make.conf
BINHOST="https://github.com/<user>/<repo>/releases/download/binhost-0.1.0+20260115"
FEATURES="${FEATURES} getbinpkg"
```

## 四、L2 技术选型边界（提前写死，防滑坡）

- **不自研 ISO 构建器**：stage3 tarball + 脚本就是 Unix 答案
- **不写更新守护进程**：cron + 静态目录就是 Unix 答案
- **不做镜像切换逻辑**：单通道，需要时换 URL 即可

## 五、后果

- `config/world` 需在 L2 加入 `sys-apps/cronie`、`net-misc/chrony`、`app-admin/sysklogd`
- `docs/deviations.md` 的 #12（单通道）与 #4（zfs/内核版本锁）需在 L2 重新评估
- 真机（L3）启用 `config/package.use/real-hardware` + 改 make.conf 的
  `COMMON_FLAGS` / `VIDEO_CARDS` / `ACCEPT_KEYWORDS`
