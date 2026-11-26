# M2 内屏驱动

外接盘使用的 7.0.9-asahi-2 内核把 drm_kms_helper 等组件编进了内核。旧模块包使用同一版本号，但来自启用 simpledrm 之前的配置。它的依赖索引指示 modprobe 再次加载 drm_kms_helper，内核以 duplicate symbol 拒绝，导致 appledrm 无法按依赖加载。

modules.tar.gz 提供该内核的 appledrm、配套依赖和 kmod 索引。制盘时将它们放入系统 initramfs，安装时也部署到根文件系统。Mesa 的软件渲染和 Apple 显示控制器可以各自独立工作。

在已构建该内核的 Linux 源码树中，先检查 ZFS ARC 上限与并发数，然后编译相同配置的模块并生成更新包。

```sh
sh dev/m2/display/rebuild.sh /usr/src/linux-7.0.9-asahi-2 /path/to/original/modules.tar.gz /tmp/display.tar.gz
```

在物理机上检查 `dmesg` 中 appledrm 的绑定结果和 `/sys/class/drm/card*-*/status`，再观察内屏静置和滚动时的表现。虚拟机只能验证模块能加载。
