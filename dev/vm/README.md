# Ordo ARM64 UTM 镜像

在 Apple Silicon Mac 上双击发布的 `.utm.zip`，再打开解压出的 `.utm`。首次启动会要求在虚拟机控制台为 `ordo` 设置密码，随后进入 Umbriel 桌面。此密码用于之后的登录和 `doas`。ZFSBootMenu 启动菜单可选择系统启动环境。

构建在独立的 ARM64 Linux 构建虚拟机内进行。准备从已验证的 Gentoo stage3 及可审计包集生成的普通目录作为 `CLEAN_BASE`，其中 `/opt/ordo` 包含发行版配置。准备同一发行版内核镜像、模块和兼容的 ZFS 模块作为 `KERNEL_TREE`。在基座中安装对应的 ZFS、dracut 和 ZFSBootMenu 用户态工具。

```sh
dev/vm/build-disk.sh CLEAN_BASE KERNEL_TREE KERNEL_RELEASE OUTPUT_DIRECTORY

mkdir -p 'Ordo Linux 0.1.0 (ARM64).utm/Data'
qemu-img convert -f raw -O qcow2 -c \
    'OUTPUT_DIRECTORY/Ordo Linux 0.1.0 ARM64.raw' \
    'Ordo Linux 0.1.0 (ARM64).utm/Data/Ordo.qcow2'
python3 dev/vm/utm.py 'Ordo Linux 0.1.0 (ARM64).utm' --version 0.1.0
disk_hash=$(sha256sum 'Ordo Linux 0.1.0 (ARM64).utm/Data/Ordo.qcow2' | cut -d' ' -f1)
python3 dev/vm/zip-bundle.py 'Ordo Linux 0.1.0 (ARM64).utm' \
    'Ordo-Linux-0.1.0-UTM-arm64.zip' --qcow2-sha256 "$disk_hash"
```

`zip-bundle.py` 会在 ZIP 同目录写出 `UTM-SHA256SUMS`（ZIP 的 SHA-256），随 ZIP 一起发布。

制盘时会将仓库中固定的 Luciole 配方和 Manifest 安装到基座的 local Portage overlay。发布前，从写时复制磁盘冷启动，核对 UEFI、OpenRC、本地密码设置与 Wayland 桌面；发布镜像保持首次启动状态。
