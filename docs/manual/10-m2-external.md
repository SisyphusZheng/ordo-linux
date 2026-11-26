# M2 MacBook Air 的外接盘安装

本入口用于 Mac14,2 和外接 USB 盘。Mac 上需要由 Asahi 安装器建立的启动入口，以及包含本机固件的内部 EFI 系统分区。请使用本文的 M2 安装流程。

## 从另一台 M2 MacBook Air 准备 0.1.0 候选

准备一块可以清空的外接 USB 盘（至少 64 GB）。在 macOS 内置盘上为下载、解压和制作留出约 12 GB。首次建立引导入口另需 Asahi 安装器提示的可用空间。

1. 把 `Ordo-Linux-0.1.0-M2-Air-macOS.tar.gz`、`M2-SHA256SUMS` 与 `M2-SHA256SUMS.sig` 放进同一个文件夹，再从仓库取 `config/release/allowed_signers` 放到同一目录。在该文件夹打开终端，先验证摘要签名，再核对摘要：

   ```sh
   ssh-keygen -Y verify -f allowed_signers -I ordo-preview -n ordo-release \
       -s M2-SHA256SUMS.sig < M2-SHA256SUMS
   shasum -a 256 -c M2-SHA256SUMS
   ```

   第一行输出 `Good "ordo-release" signature ...` 后再看第二行的 `OK`。安装包内的 `allowed_signers` 只用于包内完整性检查，不能当作来源信任锚。校验通过后，用 Finder 解压安装包，双击里面的 `Install.command`。
2. 第一次在这台 Mac 上安装时，按提示在 Asahi 官方安装器中选择 **UEFI environment only**，用这台 Mac 的所有者账户在恢复环境完成认证。随后回到 macOS，再次双击同一份 `Install.command`。安装器会从这台 Mac 的引导分区提取固件。
3. 核对安装器显示的外接盘名称和容量。确认清盘后，安装器会在选定盘上准备引导文件和系统分区。原盘上的文件会被清除。
4. 保持外接盘连接，关机后长按电源键，选刚设置的 Ordo / Asahi 引导入口。在安装界面按提示确认目标，给自己的 `ordo` 账户设置密码。安装完成后按提示从同一入口启动桌面。原有 macOS 仍可从启动选项进入。

候选包采用 Ordo 发布密钥签名，尚无 Apple Developer ID 公证。遇到 Gatekeeper 提示时，先核对来源、校验值和随包指南。[安装包使用说明](../../dev/release/M2-安装指南.txt)

### 已有独立载荷时手动制盘

以下供已有独立载荷、需要从源码运行制盘器的人使用。使用上面的下载包即可完成普通安装。

在 macOS 验证备份可用，然后按 Asahi 文档选择 **UEFI only**，并完成该 Mac 自己的恢复模式批准。安装器会调整内置盘布局、建立签名启动入口，并提取该机的固件。保留原 macOS 启动项，从新入口对应的系统 EFI 分区找到 `vendorfw/firmware.cpio`。[Asahi UEFI-only 安装说明](https://asahilinux.org/docs/sw/tethered-boot/#installing-m1n1-on-your-apple-silicon-mac) · [启动流程](https://asahilinux.org/docs/alt/boot-process-guide/)

在磁盘工具中按硬件型号、容量和连接方式核对一块可清空的外接 USB 盘。将目标盘配置为 GUID 分区图，第一分区使用 FAT32 `ORDOPAYLOAD`，建议 20 GB，第二分区使用 exFAT `ORDOZFS`，至少 32 GiB。此操作会清空选定目标盘。在开始前将其他外接存储设备拔除。保存下载的发行文件到目标盘之外的目录。

对照候选发行说明提供的 SHA-256 核对 manifest 与 Live 基础文件，然后在仓库根目录运行。将示例中的目录和校验值替换为发布者给出的实际值。`--vendor-cpio` 只读使用这台 Mac 自己的固件，生成的 USB 启动文件含本机固件，请留作本机使用。

```sh
python3 dev/m2/prepare.py --usb-payload \
  --inner "$HOME/Downloads/ordo-m2/payload" \
  --base "$HOME/Downloads/ordo-m2/live/initramfs-live.img" \
  --base-sha256 "$ORDO_LIVE_SHA256" \
  --payload-manifest "$HOME/Downloads/ordo-m2/payload.sha256" \
  --payload-manifest-sha256 "$ORDO_PAYLOAD_MANIFEST_SHA256" \
  --binhost "$HOME/Downloads/ordo-m2/binhost" \
  --native-manifest "$HOME/Downloads/ordo-m2/native/native.sha256" \
  --native-manifest-sha256 "$ORDO_NATIVE_MANIFEST_SHA256" \
  --vendor-cpio "/Volumes/ASAHI-ESP/vendorfw/firmware.cpio"
```

核对制盘器显示的外接盘标识后输入 `PREPARE` 和提示指定的四位后缀。关机后长按电源键，在启动选择器里选该 Mac 的 Asahi UEFI 入口。外接盘的默认 EFI 会启动 Live 并检查载荷。预检通过后会显示目标分区，核对后输入指定的安装确认码。安装期间设置本机的 `ordo` 登录密码。关机重启后选同一个 Asahi UEFI 入口，并从该 USB 盘启动。

## 使用原有 ORDOINNER 的机器

现有 Ordo 机器可以继续使用内部 FAT 卷 `ORDOINNER` 上的原有安装文件。

### 重建安装介质

准备一块 GPT 格式的目标 USB 盘，首个分区建议 20 GB，格式为 FAT32，卷标为 `ORDOPAYLOAD`。系统分区至少 32 GiB，格式为 exFAT，卷标为 `ORDOZFS`。创建分区会清除目标盘，已有这两个分区且尚未安装时可以直接刷新启动文件。

制盘需要 Python 3.11 或更新版本、Pillow、zstd、bsdtar 和 AArch64 GNU binutils。在 macOS 上可用 Homebrew 安装 `aarch64-elf-binutils`。保留原始 Asahi Live 的 `live/initramfs-live.img` 作为构建输入。把本版的根系统四个分片、Live squashfs、内核、内核模块与真机包放在 `ORDOINNER`，文件名与 SHA-256 见 [安装文件清单](../../config/platform/m2/payload.sha256)。这些二进制文件需要从已有安装包或备份取得。源仓库提供制盘工具、启动脚本和桌面配置。

在仓库根目录运行。将 `--vendor-cpio` 指向这台 Mac 的 Ordo EFI 分区中 `vendorfw/firmware.cpio` 的已挂载路径或本机备份。该文件提供输入、Wi-Fi 和蓝牙固件。将[指定的无线监管数据库包](../../config/platform/m2/regdb.sha256)放入 `ORDOPAYLOAD/binhost`，也可通过 `--binhost` 指定包仓库。

```sh
python3 dev/m2/prepare.py --base /Volumes/ORDOPAYLOAD/live/initramfs-live.img --vendor-cpio "/Volumes/EFI - ORDO/vendorfw/firmware.cpio"
```

当前 M2 原生版本包含 `7.0.9-asahi-2-ordo-agx` 内核、Mesa 26.2.7 和 OpenZFS 2.4.4。重新分区前，先把完整的原生构建目录保存在目标盘之外。

原生构建可放在仓库的 `.local/m2-native-release/`、`ORDOPAYLOAD/ordo-native/` 或 `ORDOINNER/native/`。清单为 `native.sha256`，旁边保留 `stage/`、`binpkgs/` 和 `asahi-repo.tar.gz`。制盘工具按上述顺序读取，并用仓库发布的校验值验证输入。可用 `--native-source <目录>` 指定存放位置。发布后找不到输入、校验失败或组件不齐时停止。

要使用另一份已知校验值的原生构建，可指定 `--native-manifest <清单路径>` 和 `--native-manifest-sha256 <校验值>`。未发布原生构建时默认使用原有载荷。已有原生发布时，可用 `--legacy` 明确选择原有载荷。

工具验证外接盘身份、读取当前分区 UUID、校验安装资料并生成启动文件，最后切换默认启动项。macOS 使用不同挂载路径时，分别通过 `--boot-volume`、`--root-volume` 和 `--inner` 指定。重新分区后确认码会改变。只生成本地文件时，可用 `python3 dev/m2/build.py --help`。内置 EFI 由 Asahi 使用，Linux 安装器只读访问其中的固件。

内置 Ordo 入口负责初始化 M2。外接盘第一分区保存启动文件，第二分区保存系统和用户数据。安装后每次启动 Ordo 都要接着这块盘。

### 安装与首次登录

关机并保持外接盘连接。长按电源键，选择 Ordo Linux，等到 Live 提示符后输入 `ordo-install`。核对盘的信息，按屏幕提示输入带四位后缀的确认码。看到外接盘已写入且池已导出的消息后，输入 `poweroff`。再次选择 Ordo Linux。

第一次启动由 greetd 自动以普通用户 `ordo` 启动 Umbriel 和 Noctalia。退出或以后启动时显示登录界面。若屏幕没有进入桌面，可用第二个虚拟终端检查 `rc-service greetd status`。真机屏幕、键盘和合盖唤醒需要在 Mac 上分别验收；合盖行为见下面的「合盖、睡眠与唤醒」。

## 合盖、睡眠与唤醒

外接盘安装默认**不进入睡眠**。`/etc/elogind/logind.conf.d/10-ordo-external-root.conf` 把合盖（电池/外接电源）、睡眠键和休眠键都设为 `ignore`。原因有两层：唤醒时 USB 控制器会重新枚举，根池掉线会让桌面卡在根文件系统 I/O 上，只能长按断电；同时 swap 只有 4G 且和根池在同一块外接盘上，不足以休眠 8G 内存。

- 不要执行 `loginctl suspend`、`loginctl hibernate` 或 `echo mem > /sys/power/state`。需要省电时直接关机。
- 确认策略真的生效（真机执行）：

  ```sh
  busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
      org.freedesktop.login1.Manager HandleLidSwitch   # 期望 s "ignore"
  ls -l /lib/elogind/system-sleep/50-ordo-root-pool.sh  # 期望可执行
  # 不要执行 loginctl suspend：Handle* 只拦合盖/电源键，D-Bus 的 Suspend 仍会真的挂起
  ```
- 如果机器还是进入了睡眠（旧镜像、手动命令或固件行为），唤醒后先在桌面终端运行：

  ```sh
  ordo-m2-hardware --resume
  ```

  它跳过 EGL/GPU 检查，只复检无线网卡、扬声器保护/音频路由、内置键盘和触控板三项。任一项“异常”时按输出里的原因排查；三项全通过也不代表根池没受伤，继续看下一节。

## 外接盘掉线（pool suspended）

症状：桌面突然卡住、终端命令不返回、小组件停在最后一帧。根文件系统在 USB 盘上，线被碰掉或供电瞬断后，ZFS 默认的 `failmode=wait` 会无限等待，所以屏幕上不会自己出现错误。

1. **先不要长按断电。** 检查 USB 线/接口，重新插紧；如果是供电问题，换到有独立供电的接口或集线器。
2. 池回来后，ZFS 通常会自动恢复并重放；不能自动恢复时，在文本终端（`Ctrl+Alt+F2`）运行：

   ```sh
   zpool status -x rpool
   zpool clear rpool
   ```

   `zpool clear` 会清掉错误并让 suspended 的池尝试恢复。看到 `pool 'rpool' is healthy` 后再继续使用。
3. 掉盘事件会被 `/etc/zfs/zed.d/statechange-ordo.sh` 记到 `/run/ordo/root-pool-failed`，并用 `wall` 和桌面 critical 通知播报。每次登录时 `ordo-m2-hardware --session-report` 也会读这个标记、再次弹出通知并把硬件自检判为异常。池恢复 ONLINE 后这个标记会自动删除；不要用删标记代替修池。
4. 池无法恢复（`FAULTED`/`UNAVAIL`，或盘已经物理损坏）时：长按电源键关机，保持盘连接，从 ZFSBootMenu 选择可用的系统环境；如果 ZBM 也起不来，用**另一块**救援 U 盘启动手动 Live，按[升级与回滚手册](06-upgrade-rollback.md)导入池并导出数据。
5. **必须保留一块独立的救援 U 盘。** ZFSBootMenu、手动 Live 入口和系统根池都在同一块外接盘上；这块盘掉线时，它们会一起不可用。救援盘不要放 `rpool`，也不要在故障时反复插拔写盘。

## USB 健康与数据保密

- **TRIM**：安装器会尝试 `zpool set autotrim=on rpool`。有些 USB-SATA/UAS 桥不支持 TRIM，此时会改为每月 1 日 03:17 的 `/etc/cron.d/ordo-trim` 兜底。核对：

  ```sh
  zpool get autotrim rpool
  cat /etc/cron.d/ordo-trim 2>/dev/null
  doas zpool trim rpool   # 手工确认桥是否真的接受 TRIM；失败会进日志
  ```

  输出 `autotrim  on` 或存在月检 cron 都算策略落地；两者都没有时看安装日志里的 `tune-usb-pool.sh` 警告。
- **swap 写入**：swap zvol 使用 `sync=standard`，不是 `sync=always`。代价是断电可能丢最近的交换页（应用可重算的匿名页），换来的是 USB 盘寿命和系统响应；这不是休眠支持，本机仍然不能休眠。
- **威胁模型**：根池与 `/home` 在外接盘上是**明文**的。盘丢失/被拿走/被长期接触，等于项目、文档、密钥环与浏览器数据全部泄露。安装器不提供全盘加密；需要保护时，把备份流发到加密的数据集或加密容器，并把盘放在物理可控的地方。加密备份是可选层，不是默认保证。
- 外接盘长期插着时，保留散热空间并避免劣质集线器；掉盘的第一嫌疑通常不是 ZFS，而是供电和线材。

## 升级与回滚

用 `doas ordo sysup` 更新系统。升级会检查 Asahi 内核配套的 ZFS 模块和 initramfs，再把同一套启动文件同步到外接盘默认 EFI 和 extlinux。记下升级前快照的名称。

原生 AGX 系统继续选用带 AGX 驱动的 Asahi 内核。更新到新的原生内核时，先将对应的内核和模块安装到该系统，再运行 `doas ordo sysup`。启动镜像会使用该系统的 J413 固件和签名无线监管数据库。

运行 `doas ordo snap rollback <快照名>` 可从快照建立回滚环境。确认后，命令检查该环境中的启动文件、同步外接盘入口并切换 `bootfs`。看到回滚准备完成后再重启。重启后用 `findmnt -no SOURCE /` 和 `zpool get bootfs rpool` 核对当前根，再检查升级后写入的用户文件。更多说明见[升级与回滚手册](06-upgrade-rollback.md)。

如果默认入口无法启动，在 U-Boot 中从外接盘第一分区加载 `/EFI/Ordo/ZFSBootMenu.EFI`，用菜单选择可用的系统环境。下例使用 USB 设备 0，先核对它是 Ordo 外接盘。[U-Boot 启动 EFI 命令](https://docs.u-boot.org/en/stable/usage/cmd/bootefi.html)

```text
usb start
part list usb 0
ls usb 0:1 /EFI/Ordo
load usb 0:1 ${kernel_addr_r} /EFI/Ordo/ZFSBootMenu.EFI
bootefi ${kernel_addr_r}
```

同步更换默认 EFI 后，`/EFI/Ordo/Previous.EFI` 保留上一版镜像，`/extlinux/ordo-previous.conf` 保留上一版备用入口。它们继续从当前 `bootfs` 选根，切回旧系统时应优先使用 ZFSBootMenu。

## 在桌面上核对 M2 加速

进入 Umbriel 后，最近一次硬件检查保存在 `~/.local/state/ordo/m2-hardware.log`。它会核对合成器选中的渲染设备、Wayland 会话实际使用的 Mesa 驱动、内屏、输入设备、无线控制器、声音保护服务、屏幕背光设备、电池状态和桌面小组件输出。摄像头不在例行检查内：`apple-isp` 还没有进入平台模块列表，目前**未支持**；`ordo-m2-hardware --capture-camera` 只保留给开发和硬件验收（先装 `media-tv/v4l-utils` 才有 `v4l2-ctl`），读到帧也不改变例行结论。

唤醒后只需要复检无线、音频和输入三项时，运行 `ordo-m2-hardware --resume`，不要用完整检查代替。

- **扬声器保护常驻**：`rc-service speakersafetyd status` 应为 started；手动 `kill` 一次该进程后，5 秒内应被 OpenRC 重新拉起（`supervise-daemon`）。没有重新拉起说明上游 init 脚本正在自行 daemonize，需按该版本 init 脚本调整 `/etc/conf.d/speakersafetyd`。保护缺失时 `/run/ordo/speaker-protection-missing` 会写明原因。
- **屏幕亮度**：例行检查里的“屏幕背光设备可用于亮度调节”要求 `/sys/class/backlight` 至少有一个 `max_brightness > 0` 的设备。Fn 亮度键调用 `noctalia msg brightness-up/down`，不依赖 `brightnessctl`。这一项报异常时，先确认内屏确实绑定在 Apple DRM 上，再看 `/sys/class/backlight`。
- **桌面小组件输出**：Noctalia 配置里每个 `output = "..."` 必须对应一个已连接（`connected`）的 DRM 连接器；M2 内屏是 `eDP-1`，写死 `Virtual-1`（虚拟机）会让组件不显示或错位。想跟随合成器默认输出时，直接省略该 widget 的 `output` 键。检查不通过时报告会列出未连接的输出名。
- **掉盘标记**：报告会先读 `/run/ordo/root-pool-failed`；标记存在时即使例行硬件项全绿也会判为异常并弹 critical 通知。这是有意的——掉盘不是硬件自检能“修好”的问题。

如果 fastfetch 显示 `llvmpipe`，这次检测走的是 CPU 软件渲染。打开报告查看“Umbriel 会话和 Mesa Wayland EGL 使用 AGX”一项。内屏静置时是否闪烁、无线网络能否连接、蓝牙设备能否配对，以及唤醒后能否回到桌面，都需要在这台 Mac 上实际操作确认。
