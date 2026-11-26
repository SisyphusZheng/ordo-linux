#!/bin/sh
# install.sh — 从官方 Gentoo ISO 一键安装 ordo（L1：arm64 VM；施工图见 docs/decisions/0002）
# 前提：从 Gentoo minimal ISO (UEFI) 启动，已联网，以 root 运行
# 用法: ./install.sh [磁盘]   （默认 /dev/vda）
set -eu

DISK="${1:-/dev/vda}"
REPO_DIR="$(dirname "$(readlink -f "$0")")"
# 数据集布局读自 config/dataset（唯一事实来源，POOL/DATASET/HOME_DATASET）
. "$REPO_DIR/config/dataset"
# 架构定义读自 config/arch（ARCH/STAGE3_*/PROFILE/MARCH/VIDEO_CARDS）
. "$REPO_DIR/config/arch"
TARGET="${TARGET:-/mnt}"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }
# warn 必须写 stderr：外层脚本（stage3 验签等）依赖它降级提示，
# 缺这个定义时 `|| warn` 会变成 "warn: command not found"（exit 127），
# 在 set -e 下直接把安装打断（2026-11-22 评审发现）。
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }

[ "$(id -u)" -eq 0 ] || die "必须以 root 运行"
[ -b "$DISK" ] || die "找不到磁盘 $DISK"

ORDO_PLATFORM="${ORDO_PLATFORM:-vm}"
case "$ORDO_PLATFORM" in
    vm) ;;
    bare-metal)
        [ -r "$REPO_DIR/config/world.bare-metal" ] || die "缺少 config/world.bare-metal"
        [ -r "$REPO_DIR/config/package.use/real-hardware" ] || die "缺少真机 USE 配置"
        ;;
    *) die "ORDO_PLATFORM 必须是 vm 或 bare-metal" ;;
esac
# 架构与平台必须自洽：config/world.bare-metal.$ARCH 是微码 vendor 的分片，
# arm64 真机不该出现 x86 微码（P2-11）。未知架构在 config/arch 里已 exit 1。
case "$ARCH" in
    arm64|amd64) ;;
    *) die "config/arch 给出的 ARCH 非法：${ARCH:-空}" ;;
esac
ORDO_LAYOUT_ONLY="${ORDO_LAYOUT_ONLY:-0}"
case "$ORDO_LAYOUT_ONLY" in 0|1) ;; *) die "ORDO_LAYOUT_ONLY 必须是 0 或 1" ;; esac

DISK="$(readlink -f "$DISK")"
[ "$(lsblk -dn -o TYPE "$DISK")" = disk ] || die "目标必须是整块磁盘：$DISK"
case "$DISK" in *[0-9]) PART_SEP=p ;; *) PART_SEP= ;; esac
DISK_P1="$DISK${PART_SEP}1"
DISK_P2="$DISK${PART_SEP}2"
TARGET="$(realpath -m "$TARGET")"
[ "$TARGET" != / ] || die "安装目录不能为 /"

for tool in parted mkfs.vfat partprobe zpool zfs zgenhostid curl gpg sha256sum tar chroot nproc findmnt mountpoint lsblk realpath install; do
    command -v "$tool" >/dev/null 2>&1 || die "Live 环境缺少依赖：$tool"
done
# Luciole 的 ebuild 名带版本号（升级只需换文件名）：按 glob 校验，
# 不在安装器里钉死 luciole-0.1.0（P2-11）。
luciole_ebuild=''
for _luciole_eb in "$REPO_DIR"/overlay/gui-apps/luciole/*.ebuild; do
    [ -f "$_luciole_eb" ] || continue
    luciole_ebuild=$_luciole_eb
done
[ -n "$luciole_ebuild" ] || die "缺少 Luciole overlay（overlay/gui-apps/luciole/*.ebuild）"
if [ "$ORDO_LAYOUT_ONLY" = 0 ]; then
    jobs=$(sed -n 's/^MAKEOPTS="\(.*\)"$/\1/p' "$REPO_DIR/config/make.conf.example")
    sh "$REPO_DIR/config/check-build" jobs "$jobs" || die "编译并行度预检失败"
    [ -w /sys/module/zfs/parameters/zfs_arc_max ] || die "Live 环境的 ZFS ARC 上限不可写"
fi

check_target() {
    mounted=$(lsblk -nr -o MOUNTPOINTS "$DISK") || die "无法检查磁盘挂载"
    [ -z "$mounted" ] || die "目标盘含挂载或 swap：$DISK"
    disk_types=$(lsblk -nr -o TYPE "$DISK") || die "无法检查目标盘设备类型"
    if printf '%s\n' "$disk_types" | grep -qvE '^(disk|part)$'; then
        die "目标盘存在使用中的堆叠块设备：$DISK"
    fi
    mount_targets=$(findmnt -rn -o TARGET) || die "无法读取挂载表"
    # findmnt --raw 会转义空格等字符，安装目录只允许普通路径字符。
    case "$TARGET" in *[!a-zA-Z0-9_./-]*) die "安装目录包含不支持的字符：$TARGET" ;; esac
    if printf '%s\n' "$mount_targets" | awk -v target="$TARGET" '
        $0 == target || index($0, target "/") == 1 { found=1 }
        END { exit !found }
    '; then
        die "安装目录已有挂载：$TARGET"
    fi
    if [ -e "$TARGET" ]; then
        [ -d "$TARGET" ] || die "安装路径不是目录：$TARGET"
        existing=$(find "$TARGET" -mindepth 1 -maxdepth 1 -print -quit) || die "无法检查安装目录"
        [ -z "$existing" ] || die "安装目录非空：$TARGET"
    fi
    imported=$(zpool list -H -o name) || die "无法列出已导入的池"
    if printf '%s\n' "$imported" | grep -Fxq "$POOL"; then
        die "池 $POOL 已导入。请确认归属并先在 Live 环境导出"
    fi
    if [ -n "$imported" ]; then
        pool_status=$(zpool status -LP) || die "无法检查已导入池的设备"
        disk_devices=$(lsblk -npr -o NAME "$DISK") || die "无法列出目标盘设备"
        if printf '%s\n' "$pool_status" | awk -v devices="$disk_devices" '
            BEGIN { n=split(devices, paths, "\n"); for (i=1; i<=n; i++) device[paths[i]]=1 }
            $1 in device { found=1 }
            END { exit !found }
        '; then
            die "目标盘属于已导入的 ZFS 池：$DISK"
        fi
    fi
}

check_target
say "目标磁盘: ${DISK}（分区将被抹除）"
lsblk "$DISK"
printf '确认继续？输入 yes: '; read -r ok
[ "$ok" = "yes" ] || die "已取消"

workdir=$(mktemp -d "${TMPDIR:-/tmp}/ordo-install.XXXXXX")
pool_created=0
cleanup() {
    rc=$?
    trap - EXIT HUP INT TERM
    if [ "$pool_created" = 1 ]; then
        for mount_dir in dev sys proc run efi; do
            if mountpoint -q "$TARGET/$mount_dir"; then
                umount -R "$TARGET/$mount_dir" || warn "无法卸载 $TARGET/$mount_dir"
            fi
        done
        zpool export "$POOL" || warn "无法导出池 $POOL"
    fi
    rm -rf -- "$workdir"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# 下载和验证在任何写盘操作之前完成。
say "下载并验证 stage3（架构: ${ARCH}）"
S3_TXT="$workdir/stage3-manifest.txt"
curl -fsSL "$STAGE3_BASE/$STAGE3_LATEST_TXT" -o "$S3_TXT" || die "下载 stage3 清单失败"
S3_REL=$(grep -oE "[0-9]{8}T[0-9]{6}Z/${STAGE3_TARBALL}-[0-9]{8}T[0-9]{6}Z\.tar\.xz" "$S3_TXT" | head -1)
[ -n "$S3_REL" ] || die "无法从清单解析 stage3 文件名"
S3_NAME=${S3_REL##*/}
S3_FILE="$workdir/$S3_NAME"
curl -fsSL "$STAGE3_BASE/$S3_REL.sha256" -o "$workdir/stage3.sha256" || die "下载签名摘要失败"
sh "$REPO_DIR/config/verify-stage3" "$workdir" "$STAGE3_GPG_FINGERPRINT" "$S3_NAME" \
    || die "无法验证 Gentoo 发布签名或归档摘要"
curl -fsSL "$STAGE3_BASE/$S3_REL" -o "$S3_FILE" || die "下载 stage3 失败"
(cd "$workdir" && sha256sum --check --strict stage3.verified) || die "stage3 SHA256 不匹配"

check_target
if [ "$ORDO_LAYOUT_ONLY" = 0 ]; then
    sh "$REPO_DIR/config/zfs-arc.start"
    sh "$REPO_DIR/config/check-build" arc || die "不能在 ARC 未限制时编译"
fi

# ---------- 1. 分区 + ZFS ----------
say "分区"
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart zfs    513MiB 100%
partprobe "$DISK"
if command -v udevadm >/dev/null 2>&1; then udevadm settle; fi
[ -b "$DISK_P1" ] && [ -b "$DISK_P2" ] || die "内核未发现新分区"
mkfs.vfat -F32 -n ESP "$DISK_P1"

# hostid 先定：pool / chroot / initramfs 三处一致（ADR 0002，经典翻车点）
say "固定 hostid"
[ -s /etc/hostid ] || zgenhostid

say "创建 zpool（布局读自 config/dataset）"
mkdir -p "$TARGET"
zpool create -f -R "$TARGET" -o ashift=12 -O compression=zstd -O atime=off \
    -O mountpoint=none -O xattr=sa "$POOL" "$DISK_P2"
pool_created=1
zfs create -o mountpoint=none "$POOL/root"
zfs create -o mountpoint=/ -o canmount=noauto "$DATASET"
zfs mount "$DATASET"
zfs create -o mountpoint=/home "$HOME_DATASET"
zpool set bootfs="$DATASET" "$POOL"
mkdir -p "$TARGET/efi" "$TARGET/boot"
mount "$DISK_P1" "$TARGET/efi"

# ---------- 2. 解包已验证的 stage3 ----------
tar -C "$TARGET" -xpf "$S3_FILE" --xattrs-include='*.*' --numeric-owner

# ---------- 3. 写入配置 ----------
say "写入配置（单一事实来源）"
mkdir -p "$TARGET/etc/portage/package.use" "$TARGET/etc/portage/package.accept_keywords" \
         "$TARGET/etc/portage/package.mask" "$TARGET/etc/portage/repos.conf" \
         "$TARGET/etc/portage/sets" \
         "$TARGET/etc/ordo" "$TARGET/etc/zfs"
# make.conf 模板注入架构参数（config/arch 是唯一事实来源）
sed -e "s|@MARCH@|$MARCH|g" \
    -e "s|@VIDEO_CARDS@|$VIDEO_CARDS|g" \
    -e "s|@ACCEPT_ARCH_KEYWORD@|$ACCEPT_ARCH_KEYWORD|g" \
    "$REPO_DIR/config/make.conf.example" > "$TARGET/etc/portage/make.conf"
# 只装 VM 基线的 USE；real-hardware 由平台分支单独决定（见下）。
# 逐文件遍历而不是逐名 cp：新增片段（fonts/llvm/…）不该靠改这里才生效。
for _pu in "$REPO_DIR"/config/package.use/*; do
    [ -f "$_pu" ] || continue
    [ "$(basename "$_pu")" = "real-hardware" ] && continue
    cp "$_pu" "$TARGET/etc/portage/package.use/$(basename "$_pu")"
done
cp "$REPO_DIR/config/package.accept_keywords/"* "$TARGET/etc/portage/package.accept_keywords/"
cp "$REPO_DIR/config/package.mask/"* "$TARGET/etc/portage/package.mask/" 2>/dev/null || true
sh -c '. "$1/config/world.sh"; ordo_world "$1/config" "$2" "$3"' sh "$REPO_DIR" "$ORDO_PLATFORM" "$ARCH" \
    > "$TARGET/etc/portage/sets/ordo-core"
[ -s "$TARGET/etc/portage/sets/ordo-core" ] || die "有效包集为空"
# arm64 不得含 x86 微码：vendor 包按架构分片（config/world.bare-metal.$ARCH）。
if [ "$ARCH" != amd64 ] && grep -qx 'sys-firmware/intel-microcode' "$TARGET/etc/portage/sets/ordo-core"; then
    die "arm64 的 @ordo-core 含 x86 微码 —— 检查 config/world.bare-metal 分片"
fi
: > "$TARGET/var/lib/portage/world"
printf '%s\n' '@ordo-core' > "$TARGET/var/lib/portage/world_sets"
printf '%s\n' "$ORDO_PLATFORM" > "$TARGET/etc/ordo/platform"
if [ "$ORDO_PLATFORM" = bare-metal ]; then
    cp "$REPO_DIR/config/package.use/real-hardware" "$TARGET/etc/portage/package.use/real-hardware"
fi
cp "$REPO_DIR/config/dataset" "$TARGET/etc/ordo/dataset"
cp "$REPO_DIR/config/forbidden-world" "$TARGET/etc/ordo/forbidden-world"
cp /etc/hostid "$TARGET/etc/hostid"    # initramfs 导入 pool 的一致性（ADR 0002）

# ZFS ARC 上限：按实际内存算 40%，写进 modprobe.d。
# 不设（默认 0）时 ARC 会按比例吃到 85%，小内存机上编译 clang 会
# 陷入 direct reclaim 活锁（2026-11-20 实测停滞 50 分钟，见 config/zfs-arc.conf）。
# ZFS ARC 上限：按实际内存算 40%，通过 OpenRC local 服务在 zfs 加载后写入 sysfs。
# 不用 modprobe.d —— root=ZFS= 让 initramfs 阶段就 insmod zfs，modprobe.d 被绕过。
# 不设（默认 0）时 ARC 会按比例吃到 85%，小内存机上编译 clang 会陷入
# direct reclaim 活锁（2026-11-20 实测停滞 50 分钟，见 config/zfs-arc.start）。
mkdir -p "$TARGET/etc/local.d"
install -m 0755 "$REPO_DIR/config/zfs-arc.start" "$TARGET/etc/local.d/zz-zfs-arc.start"
ln -sfn /etc/init.d/local "$TARGET/etc/runlevels/default/local"
say "ZFS ARC 上限脚本已装（/etc/local.d/zz-zfs-arc.start，40% 物理内存）"

# ccache：编译子进程读 env.d 而不是 make.conf；目录必须归属 portage 且 setgid
mkdir -p "$TARGET/var/cache/ccache" "$TARGET/etc/env.d"
cat > "$TARGET/etc/env.d/99ccache" <<'EOF'
# Ordo: ccache 共享缓存（make.conf 的 CCACHE_DIR 只影响 emerge 加载期，
# 编译子进程需要 env.d 才能拿到 —— 2026-11-20 实测缺此文件时缓存恒为 0）
CCACHE_DIR="/var/cache/ccache"
CCACHE_SIZE="8G"
CCACHE_NOHASHDIR="true"
EOF
chown 250:250 "$TARGET/var/cache/ccache"    # portage:portage（chroot 前无 passwd 条目）
chmod 2775 "$TARGET/var/cache/ccache"

# fstab：只挂 ESP 到 /efi；ZFS 数据集由 mountpoint 属性 + zfs-mount 服务挂载
# （不再写 zfs 条目 —— 审查者指出 fstab 的 zfs 行会用不带 zfsutil 的
#   mount -t zfs，这正是当年被迫改用 legacy 的真正原因）
# 用 PARTUUID 而不是 $DISK_P1：安装期看到的是 live 环境的盘序，
# USB 介质占住 sda 时内置盘会变成 sdb，首启 /efi 就挂不上（P2-11）。
_efi_partuuid=$(lsblk -no PARTUUID "$DISK_P1" | head -1 | tr -d '[:space:]')
[ -n "$_efi_partuuid" ] || die "无法读取 ESP 的 PARTUUID：$DISK_P1"
cat > "$TARGET/etc/fstab" <<EOF
PARTUUID=$_efi_partuuid  /efi   vfat   defaults   0 0
EOF

# pool 缓存写入 BE 文件系统（dracut zfs 模块靠它发现 pool）。
# 两次 zpool set：先用 workdir 里的临时文件拿到 cache 内容，拷进 BE 后
# 把属性指向 /etc/zfs/zpool.cache —— 旧版停在 $workdir，而 workdir 在
# 收尾时被 rm -rf，目标机属性指向一个不存在的目录（P2-11）。
zpool set cachefile="$workdir/zpool.cache" "$POOL"
install -m 0644 "$workdir/zpool.cache" "$TARGET/etc/zfs/zpool.cache"
zpool set cachefile=/etc/zfs/zpool.cache "$POOL" \
    || die "cachefile 属性指向 /etc/zfs/zpool.cache 失败"

# chroot 只读取目标根里暂存的仓库文件。
if [ "$ORDO_LAYOUT_ONLY" = 0 ]; then
    mkdir -p "$TARGET/var/tmp/ordo-source"
    cp -R "$REPO_DIR"/config "$REPO_DIR"/scripts "$REPO_DIR"/overlay \
        "$REPO_DIR"/assets "$REPO_DIR"/version "$REPO_DIR"/LICENSE "$TARGET/var/tmp/ordo-source/"
fi

# ---------- 4. chroot ----------
if [ "$ORDO_LAYOUT_ONLY" = 0 ]; then
say "进入 chroot 完成系统（emerge @world 以小时计）"
cp /etc/resolv.conf "$TARGET/etc/resolv.conf"
mount --types proc  /proc "$TARGET/proc"
mount --rbind /sys   "$TARGET/sys"
mount --make-rslave "$TARGET/sys"
mount --rbind /dev   "$TARGET/dev"
mount --make-rslave "$TARGET/dev"
# chroot 里必须有自己的 /run：OpenRC 的 telinit 走 /run/initctl，
# 缺它时旧版向 PID 1 发 HUP —— 那会打到 live ISO 的 init（P2-11）。
mkdir -p "$TARGET/run"
mount --rbind /run   "$TARGET/run"
mount --make-rslave "$TARGET/run"
# 【内核位置】/boot 是数据集内的普通目录，不挂 ESP。
# ZBM 扫描的是数据集内 /boot 里的 vmlinuz-* 与 initramfs-*.img。
# 之前挂 ESP 到 /boot 会导致：emerge 更新内核写到 ESP，ZBM 仍读数据集内旧内核。
# ESP 只挂 /efi（ZBM EFI 本体放那里）。
mkdir -p "$TARGET/boot" "$TARGET/efi"
if ! mountpoint -q "$TARGET/efi"; then
    mount "$DISK_P1" "$TARGET/efi" || die "ESP 挂载失败"
fi

# 【P0-2 修复】chroot 只传了 4 个变量，PROFILE/MARCH/VIDEO_CARDS/
# ORDO_PLATFORM 全部没进去 —— 而 heredoc 是 <<'CHROOT'（不展开）。
# 于是 chroot 内 `eselect profile set "$PROFILE"` 拿到空串，失败后被
# `|| warn` 吞掉，desktop profile 永不生效、且全程零告警。
chroot "$TARGET" /usr/bin/env \
    DISK="$DISK" POOL="$POOL" DATASET="$DATASET" HOME_DATASET="$HOME_DATASET" \
    REPO_DIR=/var/tmp/ordo-source \
    PROFILE="$PROFILE" MARCH="$MARCH" VIDEO_CARDS="$VIDEO_CARDS" \
    ARCH="$ARCH" ACCEPT_ARCH_KEYWORD="$ACCEPT_ARCH_KEYWORD" \
    ORDO_PLATFORM="$ORDO_PLATFORM" \
    ORDO_USER_PASSWORD="${ORDO_USER_PASSWORD:-}" \
    ORDO_ROOT_PASSWORD="${ORDO_ROOT_PASSWORD:-}" \
    ORDO_DOAS_NOPASS="${ORDO_DOAS_NOPASS:-0}" \
    ORDO_SSH="${ORDO_SSH:-0}" \
    /bin/sh -s <<'CHROOT'
set -eu
say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() { warn "$*"; exit 1; }

sh "$REPO_DIR/config/check-build" jobs "$(portageq envvar MAKEOPTS)" || die "实际 MAKEOPTS 超限或无法判定"
sh "$REPO_DIR/config/check-build" arc || die "不能在 ARC 未限制时编译"

# ---- 1) portage 树 + GURU（ZBM 来源，见 docs/decisions/0002）----
say "同步 portage 树"
emerge --sync
say "启用 GURU overlay"
# 引导工具：eselect-repository 与 unzip 只在「启用 GURU」这一步用一次。
# 它们不进 world（会被 depclean 回收），这是**刻意**的——
# 但 doctor 需要知道这个例外，否则「装了但没声明」会永远报警。
# 例外登记在 config/oneshot-packages。
emerge -1 --noreplace app-eselect/eselect-repository dev-vcs/git app-arch/unzip
eselect repository enable guru
emaint sync -r guru

# 注册本地桌面配方后再解析 @world。
mkdir -p /var/db/repos/local
cp -R "$REPO_DIR"/overlay/metadata "$REPO_DIR"/overlay/profiles \
    "$REPO_DIR"/overlay/gui-apps /var/db/repos/local/
cat > /etc/portage/repos.conf/local.conf <<'LOCALREPO'
[local]
location = /var/db/repos/local
masters = gentoo
auto-sync = no
LOCALREPO
for _eb in /var/db/repos/local/gui-apps/*/*.ebuild; do
    [ -f "$_eb" ] || die "本地 overlay 缺少 ebuild"
    ebuild "$_eb" manifest || die "生成 Manifest 失败：$_eb"
done
sh "$REPO_DIR/config/desktop/keyring-policy.sh" configure

# ---- 2) profile：桌面基线（udev/X/wayland 等 USE 默认值）----
say "切换 desktop profile → ${PROFILE:-（空！）}"
# 【P0-2】profile 决定整棵依赖树的 USE 基线。设不上就等于装了另一套系统，
# 不能降级成警告继续跑。空值单独报，便于一眼看出 chroot 环境没传进来。
[ -n "${PROFILE:-}" ] || die "PROFILE 为空 —— chroot 环境变量未传入（检查 install.sh 的 env 列表）"
eselect profile set "$PROFILE" || die "eselect profile set $PROFILE 失败"
say "当前 profile: $(eselect profile show 2>/dev/null | tail -1)"

# ---- 3) locale / 时区（中文开箱）----
say "配置 locale 与时区"
printf 'LANG=zh_CN.UTF-8\n' > /etc/env.d/02locale
grep -q '^zh_CN.UTF-8 UTF-8' /etc/locale.gen 2>/dev/null || printf 'zh_CN.UTF-8 UTF-8\n' >> /etc/locale.gen
locale-gen
cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone

# ---- 4) BE 内核 cmdline（console + zfs 强制导入，VM 实测必须）----
say "写入 BE 内核 cmdline"
mkdir -p /etc/kernel
cat > /etc/kernel/cmdline <<EOF
root=ZFS=$DATASET console=ttyAMA0,115200 console=tty0 loglevel=4 zfs_force=1
EOF

# ---- 5) 系统层 @world（内核/ZFS/ZBM/KDE/输入法；编译墙钟以小时计）----
# autounmask：依赖解析要求的 USE/keyword 变更自动写入 /etc/portage 并续跑
# （Phase9 会把 VM 内产物同步回仓库 config/，消除漂移）
# 多轮 autounmask 收敛：USE/keyword 级联变更逐轮落盘应用（确定性自愈，
# 避免 emerge 单轮回溯耗尽后误报 world 文件损坏）
# 前置：打断新装系统的经典循环依赖 docutils→pillow→harfbuzz→glib→docutils
# （pillow 先不带 truetype 编；@world 完成后恢复重编）
printf 'dev-python/pillow -truetype\n' > /etc/portage/package.use/zz-bootstrap-cycle
say "emerge @world"
ok=0
for i in 1 2 3 4; do
    if emerge -uDN --autounmask-write --keep-going @world; then
        ok=1; break
    fi
    say "应用 autounmask 待定变更（第 $i 轮）"
    applied=0
    for d in package.use package.accept_keywords package.mask package.unmask; do
        for f in /etc/portage/$d/._cfg????_*; do
            [ -e "$f" ] || continue
            cp "$f" "/etc/portage/$d/${f##*/._cfg????_}"
            rm -f "$f"; applied=1
        done
    done
    [ "$applied" = 1 ] || { echo "!! 依赖解析仍失败且无待定变更可应用" >&2; exit 1; }
done
[ "$ok" = 1 ] || { echo "!! @world 多轮收敛失败" >&2; exit 1; }
# 恢复 pillow 的 truetype（freetype 渲染需要），单包重编
rm -f /etc/portage/package.use/zz-bootstrap-cycle
sh "$REPO_DIR/config/desktop/keyring-policy.sh" remove

# 破环种子（deviations #3）：只在解决 docutils→pillow→harfbuzz 循环时用一次。
# 之后 @world 会把 pillow 作为依赖正常装上，故不必进 world。
emerge -1 dev-python/pillow
emerge -1 --noreplace efibootmgr   # 注册 EFI 启动项用；一次性引导工具

# ---- 4) initramfs：dracut + zfs（ADR 0002：BE 自己的 initramfs 负责挂 root）----
say "生成 BE initramfs"
KVER="$(basename "$(find /usr/src -maxdepth 1 -name 'linux-*-gentoo-dist*' | LC_ALL=C sort -V | tail -1)" | sed 's/^linux-//;s/-bin$//')"
[ -n "$KVER" ] || { printf '!! 未找到 dist 内核源码树\n' >&2; exit 1; }
say "内核版本: $KVER"
rm -f /boot/*.old    # .old 变体会让 generate-zbm 选错（VM 实测）
dracut -f --kver "$KVER" "/boot/initramfs-$KVER.img"

# ---- 5) ZBM EFI 写入 ESP（ESP 现在挂 /efi，不再挂 /boot）----
say "安装 ZFSBootMenu EFI"
mkdir -p /efi/EFI/ZBM /etc/zfsbootmenu
if command -v generate-zbm >/dev/null 2>&1; then
    # 【关键】不要在这里写死 root=ZFS=${DATASET}。
    # ZBM 会按 os-release 的 ID/ID_LIKE 自动生成 root=ZFS=<选中的数据集>，
    # 这样切换 bootfs 才能真正生效（否则内核永远挂载硬编码的那个数据集）。
    # 见 docs/decisions/0002 与 deviations #30。
    cat > /etc/zfsbootmenu/config.yaml <<YAML
Global:
  ManageImages: true
Components:
  Enabled: false
EFI:
  ImageDir: /efi/EFI/ZBM
  Versions: false
  Enabled: true
Kernel:
  CommandLine: zfs_force=1 spl_hostid=0
YAML
    generate-zbm

    # 【关键】legacy 数据集必须标记 active=on 才会出现在 ZBM 菜单里。
    # 没有这一行，ZBM 的 BE 候选集为空 —— README 承诺的"开机菜单选环境"不成立。
    zfs set org.zfsbootmenu:active=on "$DATASET" 2>/dev/null \
        || warn "设置 org.zfsbootmenu:active 失败（ZBM 菜单可能看不到此环境）"
else
    printf '!! 未找到 generate-zbm（需 sys-boot/zfsbootmenu，见 ADR 0002）\n' >&2
    exit 1
fi

# ---- EFI 默认引导兜底（P1-01）----
# 固件默认入口：NVRAM 写失败或固件不认 BootXXXX 时，UEFI 会执行
# \EFI\BOOT\BOOT<ARCH>.EFI。generate-zbm 只写 /efi/EFI/ZBM/vmlinuz.EFI，
# 不复制这一份就等于把「能否开机」押在 efibootmgr 上（外置安装已有兜底）。
# 根路径可用 ORDO_EFI_ROOT 覆盖（仅测试用；正式安装恒为 /efi）。
_efi_root="${ORDO_EFI_ROOT:-/efi}"
case "$ARCH" in
    arm64) _efi_default="$_efi_root/EFI/BOOT/BOOTAA64.EFI" ;;
    amd64) _efi_default="$_efi_root/EFI/BOOT/BOOTX64.EFI" ;;
    *) die "未知架构，无法选择 EFI 默认引导名：${ARCH:-空}" ;;
esac
[ -s "$_efi_root/EFI/ZBM/vmlinuz.EFI" ] \
    || die "generate-zbm 未产出 $_efi_root/EFI/ZBM/vmlinuz.EFI —— 没有可兜底的引导文件"
mkdir -p "$_efi_root/EFI/BOOT"
install -m 0644 "$_efi_root/EFI/ZBM/vmlinuz.EFI" "$_efi_default" \
    || die "固件默认引导写入失败：$_efi_default"
cmp -s "$_efi_root/EFI/ZBM/vmlinuz.EFI" "$_efi_default" \
    || die "固件默认引导读回不一致：$_efi_default"
say "已写入固件默认引导：$_efi_default"

say "注册 EFI 启动项"
epath='/EFI/ZBM/vmlinuz.EFI'
if efibootmgr --create --disk "$DISK" --part 1 \
    --label "Ordo Linux" --loader "$epath"; then
    say "EFI 启动项已注册"
else
    # 注册失败时唯一入口必须是刚写下的固件默认引导；它也不在就真的开不了机。
    [ -s "$_efi_default" ] \
        || die "EFI 启动项注册失败，且没有固件默认引导兜底：$_efi_default 不存在"
    warn "EFI 启动项注册失败（已由固件默认引导 $_efi_default 兜底；也可手动 FS0:\\EFI\\ZBM\\vmlinuz.EFI）"
fi

# ---- 6) 主机名 / 用户 / 权限 ----
say "主机名与用户"
echo ordo > /etc/hostname
dbus-uuidgen --ensure 2>/dev/null || true
useradd -m -G wheel,video,input,plugdev,portage ordo 2>/dev/null || warn "用户 ordo 已存在"
# 若 /home 是独立挂载的数据集，useradd -m 可能建错位置；补建并修正属主
if [ -d /home ] && [ ! -d /home/ordo ]; then
    mkdir -p /home/ordo && cp -r /etc/skel/. /home/ordo/ && chown -R ordo:ordo /home/ordo
fi
# 密码：优先用环境变量 ORDO_USER_PASSWORD；未设置时生成随机口令并打印一次
if [ -n "${ORDO_USER_PASSWORD:-}" ]; then
    printf 'ordo:%s\n' "$ORDO_USER_PASSWORD" | chpasswd
    say "用户密码取自 ORDO_USER_PASSWORD"
else
    _pw="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)"
    printf 'ordo:%s\n' "$_pw" | chpasswd
    say "已生成随机用户密码（请立即记录，只显示这一次）："
    printf '\n    ordo / %s\n\n' "$_pw"
fi
# root 口令：同样支持环境变量；未设置则锁定 root 密码登录（只允许 doas 提权）
if [ -n "${ORDO_ROOT_PASSWORD:-}" ]; then
    printf 'root:%s\n' "$ORDO_ROOT_PASSWORD" | chpasswd
else
    passwd -l root 2>/dev/null || true
    say "root 密码已锁定（提权走 doas；如需救援口令请设置 ORDO_ROOT_PASSWORD）"
fi
# doas：默认要求密码（nopass 仅在你显式要求时启用）
if [ "${ORDO_DOAS_NOPASS:-0}" = "1" ]; then
    printf 'permit nopass :wheel\n' > /etc/doas.conf
    warn "doas 已配置为免密（ORDO_DOAS_NOPASS=1）—— 仅建议在一次性 VM 中使用"
else
    printf 'permit persist :wheel\n' > /etc/doas.conf
fi
chmod 400 /etc/doas.conf

# ---- 7) 服务（OpenRC；名称有出入时跳过，VM 迭代时校准）----
say "启用 OpenRC 服务"
# 分级：下面这组失败 = 系统起不来 → die。
# 其余（网络、时间）失败可降级为 warn，但不能连坐。
for svc in dbus:default elogind:boot zfs-import:boot zfs-mount:boot; do
    name="${svc%%:*}"; lvl="${svc##*:}"
    rc-update add "$name" "$lvl" || die "关键服务 $name 注册失败 —— 系统将无法启动"
done
for svc in NetworkManager:default zfs-zed:default chronyd:default cronie:default; do
    name="${svc%%:*}"; lvl="${svc##*:}"
    rc-update add "$name" "$lvl" || warn "服务 $name 注册失败（网络/时间/快照相关，可后补）"
done
# sshd 默认**不开**：单用户桌面机不需要远程登录，
# 而 doas 已能本地提权。需要时用 ORDO_SSH=1 ./install.sh 显式开启。
if [ "${ORDO_SSH:-0}" = "1" ]; then
    rc-update add sshd default || warn "sshd 注册失败"
    say "已按 ORDO_SSH=1 启用 sshd"
else
    rc-update del sshd default 2>/dev/null || true
    say "sshd 未启用（默认关闭；需要时设 ORDO_SSH=1）"
fi
# chronyd 已在上面的服务循环里注册（net-misc/chrony 由 config/world 提供）。
# 没有 NTP 会连锁出：TLS 校验失败、快照/cron 时间戳错乱、ZBM 菜单时间漂移。

# ---- 8) 输入法：fcitx5 + rime（唯一路径）----
# 【为什么删掉了 ibus 与 GNOME dconf】桌面栈只用 fcitx5，
# 而 ibus 的配置方式是 GNOME dconf（org/gnome/desktop/input-sources）——
# 本桌面栈没有任何进程会读它。留着它等于给"输入法"留两条互不相干的事实来源，
# 评审因此把它列为 P1-11。这里只写合成器真正会读的东西：环境变量。
say "配置输入法（fcitx5 + rime）"
install -Dm644 "$REPO_DIR/config/desktop/99imm" /etc/env.d/99imm

# fcitx5 的 profile：rime 为唯一引擎（chinese-addons 无 arm64 keyword，见 deviations #6）
#
# 只装 app-i18n/fcitx + fcitx-rime：fcitx5 自带 libwaylandim.so，
# 经 text-input-v3 协议向合成器提供输入法。不装 fcitx-gtk / fcitx-qt /
# fcitx-configtool —— 三者均为 GTK/Qt 依赖，Wayland 会话下不需要。
# 代价：无图形配置界面，改配置编辑本文件。
mkdir -p /etc/xdg/fcitx5
cat > /etc/xdg/fcitx5/profile <<'FCITXPROFILE'
[Groups/0]
# Group Name
Name=Default
# Layout
Default Layout=us
# Default Input Method
DefaultIM=rime

[Groups/0/Items/0]
# Name
Name=keyboard-us
# Layout
Layout=

[Groups/0/Items/1]
# Name
Name=rime
# Layout
Layout=

[GroupOrder]
0=Default
FCITXPROFILE

# env.d 必须编译进 /etc/profile.env 才会对登录会话生效。
# 【评审发现的真 bug】旧版 install.sh 写了 /etc/env.d/02locale 却从不跑
# env-update —— env.d 从未被编译，首启 LANG 根本没生效，而 doctor 读的是
# 源文件本身，于是报 ✔（又一处假绿灯）。
say "编译环境变量（env-update）"
env-update || die "env-update 失败（/etc/env.d 里的 LANG 与输入法变量不会生效）"

# ---- 11b) 终端与 shell（Ghostty 无 arm64 keyword，WezTerm 替代；VM 实测）----
say "安装 WezTerm + ZSH + tmux + cronie 栈"
# 这里刻意不加 --jobs：config/make.conf.example 明确用 --jobs=1，
# 理由是并行 emerge 会让峰值内存翻倍 —— 而 deviations #48 的 ARC 活锁
# 正是内存不够造成的。容量靠 MAKEOPTS 的 -j 控制，不靠 emerge 并行。
emerge -1 --noreplace app-shells/zsh app-shells/starship \
    app-shells/zsh-autosuggestions app-shells/zsh-syntax-highlighting \
    app-shells/gentoo-zsh-completions x11-terms/wezterm \
    app-misc/tmux sys-process/cronie \
    || warn "终端/调度栈安装失败，不影响系统"
# cronie：定时快照 + 每月 scrub 依赖它（审查者指出 install.sh 从未装过 cronie）
rc-update add cronie default 2>/dev/null || warn "cronie 服务注册失败"

# ---- 11b-bis) 每月 scrub（ZFS 发行版的标配，审查者指出完全缺失）----
mkdir -p /etc/cron.monthly
cat > /etc/cron.monthly/zfs-scrub <<'SCRUB'
#!/bin/sh
# 每月池 scrub（读全盘校验 checksum，发现并修复静默损坏）
POOL="${ORDO_POOL:-rpool}"
if zpool list -H -o name 2>/dev/null | grep -qx "$POOL"; then
    logger -t ordo-scrub "starting scrub on $POOL"
    zpool scrub "$POOL" 2>&1 | logger -t ordo-scrub
else
    logger -t ordo-scrub "pool $POOL not found, skip"
fi
SCRUB
chmod 755 /etc/cron.monthly/zfs-scrub

# ---- 11b-ter) Flatpak 应用层（宪法"Flatpak-first"；此前 install.sh 完全缺失）----
# 包本体：sys-apps/flatpak 已在 config/world 基线内 → 由本脚本 §5 的 emerge @world 装上，
# 这里不再重复 emerge（避免同一包两条安装路径）。
# 本节只补 emerge 不会替我们做的事：每周自动更新。
# 【P1-04】Flathub remote 不在这里加：--user 的 remote 与 --user 的应用必须
# 属于同一个用户（这里以 root 跑，加了只会落到系统仓库，首启的 ordo 看不到）。
# remote 与清单安装一起做，见 §15。
say "配置 Flatpak 自动更新"
# 【P1-04】flatpak 是应用层的唯一入口：缺失时首启没有浏览器 / 商店，
# ordo app install 也无从补救。安装期就停，不把缺件留到首启。
require_flatpak() {
    command -v flatpak >/dev/null 2>&1 \
        || die "flatpak 命令不存在（@world 应已装 sys-apps/flatpak）—— 应用层全部依赖它"
}
require_flatpak
# 每周自动更新（照 /etc/cron.monthly/zfs-scrub 的写法；cronie 已在 §11b 启用）
# 应用层全部依赖 Flatpak，漏更新等于长期积累安全债，故每周而非每月。
# 注意：ordo app install 走 --user（装在各用户家目录），root 的 system 安装互不相通，
# 两种安装都必须更，否则必然漏一半。
mkdir -p /etc/cron.weekly
cat > /etc/cron.weekly/flatpak-update <<'FLATPAK_UPDATE'
#!/bin/sh
# 每周更新 Flatpak 应用（宪法 Flatpak-first：应用层全部走 Flatpak）
# 两类安装分别更新：系统级（--system）与各用户的 --user 安装。
# 失败只写 syslog，不中断其他用户/后续周任务；下次运行自动重试。
LOG_TAG=ordo-flatpak
log() { logger -t "$LOG_TAG" "$*"; }

if ! command -v flatpak >/dev/null 2>&1; then
    log "flatpak not found, skip"
    exit 0
fi

log "starting weekly flatpak update"

# 1) 系统级安装（root 装的）
if out="$(flatpak update --system -y --noninteractive 2>&1)"; then
    log "system install: ok"
else
    log "system install: FAILED"
fi
printf '%s\n' "$out" | logger -t "$LOG_TAG"

# 2) 各用户级安装（ordo app install 默认落在这里，root 的 flatpak 看不到）
for home in /home/*; do
    [ -d "$home" ] || continue
    u="${home##*/}"
    id "$u" >/dev/null 2>&1 || continue
    if out="$(su - "$u" -c 'flatpak update --user -y --noninteractive' 2>&1)"; then
        log "user $u: ok"
    else
        log "user $u: FAILED"
    fi
    printf '%s\n' "$out" | logger -t "$LOG_TAG[$u]"
done
FLATPAK_UPDATE
chmod 755 /etc/cron.weekly/flatpak-update

# 历史清理：早期版本装过 gnome-terminal，WezTerm 已替代它
emerge -C x11-terms/gnome-terminal 2>/dev/null || true
# 默认 shell 改 zsh
chsh -s /bin/zsh ordo 2>/dev/null || true

# ---- 11) ordo CLI 安装到系统（/opt/ordo + /usr/local/bin 软链）----
# 【P0-1】软链到 /usr/local/bin 后，脚本里的 $(dirname "$0") 会解析成
# /usr/local/bin —— 那里没有 lib.sh。修复分两半：
#   (a) 脚本侧改用 readlink -f（见 scripts/lib.sh 与各入口脚本头部）
#   (b) 这里必须把**全部**入口与 lib.sh/i18n 一起装到 /opt/ordo/scripts，
#       少装一个，对应子命令就变成 "No such file"。
say "安装 ordo CLI"
if [ -d "$REPO_DIR/scripts" ]; then
    mkdir -p /opt/ordo /etc/ordo
    rm -rf /opt/ordo/scripts /opt/ordo/config
    cp -r "$REPO_DIR/scripts" "$REPO_DIR/config" "$REPO_DIR/overlay" /opt/ordo/
    # 版本文件：ordo / os-release / 文档的唯一来源
    [ -f "$REPO_DIR/version" ] && cp "$REPO_DIR/version" /opt/ordo/version
    [ -f "$REPO_DIR/LICENSE" ] && cp "$REPO_DIR/LICENSE" /opt/ordo/LICENSE
    chmod 755 /opt/ordo/scripts/* 2>/dev/null || true
    # config/ 必须对所有人可读。
    # 【真实事故 2026-11-22】cp 会把源文件的 0600 权限带过来，而 ordo-config
    # 把 ~/.config/umbriel/config.toml 软链到 /opt/ordo/config 下的文件。
    # 结果是用户读不到自己的配置：Umbriel 启动时报
    # "config.toml File could not be opened for reading"。
    # 软链方案的前提是目标文件对目标用户可读，这一条必须显式保证。
    chmod -R a+rX /opt/ordo/config 2>/dev/null || true

    # 入口白名单：只软链**用户会敲的命令**，内部脚本（lib.sh / ordo-i18n.sh）
    # 不暴露到 PATH，避免污染命令空间。
    for _entry in ordo sysup ordo-snap ordo-snap-auto ordo-backup ordo-config ordo-migrate ordo-selfcheck; do
        [ -f "/opt/ordo/scripts/$_entry" ] || continue
        ln -sf "/opt/ordo/scripts/$_entry" "/usr/local/bin/$_entry"
    done
    # doctor 有两个名字：ordo doctor（内部调用）与历史别名 ordo-doctor
    ln -sf /opt/ordo/scripts/doctor /usr/local/bin/ordo-doctor

    # 自检：装完立刻验证「软链 → readlink → lib.sh」这条链真的通
    if ! /usr/local/bin/ordo --help >/dev/null 2>&1; then
        die "ordo CLI 安装后自检失败（/usr/local/bin/ordo 无法运行）—— 检查 lib.sh 是否在 /opt/ordo/scripts"
    fi
    say "ordo CLI 自检通过：$(/usr/local/bin/ordo info 2>/dev/null | head -1)"


    cp /opt/ordo/config/dataset /etc/ordo/dataset
    cp /opt/ordo/config/forbidden-world /etc/ordo/forbidden-world 2>/dev/null || true
    cp /opt/ordo/config/oneshot-packages /etc/ordo/oneshot-packages 2>/dev/null || true
    # 配色由 Noctalia 的 theme.source = "wallpaper" 从壁纸提取，
    # 不再需要独立的 palette.conf / themes 目录。
    # Flatpak 应用清单也要能被 ordo-migrate 读到
    mkdir -p /etc/ordo/apps.d
    cp /opt/ordo/config/apps.d/*.list /etc/ordo/apps.d/ 2>/dev/null || true
    # 迁移脚本：ordo-migrate 从 CONF_DIR 读，装好后 /etc/ordo 也该有一份入口
    mkdir -p /etc/ordo/migrations-link
    rm -rf /etc/ordo/migrations-link
    ln -sfn /opt/ordo/config/migrations /etc/ordo/migrations 2>/dev/null || true
else
    die "找不到 $REPO_DIR/scripts —— 无法安装 ordo CLI（不能静默跳过：装完没有 ordo 等于没装）"
fi

# ---- 12) 系统身份（os-release，让 fastfetch/系统信息显示 Ordo）----
say "写入系统身份"
# 版本单一来源：$REPO_DIR/version（根目录那一行）
_ver="$(cat "$REPO_DIR/version" 2>/dev/null)"
[ -n "$_ver" ] || die "缺少 version 文件（版本唯一来源）"
_ver_base="${_ver%%-*}"
cat > /etc/os-release <<OSREL
NAME=Ordo Linux
PRETTY_NAME="Ordo Linux ${_ver_base} (Ab Chao)"
ID=ordo
ID_LIKE=gentoo
BUILD_ID=${_ver_base}
VERSION_ID=${_ver_base}
VERSION="${_ver_base} (Ab Chao)"
VERSION_CODENAME=ab-chao
HOME_URL="https://github.com/ordo-linux/ordo"
SUPPORT_URL="https://github.com/ordo-linux/ordo/issues"
BUG_REPORT_URL="https://github.com/ordo-linux/ordo/issues"
OSREL
ln -sf /etc/os-release /usr/lib/os-release 2>/dev/null || cp /etc/os-release /usr/lib/os-release

# ---- 13) 品牌资产（logo / fastfetch / wallpaper / Gentoo 标识替换）----
say "安装 Ordo 品牌资产"
if [ -d "$REPO_DIR/assets/branding" ]; then
    mkdir -p /usr/share/ordo /etc/fastfetch
    cp "$REPO_DIR/assets/branding/ordo-ascii.txt" /usr/share/ordo/logo.txt
    cp "$REPO_DIR/assets/branding/fastfetch.jsonc" /etc/fastfetch/config.jsonc
    cp "$REPO_DIR/assets/branding/ordo-wallpaper.svg" /usr/share/ordo/wallpaper.svg

    # 用户级 fastfetch 默认配置
    mkdir -p /etc/skel/.config/fastfetch
    cp "$REPO_DIR/assets/branding/fastfetch.jsonc" /etc/skel/.config/fastfetch/config.jsonc

    # ---- 用户级 skel 配置（zsh / tmux / wezterm）----
    # 这些是 config/desktop/skel 的唯一来源，之前从未部署过（L1 靠手工拷贝）。
    if [ -d "$REPO_DIR/config/desktop/skel" ]; then
        cp -r "$REPO_DIR/config/desktop/skel"/. /etc/skel/
        chown -R root:root /etc/skel
        # 已存在的 ordo 用户也要拿到（L1 手动装的情形）
        if [ -d /home/ordo ]; then
            cp -rn "$REPO_DIR/config/desktop/skel"/. /home/ordo/ 2>/dev/null || true
            chown -R ordo:ordo /home/ordo/.tmux.conf /home/ordo/.zshrc \
                /home/ordo/.config 2>/dev/null || true
        fi
    fi

    # 桌面壁纸（GNOME 系统级默认）
    mkdir -p /usr/share/backgrounds/ordo
    cp "$REPO_DIR/assets/branding/ordo-wallpaper.svg" /usr/share/backgrounds/ordo/ 2>/dev/null || true
    # 实际使用的 PNG 壁纸（ordo-wallpaper 只认图片；SVG 作品牌素材另放）
    for _wp in "$REPO_DIR"/config/desktop/wallpapers/*.png; do
        [ -f "$_wp" ] && cp "$_wp" /usr/share/backgrounds/ordo/
    done

    # GDM / 控制中心的 logo 必须是**小尺寸图标**，绝不能用壁纸。
    # GDM 用 St.TextureCache.load_file_async(file, -1, -1) 按原始像素加载 logo，
    # 一旦塞进 3840x2160 的壁纸，logo-bin 会撑满整屏并盖住登录对话框
    # （表现为「只有壁纸和顶栏、没有密码框」）。
    # 生成 128x128 的 Ordo 徽标（同心圆 + O）。
    cat > /usr/share/pixmaps/ordo-logo.svg <<'ORDOLOGO'
<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128">
  <circle cx="64" cy="64" r="56" fill="none" stroke="#6b7fd7" stroke-width="2" opacity="0.6"/>
  <circle cx="64" cy="64" r="40" fill="none" stroke="#8b9ee8" stroke-width="1.5" opacity="0.4"/>
  <text x="64" y="76" font-family="sans-serif" font-size="34" font-weight="300"
        fill="#e8eaf0" text-anchor="middle" letter-spacing="2">O</text>
</svg>
ORDOLOGO
    chmod 644 /usr/share/pixmaps/ordo-logo.svg

else
    warn "未找到品牌资产（assets/branding/），跳过"
fi

# ---- 14) 登录管理器 + 桌面会话 ----
# 桌面栈 = Noctalia 全家桶（Umbriel 合成器 + Shell + Luciole + Greeter）。
# 中文输入实测：Umbriel + fcitx5 + rime 可用。
say "配置 greetd + Umbriel 会话"

# 14a) 登录管理器：greetd 自有 initd（provide display-manager）
# 四件套（config.toml / initd / pam.d / tmpfiles）是**系统必需**：
# 旧版把它们放在品牌资产块里 —— assets/branding 缺失时只剩一条 warn，
# 装完没有图形登录，而且没人发现（P2-11）。缺文件即 die。
_greetd_src=/opt/ordo/config/desktop/greetd
[ -f "$_greetd_src/config.toml" ] || die "缺少 $_greetd_src/config.toml —— 没有图形登录（检查 config/desktop/greetd）"
mkdir -p /etc/greetd /etc/tmpfiles.d
# 密钥环自动解锁 + greeter 状态目录（属主是 greetd 而非包硬编码的 greeter）
install -Dm644 "$_greetd_src/config.toml" /etc/greetd/config.toml || die "greetd config.toml 部署失败"
install -Dm755 "$_greetd_src/greetd.initd" /etc/init.d/greetd || die "greetd 服务脚本部署失败"
install -Dm644 "$_greetd_src/pam.d-greetd" /etc/pam.d/greetd || die "greetd PAM 部署失败"
install -Dm644 "$_greetd_src/tmpfiles-noctalia-greeter.conf" /etc/tmpfiles.d/noctalia-greeter.conf \
    || die "greetd tmpfiles 部署失败"
systemd-tmpfiles --create /etc/tmpfiles.d/noctalia-greeter.conf 2>/dev/null || \
  opentmpfiles-setup 2>/dev/null || true
say "已部署 greetd 配置、服务、PAM 与 tmpfiles"

# display-manager-init 只提供 OpenRC 的 display-manager 包装服务；greetd 的
# initd 自己 provide display-manager，两套入口互斥，这里只装包不启用服务。
# -1 --noreplace：它是安装器的一次性引导工具，不进 world（P2-11）。
emerge -q -1 --noreplace sys-apps/display-manager-init 2>/dev/null \
    || emerge -q -1 --noreplace gui-libs/display-manager-init 2>/dev/null \
    || die "display-manager-init 安装失败 —— 没有它就没有图形登录（不能降级为 warn）"

# greetd 独占 tty1，必须禁用该 VT 上的 getty。
# 不禁用则两者同时读键盘：输入错乱（"orood"）、登录框与 getty 提示重影。
# SDDM 时代用 display-manager 服务处理这件事；greetd 自行管理 VT，需在此处理。
if [ -f /etc/inittab ]; then
    if grep -qE "^c1:.*tty1" /etc/inittab; then
        sed -i 's|^c1:\(.*\)tty1|#c1:\1tty1  # greetd 独占 tty1|' /etc/inittab
        say "已禁用 tty1 的 getty（交给 greetd）"
    fi
    # chroot 里的 /run 已 bind（见 §4），telinit 走 /run/initctl。
    # 绝不向 PID 1 发 HUP：那打到的是 live ISO 的 init，不是目标系统（P2-11）。
    telinit q 2>/dev/null || warn "telinit q 失败（getty 配置将在重启后生效）"
fi

# 唯一启用的登录入口是 greetd；不再启用 display-manager 包装服务
# （旧版两者都写，M2 上因缺 /etc/conf.d/display-manager 被 doctor 误报）。
# /etc/conf.d/display-manager 仍写一份并指向 greetd，供认这个机制的工具有据可查。
printf 'DISPLAYMANAGER="greetd"\n' > /etc/conf.d/display-manager
rc-update add greetd default || die "greetd 注册失败 —— 没有图形登录界面"
say "已启用 greetd（default runlevel）"


# 14b) 用户态 dbus 会话总线 —— 必须在标准路径 /run/user/$UID/bus 上。
#      Gentoo 两套 dbus：/etc/init.d/dbus 是 --system；
#      /etc/user/init.d/dbus 才是用户会话总线。不启用它，每个会话只能靠
#      dbus-run-session 起 /tmp/dbus-XXXX 临时总线，外部工具（Warehouse、
#      自动化脚本）找不到服务。见 docs/decisions/0010-会话总线与输入法环境.md
mkdir -p /etc/user/runlevels/default
ln -sfn /etc/user/init.d/dbus /etc/user/runlevels/default/dbus

# 音频栈的用户服务。Noctalia 的音量 OSD 与控制中心依赖它，
# pipewire 未启动时 PulseAudio 客户端连不上，OSD 不显示。
for _svc in pipewire pipewire-pulse wireplumber; do
    if [ -f "/etc/user/init.d/$_svc" ]; then
        ln -sfn "/etc/user/init.d/$_svc" "/etc/user/runlevels/default/$_svc"
    fi
done
say "已启用音频用户服务（pipewire / pipewire-pulse / wireplumber）"

# 【P2-08】光有 /etc/user/runlevels/default/* 不够：OpenRC 的用户服务要以
# user.<用户名> 实例进系统 runlevel 才会被拉起。旧版从不建实例，那些软链
# 永远不生效，"音频由用户级 OpenRC 管理"只是注释。模板缺失时不连坐（warn）。
if [ -f /etc/init.d/user ]; then
    ln -sfn /etc/init.d/user /etc/init.d/user.ordo
    # user.ordo 注册失败 = 音频/会话总线用户服务永不启动（P2-08），不能降级为 warn。
    rc-update add user.ordo default || die "user.ordo 注册失败（用户级服务不会启动）"
    say "已启用 user.ordo（用户级 dbus / pipewire 等）"
else
    warn "缺少 /etc/init.d/user（openrc 用户服务模板），用户级服务需手动启用"
fi

# 兼容旧路径（用户级 runlevel 目录）
mkdir -p /home/ordo/.config/rc/runlevels/boot
ln -sfn /etc/user/init.d/dbus /home/ordo/.config/rc/runlevels/boot/dbus
chown -R ordo:ordo /home/ordo/.config 2>/dev/null || true

# 14c) rc/bin 工具符号链接 —— 非 TTY 环境下 openrc 的 functions.sh 会把
#      ebegin/eend/service_set_value 委托给外部二进制，而用户服务的 PATH
#      不含 /usr/libexec/rc/bin，导致 "ebegin: 未找到命令"
for f in /usr/libexec/rc/bin/*; do
    b=$(basename "$f")
    [ -e "/bin/$b" ] || ln -sf "$f" "/bin/$b"
done

# 14d) Umbriel 会话包装脚本 —— 注入输入法环境后启动合成器
#      关键：GTK_IM_MODULE 必须是 wayland（不是 fcitx），否则 GTK 应用
#      走 immodule 绕路，text-input-v3 协议接管不到。
install -Dm755 "/opt/ordo/config/desktop/umbriel/ordo-umbriel-session" /usr/local/bin/ordo-umbriel-session 2>/dev/null \
    || warn "ordo-umbriel-session 部署失败（Umbriel 会话不可用）"

# 【P2-08】x11-misc/xdg-user-dirs 在 config/world 里声明，但交付镜像里
# 没有 /usr/bin/xdg-user-dirs-update（只有 Flatpak runtime 的副本），
# 会话脚本用 `command -v` 静默跳过 → XDG 目录永不初始化。
# 声明 = 系统：缺了就在安装期停下，而不是首启后静默。
command -v xdg-user-dirs-update >/dev/null 2>&1 \
    || die "xdg-user-dirs 未随 @world 安装（config/world 声明了 x11-misc/xdg-user-dirs）"

# 14d-2) ffplay 替身 —— 番茄钟插件的依赖门禁（偏离登记 #65，docs/deviations.md 第十一节）。
#        真 ffplay 属 ffmpeg 的 sdl USE（→ GTK3），替身转调 pw-play。
install -Dm755 "/opt/ordo/config/desktop/ffplay" /usr/local/bin/ffplay 2>/dev/null \
    || warn "ffplay 替身部署失败（番茄钟 bar widget 将不实例化）"

# 14e) Umbriel 会话文件（greetd 从这里读会话列表）
mkdir -p /usr/share/wayland-sessions
cat > /usr/share/wayland-sessions/umbriel.desktop <<'UMBDESK'
[Desktop Entry]
Name=Umbriel (Ordo)
Comment=Wayland compositor with scrolling/dwindle/master/stacking layouts
Exec=/usr/local/bin/ordo-umbriel-session
Type=Application
DesktopNames=Umbriel
UMBDESK

# 14f) 输入法环境 —— 唯一来源是 /etc/env.d/99imm（见 §8），
#      env-update 已把它编译进 /etc/profile.env。这里不再重复写第二份。

# 14g) locale 完整生成 —— 必须同时生成 zh_CN.UTF-8 与 en_US.UTF-8。
#      只生成 zh_CN.utf8（小写）时，LANG=zh_CN.UTF-8 会被 glibc 视为
#      不同 locale，所有 GTK/Qt 应用回退到 C locale：
#        - fuzzel 显示 <no title>
#        - waybar 时钟模块失效
#      这是 2026-11-20 定位到的全局性根因。
printf 'zh_CN.UTF-8 UTF-8\nen_US.UTF-8 UTF-8\n' > /etc/locale.gen
locale-gen 2>/dev/null || warn "locale-gen 失败"

# Luciole 的 base 配置由 `ordo config apply desktop` 软链部署，
# 不在这里 cp —— 拷贝会产生第二份事实来源。

# 14h) 会话环境公共脚本：Umbriel 的 session 脚本 source 它
install -Dm755 "/opt/ordo/config/desktop/ordo-session-env" /usr/local/bin/ordo-session-env 2>/dev/null \
    || warn "ordo-session-env 部署失败（会话起不来）"
# 14i) 用户 dotfiles（starship / wezterm）
# 桌面配置本身（umbriel / noctalia）由 `ordo config apply desktop` 以软链部署，
# 不在这里拷 —— 拷贝会产生第二份事实来源。
_skel="/opt/ordo/config/desktop/skel"
for rel in .config/starship.toml .config/wezterm/wezterm.lua; do
    [ -f "$_skel/$rel" ] || continue
    install -Dm644 "$_skel/$rel" "/home/ordo/$rel" 2>/dev/null || true
done
chown -R ordo:ordo /home/ordo/.config 2>/dev/null || true

# 14j) 桌面配置软链部署 —— OneConfig 的真正落点。
#      【缺陷修复】此前两处注释都写着"由 `ordo config apply desktop` 以软链
#      部署"，但整份脚本从未调用它：新装机 /home/ordo/.config 下没有软链，
#      Umbriel/Noctalia 启动读不到配置（实机是手工补的软链）。
#      执行环境：chroot 内无 DOAS_USER/SUDO_USER，_apply_desktop 以 $HOME
#      定位家目录，因此显式 HOME=/home/ordo；跑完把链接属主交给 ordo。
#      这里必须晚于 §11（/opt/ordo/config 已就位）与 useradd（家目录存在）。
if [ -x /opt/ordo/scripts/ordo-config ]; then
    # 失败即停（AGENTS.md）：桌面配置未部署的系统 = 启动即裸奔，不允许带病完成安装
    HOME=/home/ordo /opt/ordo/scripts/ordo-config apply desktop \
        || die "ordo config apply desktop 失败——桌面配置未部署（修复后重跑安装）"
    # 必须 -h：coreutils 的 chown -R 默认跟随符号链接，会把软链目标
    # /opt/ordo/config 一并改成 ordo 所有 —— 系统声明层变用户可写（P2-08）。
    chown -hR ordo:ordo /home/ordo/.config 2>/dev/null || true
else
    die "找不到 /opt/ordo/scripts/ordo-config —— 桌面配置无从部署（§11 应已安装 CLI）"
fi

# ---- 15) Flatpak 应用清单（config/apps.d）----
# 首启就能干活：浏览器 / 商店 / 文件管理器形状的东西全在 Flatpak。
# 清单是数据（config/apps.d/*.list），本段只负责读它 —— 与 world 同一哲学。
# 清单解析（apps.d 的格式允许行尾理由）：剥掉 `#` 之后的部分再取第一列。
# 旧版只跳过 `#` 开头的行，`org.mozilla.firefox   # 浏览器` 整行被当成
# app id 传给 flatpak，首启没有浏览器（P1-04）。install.sh 与
# config/migrations 共用同一口径，tests/cases/090 断言两边解析结果一致。
flatpak_apps_of() {
    sed -e 's/#.*//' "$1" | awk 'NF { print $1 }'
}

# 【作用域】--user 的安装落在**执行者**家目录：root 执行会装进
# /root/.local/share/flatpak，而首启登录的是 ordo —— 等于没装。
# 所以 remote 与应用都以桌面用户身份执行（P1-04）。
say "安装 Flatpak 应用清单"
_flatpak_user="${ORDO_DESKTOP_USER:-ordo}"
require_flatpak
if ! id -u "$_flatpak_user" >/dev/null 2>&1; then
    warn "桌面用户 $_flatpak_user 不存在，跳过应用清单（首启后用 ordo app install 补装）"
else
    as_flatpak_user() { su -s /bin/sh - "$_flatpak_user" -c "$1"; }
    as_flatpak_user 'flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo' \
        || warn "Flathub remote 添加失败（联网后以 ordo 身份执行：flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo）"
    for _list in /opt/ordo/config/apps.d/*.list; do
        [ -f "$_list" ] || continue
        # 01-optional.list 是「推荐应用」的唯一定义处，不由安装器自动装。
        case "${_list##*/}" in *optional*) continue ;; esac
        _group="$(basename "$_list" .list)"
        flatpak_apps_of "$_list" | while IFS= read -r _app; do
            if as_flatpak_user "flatpak install --user --noninteractive -y flathub '$_app'" >/dev/null 2>&1; then
                say "  $_group: $_app"
            else
                warn "Flatpak 安装失败：${_app}（首启后可用 ordo app install $_app 补装）"
            fi
        done
    done
fi

# ---- 16) 定时快照（宪法承诺"快照全自动"的落点）----
# 【评审发现】旧版只在文档里说 cron 会调 ordo-snap-auto，但从不创建 cron 文件，
# README 却写"快照全自动"——承诺与实现之间没有任何东西。
say "启用定时快照"
mkdir -p /etc/cron.d
cat > /etc/cron.d/ordo-snapshot <<'CRON'
# ordo 定时快照：每小时一次，分档保留（24 小时 / 7 天 / 4 周）
# 执行体是 repo 的 scripts/ordo-snap-auto（§11 安装到 /opt/ordo/scripts/，
# 软链到 /usr/local/bin），对象是 RUNNING_ROOT（回滚后也对）
SHELL=/bin/sh
PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/sbin
17 * * * * root /usr/local/bin/ordo-snap-auto >/dev/null 2>&1
CRON
chmod 644 /etc/cron.d/ordo-snapshot
rc-update add cronie default 2>/dev/null || warn "cronie 注册失败（定时快照不会运行）"

# ---- 17) 构建清单（P1-02：verify 的期望值来源）----
# 旧版的 `ordo config verify` 拿 /opt/ordo/config 和由它自己派生出的
# /etc/portage/sets/ordo-core 比 —— 两边同源，verdict 恒绿；镜像里的
# 旧副本（world 少 4 个 atom、会话脚本 1777B、版本三处不一致）照报「一致」。
# 生成逻辑统一在 scripts/ordo-build-manifest：install.sh / M2 外置安装 /
# VM 装配三处共用同一格式，verify 只认这份清单（缺失 = 无法判定，不是通过）。
say "写入构建清单（/etc/ordo/build-manifest）"
sh /opt/ordo/scripts/ordo-build-manifest / "$ORDO_PLATFORM" "$ARCH" \
    || die "构建清单生成失败（/etc/ordo/build-manifest）"

say "chroot 完成"
CHROOT
    rm -rf -- "$TARGET/var/tmp/ordo-source"
fi

# ---------- 5. 收尾：干净卸载 + 干净导出（首次开机无脏状态） ----------
say "收尾：卸载并干净导出 pool"
for mount_dir in dev sys proc run efi; do
    if mountpoint -q "$TARGET/$mount_dir"; then
        umount -R "$TARGET/$mount_dir"
    fi
done
zfs unmount "$HOME_DATASET"
zfs unmount "$DATASET"

zfs set org.zfsbootmenu:active=on "$DATASET"
zpool export "$POOL"
pool_created=0

if [ "$ORDO_LAYOUT_ONLY" = 1 ]; then
    say "布局验证完成：池已导出，未安装可引导系统"
    exit 0
fi

say "完成。reboot 后将从 ZFSBootMenu 引导新系统"
say "安装完成。默认用户：ordo（登录 dn 口令见上方 chroot 阶段输出的一次性随机密码）"
