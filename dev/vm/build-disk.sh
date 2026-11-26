#!/bin/bash
# Create a UEFI/GPT VM disk from a freshly assembled public rootfs.
set -euo pipefail

if [[ $# != 4 ]]; then
    printf 'Usage: %s CLEAN_BASE KERNEL_TREE KERNEL_RELEASE OUTPUT_DIRECTORY\n' "$0" >&2
    exit 2
fi
if [[ $(uname -s) != Linux || $(uname -m) != aarch64 || $EUID != 0 ]]; then
    printf 'Build in an isolated Linux ARM64 VM as root.\n' >&2
    exit 2
fi

here=$(dirname "$(readlink -f "$0")")
platform_config=$here/../../config/platform
vm_config=$platform_config/utm
base=$(realpath "$1")
kernel=$(realpath "$2")
release=$3
mkdir -p "$4"
output=$(realpath "$4")
pool=ordovm
be=$pool/root/ordo
home=$pool/home

[[ $release =~ ^[A-Za-z0-9._+-]+$ && -s "$kernel/boot/vmlinuz-$release" ]]
[[ -d "$kernel/lib/modules/$release" ]]
[[ -f "$base/opt/ordo/version" && -x "$base/opt/ordo/scripts/ordo-config" ]]
[[ -f "$vm_config/firstboot.sh" ]]
version=$(cat "$base/opt/ordo/version")
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
for command in zpool zfs sfdisk losetup mkfs.vfat mount umount tar; do
    command -v "$command" >/dev/null
done
if zpool list -H -o name "$pool" >/dev/null 2>&1; then
    printf 'Refusing to use the already imported %s pool.\n' "$pool" >&2
    exit 1
fi
disk="$output/Ordo Linux $version ARM64.raw"
if [[ -e $disk || -L $disk ]]; then
    printf 'Output already exists: %s\n' "$disk" >&2
    exit 1
fi

work=$(mktemp -d "$output/.ordo-vm.XXXXXX")
data=$work/disk.raw
root=$work/root
loop=
imported=0
mounts=()
cleanup() {
    local rc=$? i
    trap - EXIT
    for ((i=${#mounts[@]}-1; i>=0; i--)); do
        umount -R "${mounts[i]}" || rc=1
    done
    if ((imported)); then
        zpool export "$pool" || rc=1
    fi
    if [[ -n $loop ]]; then
        losetup -d "$loop" || rc=1
    fi
    if ((rc)); then
        printf 'Build stopped; staging remains at %s\n' "$work" >&2
        exit "$rc"
    fi
    ln -T "$data" "$disk"
    rm "$data"
    rmdir "$root" "$work"
    printf '%s\n' "$disk"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

mkdir "$root"
truncate -s 48G "$data"
sfdisk "$data" <<'GPT'
label: gpt
size=512M, type=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
type=6a898cc3-1dd2-11b2-99a6-080020736631
GPT
loop=$(losetup --find --show --partscan "$data")
esp=${loop}p1
system=${loop}p2
[[ -b $esp && -b $system ]]
mkfs.vfat -F 32 -n ORDO_EFI "$esp"
zpool create -o ashift=12 -o cachefile=none \
    -O compression=zstd -O atime=off -O mountpoint=none \
    -O acltype=posixacl -O xattr=sa "$pool" "$system"
imported=1
zfs create "$pool/root"
zfs create -o canmount=noauto -o mountpoint=legacy "$be"
zfs create -o mountpoint=legacy "$home"
zpool set "bootfs=$be" "$pool"
zfs set org.zfsbootmenu:rootprefix=zfs: \
    'org.zfsbootmenu:commandline=ro console=ttyAMA0,115200 console=tty0' "$pool/root"
zfs set org.zfsbootmenu:active=on "$be"
mount -t zfs "$be" "$root"
mounts+=("$root")

tar -C "$base" --one-file-system --numeric-owner --acls --xattrs --xattrs-include='*' \
    --exclude='./.ordo-base-prepared' \
    --exclude='./dev/*' --exclude='./proc/*' --exclude='./sys/*' --exclude='./run/*' \
    --exclude='./home/*' --exclude='./tmp/*' --exclude='./var/tmp/*' --exclude='./var/log/*' \
    --exclude='./var/cache/distfiles/*' --exclude='./var/cache/binpkgs/*' \
    --exclude='./root/.ssh' --exclude='./root/.gnupg' --exclude='./root/.cache' \
    --exclude='./root/.*history' --exclude='./opt/ordo/.git' --exclude='./efi/*' -cpf - . |
    tar -C "$root" --numeric-owner --acls --xattrs --xattrs-include='*' -xpf -
mkdir -p "$root/opt/ordo/config/platform/utm"
cp -a "$vm_config/." "$root/opt/ordo/config/platform/utm/"
install -m 644 "$platform_config/../desktop/keyring-policy.sh" "$root/opt/ordo/config/desktop/"
install -m 755 "$platform_config/m2/repair-package-defaults.py" "$root/opt/ordo/config/platform/m2/"
mkdir -p "$root"/{boot,dev,efi,home,proc,run,sys}
mount -t vfat "$esp" "$root/efi"
mounts+=("$root/efi")
mount -t zfs "$home" "$root/home"
mounts+=("$root/home")
esp_uuid=$(blkid -s PARTUUID -o value "$esp")
[[ -n $esp_uuid ]]
printf 'PARTUUID=%s /efi vfat umask=0077,noatime 0 2\n%s /home zfs defaults 0 0\n' \
    "$esp_uuid" "$home" > "$root/etc/fstab"

mkdir -p "$root/lib/modules/$release"
cp -a "$kernel/lib/modules/$release/." "$root/lib/modules/$release/"
rm -f "$root/lib/modules/$release"/{source,build}
install -m 644 "$kernel/boot/vmlinuz-$release" "$root/boot/"
if [[ -f "$kernel/boot/config-$release" ]]; then
    install -m 644 "$kernel/boot/config-$release" "$root/boot/"
fi
for dir in proc sys; do
    mount --rbind "/$dir" "$root/$dir"
    mounts+=("$root/$dir")
    mount --make-rslave "$root/$dir"
done
mount -t tmpfs -o nosuid,mode=755 tmpfs "$root/dev"
mounts+=("$root/dev")
for node in null zero full random urandom tty console zfs; do
    touch "$root/dev/$node"
    mount --bind "/dev/$node" "$root/dev/$node"
done
ln -s /proc/self/fd "$root/dev/fd"
ln -s fd/0 "$root/dev/stdin"
ln -s fd/1 "$root/dev/stdout"
ln -s fd/2 "$root/dev/stderr"
mount -t tmpfs -o nosuid,nodev,mode=755 tmpfs "$root/run"
mounts+=("$root/run")
install -m 755 "$here/configure-root.sh" "$root/tmp/ordo-vm-configure"
chroot "$root" /tmp/ordo-vm-configure "$release"
rm "$root/tmp/ordo-vm-configure"
[[ ! -s "$root/etc/machine-id" && ! -e "$root/var/lib/ordo/greetd-first-session" ]]
[[ -z $(find "$root/etc/ssh" -maxdepth 1 -name 'ssh_host_*' -print -quit 2>/dev/null || :) ]]
zpool sync "$pool"
