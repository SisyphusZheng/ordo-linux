# 装配 ARM64 0.1.0 发行载荷

装配在独立的 ARM64 Linux 工作目录进行。以下目录名指普通目录，整个过程只写工作区。先保留输入文件的校验记录、Portage 构建日志和最终安装包清单。

## 共用系统根

1. 获取 Gentoo 官方 `stage3-arm64-desktop-openrc-20261122T234603Z.tar.xz` 与签名摘要。用 `config/verify-stage3` 按 Gentoo 发布主钥 `13EBBDBEDE7A12775DFDB1BABB572E0E2D182910` 验签。该压缩包 SHA-256 为 `b15941788842351f7a6e67dfdc6bf379c291ac5f0d8f346c567c3ab644fe6a98`。
2. 向空目录解包，保留数字 UID/GID、ACL 和 xattrs。准备 ARM64 二进制包缓存及其 `Packages` 索引，构建时将该缓存只读挂到目标下的 `/var/cache/binpkgs`。0.1.0 装配使用 Gentoo `5612e759ddbb58ff224546966df19866d460a93f` 与 GURU `162a44d29ef4c1ff8a2f2e47c0a012923dcd5064`。从这些修订版导出配方，分别解到 `/var/db/repos/gentoo` 和 `/var/db/repos/guru`，并将 Ordo 的 `overlay/` 部署为本地仓库。缓存可以按这些配方重新构建。若提供已有缓存，核对索引里的架构、修订、文件路径和内容摘要。
3. 设定 `default/linux/arm64/23.0/desktop` profile。由 `make.conf.example` 渲染 `armv8.2-a`、`virtio virgl` 和 `~arm64`，复制 `package.use/`、`package.accept_keywords/` 和 `package.mask/`，跳过仅真机使用的 `package.use/real-hardware`。用 `ordo_world config vm` 生成 `/etc/portage/sets/ordo-core`。本次缓存中的 GURU `zsh-autosuggestions-0.7.1` 已有 ARM64 二进制，需以 `=app-shells/zsh-autosuggestions-0.7.1::guru **` 单独准入。
4. 在私有 mount namespace 中挂载 chroot 的 proc、sysfs 和运行所需的 devfs。保留 `/dev/fd` 到 `/proc/self/fd` 的正常映射。先解析 `emerge --pretend --update --deep --usepkgonly --getbinpkg=n --with-bdeps=n @world @ordo-core`，再执行同一合并。若缓存由已安装文件产生，`xkeyboard-config-2.49` 的映像可能缺 Gentoo preinst 所需的 `xkb.workaround`。用 SHA-512 与 ebuild Manifest 一致的 `xkeyboard-config-2.49.tar.bz2` 从源码合并一次，并对后续二进制合并加 `--exclude=x11-misc/xkeyboard-config`。涉及 OpenSSL 子槽位变化时，用 `@world` 同步解析基础系统的消费者。
5. 对 `/etc` 做完整的 quickpkg 占位行扫描。用同版本包的源码与 ebuild 配置恢复默认文件。也可以从可信的同版本安装或公开包中恢复与原始 GPKG `metadata/CONTENTS` 中路径和摘要完全一致的文件。只通过字节精确的占位匹配写入，用原始包记录核对实际版本、来源和模式。Greetd PAM 由 `greetd-0.10.3-r1.ebuild` 的 `newpamd` 段生成，Greetd 会话配置使用仓库声明。SysV init 表使用官方干净 stage3 的 OpenRC 默认表。ZFSBootMenu 使用 3.1.0 发行源中的 `etc/zfsbootmenu/config.yaml`。再次扫描，要求占位归零。
6. 将 `config/`、`scripts/`、`assets/` 和 `version` 部署到目标 `/opt/ordo`。给 Gentoo 主树配置正常官方 rsync 与 MetaManifest 验证，保留 GURU 和本地 overlay 的固定版本。移除构建期间生成的默认 initramfs、机器 ID、hostid、池缓存、SSH 主机密钥和 root 历史，锁定 root，检查没有已创建的普通用户和 home 内容。检查 Umbriel、Noctalia、Luciole 和 greetd 可执行且库依赖完整。此根可作为 ARM64 虚拟机的输入。

## M2 Live、根分片和制盘

M2 根从共用根另作一份副本。通过正常 Portage 合并补齐 UPower 1.91.3、power-profiles-daemon 0.30-r1 与 i2c-tools 4.4。源码压缩包须和所用 Gentoo Manifest 的 SHA-512 吻合。在根内检查 `repair-package-defaults.py --check` 与实际 OpenRC 服务文件。安装过程会在外接盘新建用户并写入该 Mac 的固件与每盘 hostid。

从这份干净 M2 根另取临时副本，为它安装候选 Asahi 仓库、固定提交的 Luciole ebuild 与 Manifest，以及 `ordo-m2` USE/keyword 文件和硬件包集。使用待发的 native `binpkgs` 作为唯一离线包目录。照 `install-native.sh` 分别执行两条带 `--pretend --usepkgonly --getbinpkg=n --with-bdeps=n` 的合并，先解析 `package-atoms` 的八个定版包，再解析 `@ordo-m2`。旧安装可能已持有部分依赖，因此发布检查使用清洁根。

0.1.0 的原生包清单还需包含 Gentoo 缓存中的 `dev-python/pyparsing-3.3.3`、`sys-kernel/asahi-sources-7.0.9_p2`、`app-alternatives/bc-0` 和 `sys-devel/bc-1.08.2`。第一项是 PipeWire 的 LV2 依赖，后三项满足 Asahi 音频要求的内核来源。按原 ARM64 缓存的 `Packages` 路径和摘要核对四个 GPKG，再把完整的包记录合并到原生 `binpkgs/Packages`。更新索引哈希和四个 GPKG 的 SHA-256 清单行。制盘后从生成的原生归档读取索引和这四个文件，核对摘要。执行实际离线合并后用 `portageq has_version / <atom>` 逐项确认 `@ordo-m2` 已落盘。

Live 根再次从签名 stage3 解出。加入 ZFS 2.4.4 用户工具、GNU cpio 2.15 和匹配包记录的 OpenSSL 4.1 `libcrypto.so.4`，保留 stage3 原有的 OpenSSL 运行库。将 native 清单记录的同一版本内核模块部署到 `/usr/lib/modules`。清理账户凭据、机器标识和宿主配置。使用校验过的 SquashFS Tools 4.7.5 执行 `mksquashfs <live-root> image.squashfs -noappend -comp gzip`。检查镜像完整、压缩方式为 gzip，大小低于 2 GiB。

用 `dev/m2/release-boot.sh` 制作独立的 Live 初始 initramfs 和 ZFSBootMenu EFI。将后者放在 `payload/kernel/vmlinuz-asahi.EFI`。对干净 M2 根使用支持 `--numeric-owner --xattrs --acls --one-file-system` 的 GNU tar，排除构建标记、包缓存、distfiles、Portage 临时目录和日志。用 gzip 压缩后执行 `split -d -a 2 -n 4 rootfs.tar.gz payload/rootfs.tar.gz.part`，读回并校验四个分片非空且适合 FAT32。生成 `payload.sha256`，覆盖 `image.squashfs`、`kernel/vmlinuz-asahi.EFI` 和 `rootfs.tar.gz.part00` 到 `part03`。分别给出该清单、Live 初始文件以及 `native/native.sha256` 的 SHA-256。

最终包应包含重建工具、这些载荷、原生清单与包、无线监管数据库、许可及对应源码记录。Apple 固件应在目标机用 Asahi 安装器获取。生成 USB 后额外检查默认 EFI 的签名和实际分区身份。交给使用者前，从空白外接介质跑完整预检、安装、重启和登录，并核对系统显示的 `0.1.0`。
