# 偏离账本

本文件登记所有与设计约束不一致的实现选择，以及已知限制。每条包含：偏离内容、原因、收回条件或当前状态。

新增偏离须先登记再实施。

---

## 一、L1 阶段

| # | 偏离 | 原因 | 收回条件 / 状态 |
|---|---|---|---|
| 1 | 全局 `ACCEPT_KEYWORDS=~arm64` | GNOME 50 全栈在 arm64 上未全部稳定；逐包 pin 会导致 keyword 缺失组合过多 | arm64 稳定后收紧（L2 期间）。`doctor` 对该项报 warn |
| 2 | `llvm-core/llvm -binutils-plugin` | 该 USE 默认会为每个 llvm slot 引入 llvmgold，额外编译整条 llvm（1–2 小时） | 上游不再默认开启时 |
| 3 | `dev-python/pillow -truetype` 破环种子 | `docutils→pillow→harfbuzz→glib→docutils` 循环依赖；该做法为 emerge 给出的处方 | 上游修复该循环后。种子已登记于 `config/oneshot-packages` |
| 4 | `zfs 2.4.4` + 内核限制 6.18 | zfs 硬限 `MODULES_KERNEL_MAX=7.2`，树内最新内核为 7.3.4；且 live ISO 的 2.4.4 创建的 pool 需 >= 2.4.4 才能写入 | 上游 zfs 支持 7.3 后（OpenZFS 通常滞后 1–3 个月）。当前由 `config/package.mask/l1-zfs-pin` 屏蔽 `>=7.3` |
| 5 | `spl_hostid=0` | pool 由 live 环境（hostid=0）创建 | 下一次全新安装。`install.sh` 已执行 `zgenhostid -f` |
| 6 | ~~输入法从 fcitx5 改 ibus~~ | ~~fcitx5 不在 Gentoo 主树也不在 GURU~~ | 已收回（2026-11-21）：改用 fcitx5 + rime |
| 7 | `-march=armv8.2-a` + `VIDEO_CARDS="virtio virgl"` | L1 目标为 arm64 VM | L3 真机验证时按硬件修改 `config/arch` |

## 二、流程

| # | 偏离 | 原因 | 收回条件 / 状态 |
|---|---|---|---|
| 8 | ~~`sudo` 与 `doas` 并存~~ | ~~过渡期保留~~ | 已收回（2026-11-18）：sudo 已从 world 移除 |
| 9 | 手动驱动 chroot（绕过 `install.sh` 的 chroot 段） | 编译中断后需续跑，完整重跑代价过高 | 下次完整验收时。`install.sh` 已修正 |
| 10 | ~~EFI 启动项需手动引导~~ | ~~vars.fd 被覆盖~~ | 已收回：vm.sh 分离 iso/disk 的 vars；ZBM 装至 `/EFI/BOOT/BOOTAA64.EFI` |
| 11 | ~~`ordo` CLI 未自动安装~~ | ~~`install.sh` 缺此段~~ | 已收回：`install.sh` 已包含安装与自检 |
| 12 | 单一 binhost = GitHub Releases | 国内可达性降低 | 出现国内用户需求时。当前 binhost 未实现 |
| 13 | ~~`doas permit nopass :wheel`~~ | ~~`persist` 需 TTY 输密码，SSH/脚本环境不可用~~ | 已收回（2026-11-21）：默认 `permit persist :wheel`；`ORDO_DOAS_NOPASS=1` 才免密 |
| 14 | ~~root 密码未设置~~ | ~~单用户救援不可用~~ | 已收回（2026-11-21）：默认 `passwd -l root`；`ORDO_ROOT_PASSWORD` 可设 |

## 三、GNOME 50 + OpenRC 集成（2026-11-18）

以下 9 项已固化进 `install.sh`。GNOME 已随 ADR 0009 退场，本节保留为修复记录。

| # | 问题 | 根因 | 修复 |
|---|---|---|---|
| 15 | 登录框不可见 | `install.sh` 把 3840×2160 壁纸复制为 `/usr/share/pixmaps/gentoo-gdm.svg`。GDM 以 `St.TextureCache.load_file_async(file, -1, -1)` 按原始像素加载 logo，4K 图撑满 `login-dialog-logo-bin` 覆盖对话框 | logo 使用 128×128 `ordo-logo.svg` |
| 16 | `custom.conf` 被整体覆盖 | `printf > /etc/gdm/custom.conf` 清除其它 GDM 配置 | 写完整模板；logo 经 dconf |
| 17 | 手写 `/etc/init.d/gdm` | 绕过 Gentoo 的 `display-manager` 机制 | 装 `gui-libs/display-manager-init`，设 `DISPLAYMANAGER` |
| 18 | 会话总线分裂 | 用户 `dbus` 服务不在 boot runlevel，`gdm-wayland-session` 自建 `/tmp/dbus-xxx` | 在用户 boot runlevel 加入 `dbus` |
| 19 | `pam_openrc.so` 位置错误 | 位于 `pam_elogind` 之前，此时 `/run/user/$uid` 未就绪 | 追加至 PAM 栈末尾 |
| 20 | greeter 读不到 dconf | gdm 期望 `/usr/share/dconf/profile/gdm`，dconf 只读 `/etc/dconf/profile/` | 建立符号链接 |
| 21 | `ebegin: 未找到命令` | 非 TTY 下 `functions.sh` 将 `ebegin` 委托给外部二进制，而用户服务 PATH 不含 `/usr/libexec/rc/bin` | 将 `rc/bin/*` 软链至 `/bin` |
| 22 | `gnome-settings-daemon` 无法启动 | 上游脚本使用 `supervisor=supervise-daemon` 但无 `command=` | 移除该行，退化为 meta 服务 |
| 23 | 主题 CSS 加载失败 | GNOME 50 gresource 仅有 `-dark/-light/-high-contrast` 变体，`_getStylesheet()` 期望的 `gnome-shell.css` 不存在 | 解压主题至 `/usr/share/gnome-shell/theme/`，缺文件时以 dark 变体顶替 |

## 四、已修复项（2026-11-18）

- `rpool/root/nixos` 命名残留 → `rpool/root/ordo`
- 删除 `--complete-graph`（新装系统的假冲突源）
- `doctor` 的 bad/warn 计数互相覆盖
- 数据集 `mountpoint=/` → `legacy`（`root=ZFS=` 的硬性要求，见 ADR 0002）

## 五、上游贡献判定规则（2026-11-18）

提交上游贡献须同时满足三项，缺一视为未验证：

1. 可引用的上游源码行号
2. 干净环境下的复现输出
3. 排除自身配置问题

报前先确认该包是否由 Portage 管理（`ls /var/db/pkg/<cat>/ | grep <pkg>`）。涉及 eclass 机制时须读 eclass 实现，不能只依据 ebuild 中的 grep 结果。

Gentoo 仓库现状：主树 `github.com/gentoo/gentoo` 为只读镜像，不接受 PR；GURU 亦为镜像，优先 Codeberg；主树修改只能经 `bugs.gentoo.org`。

## 六、显性决策：不引入（2026-11-19）

| # | 决策 | 原因 | 重审条件 |
|---|---|---|---|
| 30 | 不启用系统级 MAC（SELinux / AppArmor） | 内核侧 `CONFIG_LSM="landlock,yama,bpf"` 未启用二者，无策略包与用户态工具。部分启用的 MAC 需自养全部策略，否则产生审计噪音 | Agent 沙箱使用 Landlock（活动 LSM 已含）。若目标转向 hardened 或多用户服务器，先立 ADR 评估 AppArmor per-app profiles |

## 七、KDE 桌面栈实测（2026-11-19）

KDE 已随 ADR 0009 退场，本节保留为记录。

| # | 问题 | 原因 | 状态 |
|---|---|---|---|
| 31 | `plasma-workspace` 与 `plasma-desktop` 分层 | 前者只提供 plasmashell / kwin / 会话启动；桌面 shell（`/usr/share/plasma/shells/`、面板、containments）在后者。仅装前者时进程启动、日志无错误、屏幕全黑 | 已记录。包级归因未在 ebuild 层逐行核实 |
| 32 | VM 仅 1 核可用，根因为 ZBM kexec 不重置 PSCI CPU 状态 | 对照实验：ZBM kexec 路径 `nproc=1`，CPU1-3 超时后 `failed to come online`；QEMU `-kernel` 直启 `nproc=4`。`acpi=off` 亦复现。ZBM 3.1.0 的 `zkexec` 无 CPU 处理 | 已定案，ZBM 层无解；真机不受影响。VM 开发期 CPU 敏感任务用 `-kernel` 直启 |
| 33 | `plasmashell` 报 `starting invalid corona` | 同 #31 | 记录 |
| 34 | `startplasma-wayland` 挂起且无日志 | 手动/setsid 启动时缺 `DBUS_SESSION_BUS_ADDRESS` | 手动调试须显式设置该变量 |
| 35 | KWin 报 `no outputs - creating placeholder screen` | `loginctl show-seat seat0` 的 `ActiveSession` 为空，elogind 不授予 DRM master，KWin 只能打开 `renderD128` 而非 `card0` | 手动 pkill 会丢失会话归属；恢复用 `rc-service display-manager restart`。判据：`ActiveSession` 非空 |
| 36 | `tar --strip-components` 破坏主题目录结构 | 包内 `ordo/*` 被剥至 `themes/*`，`metadata.desktop` 落到根目录，SDDM 回退默认主题 | 打包层级须与目标一致；解包后须 `ls` 验证 |
| 37 | `/etc/sddm.conf.d/` 下任意 `*.conf` 均被读取 | 备份文件 `*.conf.bak-*` 仍在目录内并覆盖主配置 | 备份移出 `conf.d/` |
| 38 | QML 根项尺寸须取真实分辨率 | 根 `Rectangle` 写死尺寸且未用 `primaryScreen`，高分辨率下背景只覆盖局部；`anchors.fill: parent` 无效 | 用 `primaryScreen.width/height`；验收以 guest 内 `xwd` 抓图为准 |

取证顺序：`dmesg` / 日志原文 → `loginctl` seat 状态 → 进程 fd 指向的 `/dev/dri` 节点 → guest 内 `xwd` 截图。外部观察（截图）只能证明未观察到，不能证明未发生。

## 八、迁移到 niri 后的偏离（2026-11-20）

| # | 偏离 / 限制 | 原因 | 收回条件 / 状态 |
|---|---|---|---|
| 40 | `dconf` 归入应用层 | core（Portage）为纯文本；`sys-apps/flatpak` 硬依赖 `gnome-base/dconf`，属应用层成本 | 不收回，为分层边界 |
| 41 | ~~Rust 工程在 VM 内无法编译~~ | ~~判断为内存不足~~ | 已撤销（2026-11-21）：根因为 ARC 未限（见 #48）。实测 4 vCPU / 8 GB 内各约 2 分钟编完 |
| 42 | ~~ashell 放弃~~ | ~~clang-22 编不完~~ | 已撤销：ARC 修复后 clang 45 分钟编完。已装 `gui-apps/ashell-0.9.0::guru` |
| 43 | ~~niri 无原生 X11 支持~~ | ~~bindgen 缺 `libclang.so`~~ | 已撤销：`libclang.so` 实际位于 `/usr/lib/llvm/22/lib64/`。已装 `gui-apps/xwayland-satellite-0.8.3-r1::guru` |
| 44 | Hyprland 全家桶不可用 | 15 个包均不在 Gentoo 树；自写 15 个 ebuild 与薄委托层冲突 | 社区打包后 |
| 45 | 无取色器 | hyprpicker 无包亦无等价替代 | 不收回；可由 `grim` + ImageMagick 手动实现 |
| 46 | ~~文件管理器 Nautilus → nnn~~ | ~~Nautilus 为 GTK4 会写 dconf~~ | 已收回：实际使用 yazi（Rust，纯文本配置）；nnn 已不在 world |
| 47 | dbus-broker 不引入 | `dbus-broker-37-r1` 硬依赖 `>=sys-apps/systemd-230`，并带入 24 个依赖包 | 不引入 |
| 47a | GTK4 图标与主题须经 gsettings 设置 | GTK4 不读 `~/.config/gtk-4.0/settings.ini`，只读 gsettings（dconf）。实测 `settings.ini` 中 `gtk-icon-theme-name` 无效，`gsettings set` 立即生效 | 不收回：GTK4 的机制。core 配置仍为纯文本，仅 GTK 应用偏好走 dconf |
| 48 | ZFS ARC 未设上限导致编译期内存回收停滞 | `zfs_arc_max=0` 时 ARC 占用约 85% 内存。编译高内存占用包时触发 direct reclaim：OOM killer 无法调度、网络中断处理停滞、guest agent 无响应，vCPU 满载但磁盘零写入。取证：qcow2 mtime 停滞 → `arp -an` 显示 `(incomplete)` → 全网段无响应 → `utmctl exec` 无响应 → `sample` 显示 4 线程阻塞于 `hvf_vcpu_exec` | 已修复：`config/zfs-arc.start` 通过 OpenRC local 服务写入 sysfs（`root=ZFS=` 使 modprobe.d 被绕过）。实测 clang-22.1.8 由停滞转为 45 分钟完成。`doctor` 已加判据 |
| 49 | 本 VM 的 `/boot` 挂载于 ESP，数据集内 `/boot` 无内核镜像 | `install.sh` 要求 ESP 只挂 `/efi`，因 ZBM 扫描数据集内 `/boot`。当前 `vmlinuz-*` 仅存在于 ESP | 待重新安装解决。`doctor` 已守门 |

## 九、对账（2026-11-21）

> 本节编号独立：#50–61 只在本节内有意义，与第十一节的 #58/59/60 无关
> （两节各自追加所致，不做全局重编号）。

### 已收回

| # | 条目 | 收回方式 |
|---|---|---|
| 1 | 全局 `ACCEPT_KEYWORDS=~arm64` | 未收回；`doctor` 已加判据 |
| 6 | 输入法 ibus → fcitx5 | `install.sh` 删除全部 GNOME `input-sources` 配置，改为 `/etc/env.d/99imm` + fcitx5 |
| 12 | 单一 binhost | binhost 未实现，条目不适用 |
| 13 | `doas nopass` | 默认改为 `permit persist :wheel` |
| 14 | root 密码未设置 | 默认 `passwd -l root` |
| 46 | 文件管理器 | 改用 yazi |
| 40 / 47a | dconf 归入应用层 | 不收回，为设计边界 |

### 编号说明

条目编号存在乱序：#39 位于 #30 之前，#47a 位于 #47 之前。内容完整，为章节追加所致。

### 新增登记

| # | 偏离 | 原因 | 收回条件 |
|---|---|---|---|
| 50 | 不设置 `GLFW_IM_MODULE` | 该变量只接受 ibus 协议名；设置后要求系统存在 ibus 兼容层 | GLFW 应用需要输入法且 fcitx5 提供原生后端时 |
| 51 | stage3 清单 PGP 验签默认关闭 | 不在安装器中内置可能过期的信任根。默认仅做 SHA256 摘要比对 | Gentoo releng 公钥随仓库分发并定期更新时 |
| 52 | 无防火墙默认规则 | 默认不启用 sshd，为单用户桌面机 | L3 真机阶段，与 `ORDO_SSH` 联动 |
| 53 | 无 faillock | 同上；`doas` 默认需密码且 root 已锁定 | L3 |
| 54 | `pipewire` 进入 world | 音频为系统服务，Flatpak 应用经 socket 连接，沙箱无法自行提供 | 不收回，为分层结论 |
| 55 | `media-fonts/nerdfonts` keyword 变动时的回退 | 图标字体缺失会导致状态栏显示为方框 | 上游 keyword 稳定后。回退方案为 `symbols-nerd-font` + `jetbrains-mono` |
| 57 | 不安装 `fcitx-gtk` / `fcitx-qt` / `fcitx-configtool` | 三者分别引入 GTK immodule、Qt 插件与 Qt 图形配置工具。fcitx5 自带 `libwaylandim.so`，经 text-input-v3 协议向合成器提供输入法，niri 下无需各工具包的前端 | 需要图形配置界面时单独装 `fcitx-configtool`（会引入 Qt）；或在非 Wayland 合成器下使用 |
| 58 | `wpa_supplicant` 关闭 `gui` USE | 该 USE 编译 `wpa_gui`，依赖 `dev-qt/qtbase` 与 `qtsvg`。WiFi 由 NetworkManager 管理 | 需要 `wpa_gui` 时单独开启 |
| 59 | GTK 从系统层清除（进行中） | 已处理：`mediainfo` 移除（它依赖 `wxGTK` → GTK3；yazi 的缩略图由 `ffmpegthumbnailer` 提供，不依赖它）、`ffmpegthumbnailer` 关闭 `gtk` USE、`gammastep` 换为 `wlsunset`（纯 Wayland，仅依赖 `dev-libs/wayland`）。<br>未完成：`ffmpeg` 的 `sdl` USE 仍引入 `libsdl2` → `libdecor` → GTK3 | `ffmpeg` 关闭 `sdl` USE 后重评估（会失去 ffplay） |
| 60 | `ashell` 由本地 overlay 提供，不走 GURU | GURU 最高 0.9.0，而规范要求 0.12.1（`bar.padding` 0.11+、`bar.border` 与 `appearance.modules` 0.12+）。ebuild 用 `pycargoebuild` 生成 crate 清单，`SRC_URI` 走 GitHub tarball | GURU 收录 0.12.x 后移除本地 overlay |
| 61 | `pipewire-pulse` 需要显式启动 | ashell 的 Settings 模块含 Audio 指示器，`pipewire` 单独运行时不建 `/run/user/*/pulse/native`，PulseAudio 客户端连不上，整条 Settings 不渲染 | 不收回——这是 pipewire 的预期分层 |
| 56 | 测试仅覆盖 L1 静态与 L2 行为，无 VM 全系统验收 | 单维护者无法承担 qemu 集群成本 | 出现第二位维护者，或 L2 binhost 落地后承担 nightly |

## 十一、迁移到 Noctalia 全家桶后的偏离（2026-11-22）

> 本节编号独立：#58–65 只在本节内有意义，与第九节的 #58/59/60 撞号，
> 引用时务必带节名（如「偏离 #65（第十一节）」）。

ADR 0011 取代了 ADR 0009 的 niri 栈。以下偏离随之产生，
第八节中关于 niri/ashell/tofi/swaybg/dunst/swaylock/cliphist/wlsunset/
xwayland-satellite/yazi 的条目已随包一起失效。

| # | 偏离 | 原因 | 状态 |
|---|---|---|---|
| 58 | Umbriel 为 pre-release（`0.0.0_pre99999999`） | 上游尚未发正式版；配置键名可能在小版本间变动 | 接受。升级前看上游 changelog |
| 59 | Luciole 无 release tag | 上游 GitHub 只有 `main` 分支，无任何 tag | 接受。ebuild 用 `archive/main` 快照，升级改 `LUCIOLE_COMMIT` |
| 60 | Noctalia Greeter 不用上游文档的 `greeter` 用户 | GURU 的 `noctalia-greeter-9999` 只装 tmpfiles.d，未创建该用户 | 接受。用 `greetd` 用户（已在 video/input 组） |
| 61 | `noctalia msg media <action>` 不可用 | help 里列了该命令，但所有 action 均返回 `unknown command` | 媒体键改用 `playerctl` |
| 62 | 无法远程截取登录屏 | greeter 自带的合成器不支持 screencopy 协议 | 接受。只能本地看 |
| 63 | 配色不再有独立配置文件 | Noctalia 从壁纸提取调色板，`themes/` 与 `ordo-theme` 已删除 | 接受。换壁纸即换配色 |
| 64 | `install.sh` 必须显式 `chmod -R a+rX /opt/ordo/config` | `cp` 会带回源文件的 0600，而桌面配置以软链部署 | **已修**。软链方案的前提。2026-11-22 起部署规程升级为 config/ + scripts/ 双目录 rsync：config 用 `--chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r`（归一 644，一步解决属主与 0600），scripts 必须用 `Fu=rwx,Fgo=rx`——用 config 的 chmod 推 scripts 会剥掉可执行位（实测 doctor Permission denied），完整命令见 `config/desktop/README.md`「部署到实机」一节 |
| 65 | `ffplay` 由 `config/desktop/ffplay` 替身提供 | pomodoro 插件声明 ffplay 依赖（bar widget 实例化的门禁）；真 ffplay 属 ffmpeg 的 `sdl` USE（→ GTK3，与 `-sdl` 审计冲突）。替身剥掉 ffplay 三个 flag 转给 pipewire 自带 `pw-play`（`pipewire` 开 `extra` USE）。插件默认走 noctalia 原生音效 API，仅 `use-bundled-alarm-sound = true` 才真正调用 | ffmpeg 出非 SDL 的 ffplay，或上游改用原生音效 |
