# M2 电池驱动

公开源码包含重建脚本。制作旧版介质时，将脚本的输出保存为 `dev/m2/power/macsmc-power.ko`。0.1.0 独立 USB 安装器从发行载荷读取所需的原生驱动。

7.0.9-asahi-2 的原版 macsmc-power 在读取 BCF0 失败后仍调用 orderly_poweroff。M2 Air 的启动日志中，读取失败与十秒关机倒计时在同一时刻出现。BCF0 是电池耗尽标志，不同固件以一字节或四字节返回它。

本目录的补丁按固件报告的长度读取 BCF0。只有有效的耗尽标志会进入有序关机流程。电压低于设计下限时仍执行原有紧急保护。该处理与 [Asahi 的驱动实现](https://github.com/AsahiLinux/linux/blob/asahi/drivers/power/supply/macsmc-power.c) 一致。

在装有匹配工具链、内核配置和 Module.symvers 的 arm64 构建机上，用以下命令重建仓库随附的模块。脚本先校验原始驱动源码，再模拟新旧固件、读取失败及真正低电压，最后编译和检查 vermagic。

```sh
sh dev/m2/power/rebuild.sh /usr/src/linux-7.0.9-asahi-2 /tmp/macsmc-power.ko
```

制盘工具把模块放入 Live、已安装系统的 initramfs 和 ZFSBootMenu 的 EFI 镜像。安装器在解包基础模块集后也把它安装到根文件系统。切换内核版本时，应使用该版本对应的源码、配置和符号表重建，或使用已含上游修复的内核。
