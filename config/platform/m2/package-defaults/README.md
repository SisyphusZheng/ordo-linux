# M2 安装载荷的软件包默认配置

M2 基础载荷曾通过 `quickpkg --include-config=n` 打包，导致部分配置只有一行占位文本。安装器在合并原生软件包后按完整字节匹配占位文本，并恢复同版本配置。已有配置继续由本机和 Portage 管理。

| 默认文件 | 来源 | 许可 |
|---|---|---|
| `zfs-2.4.4/etc/init.d/` 和 `etc/zfs/zfs-functions` | OpenZFS 2.4.4 模板，按 Gentoo OpenRC 参数渲染 | BSD-2-Clause，源文件保留许可和署名 |
| `zfs-2.4.4/etc/conf.d/zfs`、ZED 配置和 vdev 示例 | OpenZFS 2.4.4，`ZFS_UNMOUNT='no'` 与 Gentoo 2.4.4 ebuild 一致 | CDDL-1.0 |
| `upower-1.91.3/` | UPower v1.91.3 的配置和目录说明 | GPL-2.0-or-later |
| `power-profiles-daemon-0.30-r1/` | Gentoo `sys-power/power-profiles-daemon` 的 `files/power-profiles-daemon.initd-r1` | GPL-2.0 |

OpenZFS 和 UPower 发布包与 Gentoo `Manifest` 记录的 SHA-512 一致。生成器校验发布包和 Gentoo init 文件的摘要，按 Gentoo ebuild 的配置参数渲染，使用原始文件的路径和模式。

```sh
python3 dev/m2/render-package-defaults.py \
  /path/to/zfs-2.4.4.tar.gz /path/to/upower-v1.91.3.tar.bz2 \
  /path/to/power-profiles-daemon.initd-r1 /path/to/gentoo/licenses/BSD-2 \
  config/platform/m2/package-defaults
```

完整许可文本见各软件包子目录及 `licenses/GPL-2.0.txt`。源码可从 [OpenZFS v2.4.4](https://github.com/openzfs/zfs/releases/tag/zfs-2.4.4)、[UPower v1.91.3](https://gitlab.freedesktop.org/upower/upower/-/tree/v1.91.3) 和 [Gentoo 软件包仓库](https://gitweb.gentoo.org/repo/gentoo.git/tree/sys-power/power-profiles-daemon/) 获取。
