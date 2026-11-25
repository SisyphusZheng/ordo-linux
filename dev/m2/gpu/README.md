# MacBook Air M2 硬件构建与验收

Mac14,2（J413）有独立的 Apple 显示控制器和 AGX GPU。初始安装介质使用的 `7.0.9-asahi-2` 配置启用了显示控制器，GPU 的 Rust 驱动需要另行构建。新内核和模块用 `-ordo-agx` 区分。会话在可读写的 Asahi DRM 渲染节点和 Mesa 驱动同时就绪后启用 GLES2。

## 生成候选内核

在有充足构建空间的 arm64 Gentoo 构建机上，使用 `7.0.9-asahi-2` 的干净源树、该版本运行基线的 `.config`、Rust、bindgen 和 Clang/LLVM。先把 [BCF0 电池修复](../power/bcf0.patch) 合入干净源树，再运行构建器。构建器检查 ZFS ARC 和并行度，并用模拟 SMC 运行电池回归。

构建机须能从 `PATH` 找到 Clang 和 LLVM 工具。若使用 Gentoo 的 LLVM 22，可加入 `/usr/lib/llvm/22/bin`。使用 GNU ld 时，为内核构建设置 `MAKEFLAGS='LD=ld HOSTLD=ld'`，并为 OpenZFS 构建设置 `KERNEL_LD=ld`。

```sh
patch -d "$ASAHI_SOURCE" -p1 < dev/m2/power/bcf0.patch
mkdir "$M2_BUILD"
sh dev/m2/gpu/rebuild.sh "$ASAHI_SOURCE" "$M2_BASE_CONFIG" "$M2_BUILD" 4
sh dev/m2/gpu/finish.sh "$ASAHI_SOURCE" "$M2_BUILD" "$OPENZFS_TARBALL" 4
```

候选内核与对应的树内模块写到 `$M2_BUILD/stage`。第二条命令使用同一内核的符号表构建 OpenZFS 2.4.4，并生成可供制盘工具使用的 initramfs。制盘时再加入外接分区的 USB 根发现钩子和本机 Apple 固件。保留原内核和对应模块，直到新版本在物理机启动成功。

已存在匹配的内核与 ZFS 模块时，可以单独运行 `sh dev/m2/gpu/initramfs.sh "$M2_BUILD/stage" 7.0.9-asahi-2-ordo-agx`。构建器按目标内核的模块索引解析依赖，确认 initramfs 含相应模块和索引后才替换旧生成文件。

## 构建 Mesa 和机型音频

在独立构建机应用 `config/platform/m2/install-hardware.sh`。Asahi Gentoo 仓库来自 Gentoo Asahi 项目维护者，具体修订由 [asahi-revision](../../../config/platform/m2/asahi-revision) 固定。对所需 ebuild 使用稀疏检出，Mesa 保持 Gentoo 主树版本。安装介质已有的 Asahi sources 满足上游音频配方。Portage 需要补装依赖时，`-symlink` 保留构建机当前内核源码链接。

```sh
asahi_repo=/var/db/repos/ordo-asahi
git init "$asahi_repo"
git -C "$asahi_repo" sparse-checkout set profiles metadata eclass \
    acct-group/speakersafetyd acct-user/speakersafetyd \
    media-libs/alsa-ucm-conf-asahi media-libs/asahi-audio \
    media-libs/bankstown-lv2 media-libs/triforce-lv2 \
    sys-apps/speakersafetyd sys-kernel/asahi-sources
git -C "$asahi_repo" fetch --depth 1 https://github.com/chadmed/asahi-overlay.git \
    "$(cat config/platform/m2/asahi-revision)"
git -C "$asahi_repo" switch --detach FETCH_HEAD
install -Dm644 config/platform/m2/asahi.conf /etc/portage/repos.conf/ordo-asahi.conf
sh config/platform/m2/install-hardware.sh
emerge --pretend --verbose --newuse @ordo-m2
sh config/check-build arc
sh config/check-build jobs "$(portageq envvar MAKEOPTS)"
emerge --oneshot --buildpkg --newuse @ordo-m2
```

在目标系统配置同一 Asahi 仓库与二进制包目录，再运行 `emerge --usepkgonly --newuse @ordo-m2`，将硬件包集加入系统包集。再次应用 `install-hardware.sh`，把齐备的扬声器保护服务加入 OpenRC 默认运行级。重启并登录原生 Wayland 会话后运行 `ordo-m2-hardware --capture-camera`。该命令检查 GPU 渲染、内屏连接、电池读数、机型音频路径、键盘背光接口，并读三个摄像头帧后丢弃。实际内屏稳定性、键盘亮度变化以及内置扬声器和麦克风听感需要在物理机上操作验收。扬声器验收使用 PipeWire 的机型 DSP 输出。
