# 变更记录

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。
版本号见仓库根 `version` 文件（唯一来源）。

## [Unreleased]

### Changed
- 恢复 Secret Service：新增 `app-crypt/gnome-keyring`，`app-crypt/libsecret` 回到
  Gentoo 树内版本，删除本地 libsecret overlay 与 `gnome-keyring` /
  `virtual/secret-service` 的 mask；`sys-auth/pambase` 启用 `gnome-keyring` USE。
- greetd PAM 在 `include login` 之后加入 `pam_gnome_keyring.so` 的 auth/session
  两行，登录时由 PAM 用登录密码自动创建/解锁 login keyring，不弹「新建/解锁
  密钥环」对话框；会话入口在 D-Bus 就绪后、Noctalia 之前启动
  `gnome-keyring-daemon --components=secrets`。
- 收回偏离「libsecret 客户端与 Secret Service 分开安装」；Noctalia 网络面板可
  跨会话保存 Wi-Fi 密码，`ordo-wifi` 降级为旧镜像兜底。
- `config/desktop/keyring-policy.sh check` 改为验证声明与接线（world、mask、
  PAM、会话启动），`configure` 只做幂等声明收敛，`remove` 改为 no-op 提示。

## [0.1.0] — 产品候选版

首个产品版本面向两个安装目标：Mac14,2 的外接 USB 系统盘，以及 Apple Silicon 上的 ARM64 UTM 虚拟机。下方按原日期保留产品定版前的开发记录和当时的版本号。

## [0.2.0] — 2026-11-21

### Fixed

#### 安装与分发
- 脚本改用 `readlink -f` 解析自身路径，修复软链安装后 `lib.sh` 无法定位的问题；
  `install.sh` 补齐入口白名单并在安装结束时自检。
- chroot 传入 `PROFILE`、`MARCH`、`VIDEO_CARDS`、`ARCH`、`ORDO_PLATFORM`；
  profile 设置失败由警告改为中止。
- stage3 下载增加 PGP 清单验签（指纹可配置）与 SHA256 比对；无法获取摘要时中止。
- `ordo config apply` 改为 world（写入 Portage set）、theme、desktop 三个模块；
  移除失效的 `kde` 模块。
- 补 `LICENSE`、`version`、`LICENSE-NOTES.md`；os-release 的 URL 从
  404 地址改为实际仓库。

#### 验收与声明层
- 退出码三态契约：`0` 全绿 / `1` 有问题 / `2` 无法判定。`doctor`、`verify`、
  `ordo-theme` 全部遵守。
- 修四处假绿灯：`verify` 数据集（findmnt 缺失）、`ordo-theme check`（组件缺失）、
  `doctor` 的 `/boot` 与 `world` 检查。
- `config/world` 去注释化（注释移至 `config/world.notes`），修掉 31 条幻影
  漂移；新增 `config/oneshot-packages` 显式登记「装过但不进 world」的引导工具。
- 双状态栏收口：waybar 从 world 与仓库移除，`layer-rule` 改为 ashell；
  删除无消费者的 `fuzzel.ini`、`lavalauncher.conf`、`niri-win`。
- 主题成为数据：`config/desktop/themes/{mocha,forest,seven}.conf` + `ordo theme list/set`；
  `apply` 只改 `focus-ring` 块（不再破坏用户自定义窗口边框）。
- 修会话启动顺序：`cliphist`/`portal`/`fcitx5`/壁纸全部移到 niri 的
  `spawn-at-startup`（之前起在 `exec niri` 之前，静默失败）。
- 壁纸真正可用：`ordo-wallpaper` 重写为按候选路径挑图并报错，install.sh 部署。
- 输入法收敛到 fcitx5 单一路径：删除 GNOME dconf 的 ibus 配置、`GLFW_IM_MODULE=ibus`；
  新增 `/etc/env.d/99imm` 并强制 `env-update`。
- 新增迁移机制：`config/migrations/` + `ordo migrate`，`sysup` 升级后自动执行。
- `sysup` 加固：参数校验、`--dry-run`、空间预检、trap 释放 hold、失败清理空快照、
  升级后可用性校验（initramfs / zfs 模块 / ZBM active），校验不过不放 hold。
- 内核 pin 从「钉一个版本」改为「钉一条边界」（`>=sys-kernel/*-7.3`）。
- 新增 `config/apps.d/` Flatpak 应用清单 + install.sh 读取 + `ordo app` 断言。
- 新增定时快照 cron（`/etc/cron.d/ordo-snapshot`），兑现「快照全自动」。
- sshd 默认关闭（`ORDO_SSH=1` 显式开启）；关键服务（dbus/elogind/zfs）注册失败
  改为 `die`。
- 删除约 185 行 GNOME/GDM/KDE 死代码与 `scripts/ordo-desktop-setup`；
  `package.use/desktop` 清理 5 条指向已删除 GNOME 栈的 USE，并给每行补原因注释。
- `config/package.use/real-hardware` 与 `config/world.bare-metal` 分离
  （USE 文件不再被当包清单追加进 world）。

#### 细节缺陷
- 修 `ordo-launch` 缓存永不命中 + 匹配永远失败（先 `rm` 再 `-s`；正则转义配 `grep -F`）。
- 修 `ordo-snap` 删除时区分 clone/hold/其他；回滚收尾的两条互斥指令改为二选一；
  `auto on` 校验 cronie 在 runlevel 里。
- 修 `doctor` 的 atom ERE 元字符崩溃、`-d` 对 glob（SC2144）、KDE 死代码换成 niri 检查。
- `require_root` 统一到 lib.sh（不再打印重复或截空的命令）。
- `ordo config show` 打印解析后的值而非 shell 源码；`diff` 不再恒显示 `POOL=?`。
- 新增 `ordo selfcheck`（usage × case × 软链三方一致）。

#### 登录管理器
- SDDM 换为 greetd + tuigreet。SDDM 依赖 Qt6 全家桶（实测连带 13 个
  dev-qt 包、26 MB 库），自定义主题需维护 618 行 QML。
  greetd 上游仅提供 systemd unit，OpenRC 服务文件补在 `config/desktop/greetd/greetd.initd`。
- 删除 `config/sddm-theme/`（5 个文件，618 行 QML）。
- 实测：重启后 greetd 于 tty7 启动 tuigreet，登录链路经 PAM 验证通过。

### Added
- `tests/`（L1 静态检查 + L2 行为用例）、`Makefile`、`.github/workflows/ci.yml`。
- `CONTRIBUTING.md`、`SECURITY.md`、`CHANGELOG.md`、`docs/manual/`（9 章用户手册）、
  `docs/decisions/README.md`（ADR 索引）。

## [0.1.0] — 2026-11-18

#### 登录管理器
- SDDM 换为 greetd + tuigreet。SDDM 依赖 Qt6 全家桶（实测连带 13 个
  dev-qt 包、26 MB 库），自定义主题需维护 618 行 QML。
  greetd 上游仅提供 systemd unit，OpenRC 服务文件补在 `config/desktop/greetd/greetd.initd`。
- 删除 `config/sddm-theme/`（5 个文件，618 行 QML）。
- 实测：重启后 greetd 于 tty7 启动 tuigreet，登录链路经 PAM 验证通过。

### Added
- L1：ZFS root + OpenRC + niri + 中文开箱 + Flatpak 分层，VM 内跑通。
- ZFS Boot Environment 与 ZFSBootMenu 回滚路径。
- `ordo` 统一 CLI（sysup / snap / backup / config / doctor）。
