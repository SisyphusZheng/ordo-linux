#!/bin/sh
# Invoked in the isolated VM image chroot with its home and EFI partitions mounted.
set -eu
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

repo=/opt/ordo
desktop=$repo/config/desktop
vm=$repo/config/platform/utm
release=$1

sh "$desktop/keyring-policy.sh" check

for program in umbriel start-umbriel noctalia noctalia-greeter-session greetd dbus-uuidgen setsid chvt; do
    command -v "$program" >/dev/null
done
if awk -F: '$3 >= 1000 && $3 < 65534 { found=1 } END { exit !found }' /etc/passwd; then
    printf 'The clean VM base already has a regular user.\n' >&2
    exit 1
fi

local_repo=$(portageq get_repo_path / local)
case "$local_repo" in
    /*) ;;
    *) printf 'Cannot locate the local Portage overlay in the VM base.\n' >&2; exit 1 ;;
esac
luciole=gui-apps/luciole
# ebuild 名带版本号（升级只换文件名）：按 glob 校验，不在装配器里钉死版本。
install -Dm644 "$repo/overlay/$luciole/Manifest" "$local_repo/$luciole/Manifest"
for ebuild in "$repo/overlay/$luciole"/*.ebuild; do
    test -f "$ebuild"
    install -Dm644 "$ebuild" "$local_repo/$luciole/${ebuild##*/}"
done

groupadd -f plugdev
useradd -m -G wheel,video,input,plugdev,portage ordo
passwd -l root
install -d /etc/ordo /etc/greetd /etc/zfs /var/lib/dbus /var/lib/ordo /etc/tmpfiles.d /etc/user/runlevels/default
version=$(cat "$repo/version")
cat > /etc/os-release.new <<OS_RELEASE
NAME="Ordo Linux"
ID=ordo
ID_LIKE=gentoo
VERSION_ID="$version"
PRETTY_NAME="Ordo Linux $version"
OS_RELEASE
mv /etc/os-release.new /etc/os-release
printf '%s\n' ordo-vm > /etc/hostname
printf '%s\n' vm > /etc/ordo/platform
cat "$vm/dataset" "$repo/config/dataset" > /etc/ordo/dataset
printf '%s\n' 'permit persist :wheel' > /etc/doas.conf
chmod 400 /etc/doas.conf
rm -f /etc/machine-id /var/lib/dbus/machine-id /etc/hostid /etc/zfs/zpool.cache
install -m 444 /dev/null /etc/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id
zgenhostid
rm -f /etc/ssh/ssh_host_* /etc/NetworkManager/system-connections/* /var/lib/ordo/greetd-first-session
rm -f /var/lib/NetworkManager/secret_key /var/lib/NetworkManager/seen-bssids \
    /var/lib/NetworkManager/timestamps
for level in /etc/runlevels/*; do
    rm -f "$level/sshd" "$level/display-manager" "$level/gdm" "$level/speakersafetyd"
done

install -d /usr/local/bin
for entry in ordo sysup ordo-snap ordo-snap-auto ordo-backup ordo-config ordo-migrate ordo-selfcheck; do
    test -x "$repo/scripts/$entry"
    ln -sfn "$repo/scripts/$entry" "/usr/local/bin/$entry"
done
ln -sfn "$repo/scripts/doctor" /usr/local/bin/ordo-doctor
ordo selfcheck

cp -R "$desktop/skel/." /etc/skel/
cp -R "$desktop/skel/." /home/ordo/
install -Dm755 "$desktop/umbriel/ordo-umbriel-session" /usr/local/bin/ordo-umbriel-session
install -Dm755 "$desktop/ordo-session-env" /usr/local/bin/ordo-session-env
install -Dm755 "$desktop/ffplay" /usr/local/bin/ffplay
install -Dm644 "$desktop/wallpapers/wallpaper-blackhole.png" /usr/share/backgrounds/ordo/wallpaper-blackhole.png
install -Dm755 "$desktop/greetd/greetd.initd" /etc/init.d/greetd
install -Dm644 "$desktop/greetd/pam.d-greetd" /etc/pam.d/greetd
install -Dm644 "$desktop/greetd/tmpfiles-noctalia-greeter.conf" /etc/tmpfiles.d/noctalia-greeter.conf
cat "$desktop/greetd/config.toml" "$desktop/greetd/first-boot.toml" > /etc/greetd/config.toml
if ! getent passwd greetd >/dev/null; then
    groupadd -f greetd
    useradd -r -g greetd -d /var/lib/greetd -s /sbin/nologin greetd
fi
usermod -aG video,input greetd
install -d -m 750 -o greetd -g greetd /var/lib/greetd
systemd-tmpfiles --create /etc/tmpfiles.d/noctalia-greeter.conf
install -Dm644 "$desktop/99imm" /etc/env.d/99imm
env-update

HOME=/home/ordo XDG_CONFIG_HOME=/home/ordo/.config ORDO_CONF_DIR="$repo/config" \
    "$repo/scripts/ordo-config" apply desktop
chown -hR ordo:ordo /home/ordo
sed -i -E '/^[^#][^:]*:.*[[:space:]]tty1([[:space:]]|$)/s/^/# /' /etc/inittab
install -m 755 "$vm/firstboot.initd" /etc/init.d/ordo-vm-firstboot
install -Dm755 "$vm/firstboot.sh" /usr/local/sbin/ordo-vm-firstboot
printf '%s\n' 'rc_need="ordo-vm-firstboot"' > /etc/conf.d/greetd
for service in ordo-vm-firstboot dbus elogind greetd NetworkManager local; do
    rc-update add "$service" default
done
install -Dm755 "$repo/config/zfs-arc.start" /etc/local.d/zz-zfs-arc.start
for svc in dbus pipewire pipewire-pulse wireplumber; do
    [ -f "/etc/user/init.d/$svc" ] || continue
    ln -sfn "/etc/user/init.d/$svc" "/etc/user/runlevels/default/$svc"
done
# P2-08：用户级 OpenRC 服务要以 user.ordo 实例进 default runlevel 才会被拉起；
# 只建 /etc/user/runlevels/default/* 软链不生效。模板缺失 = 镜像基础不完整。
test -f /etc/init.d/user
ln -sfn /etc/init.d/user /etc/init.d/user.ordo
rc-update add user.ordo default
for helper in /usr/libexec/rc/bin/*; do
    [ -f "$helper" ] || continue
    [ -e "/bin/${helper##*/}" ] || ln -s "$helper" "/bin/${helper##*/}"
done
install -d /usr/share/wayland-sessions
cat > /usr/share/wayland-sessions/umbriel.desktop <<'DESKTOP'
[Desktop Entry]
Name=Umbriel (Ordo)
Exec=/usr/local/bin/ordo-umbriel-session
Type=Application
DesktopNames=Umbriel
DESKTOP

modules=/lib/modules/$release
test -s "/boot/vmlinuz-$release"
test -d "$modules"
python3 "$repo/config/platform/m2/repair-package-defaults.py" --zfs-only
depmod "$release"
for driver in zfs virtio_blk virtio_pci virtio_gpu snd_hda_intel; do
    modinfo -k "$release" "$driver" >/dev/null
done
mod_version=$(modinfo -k "$release" -F version zfs)
usr_version=$(zfs version 2>/dev/null | sed -n '1s/^zfs-//p')
if [ -z "$mod_version" ] || [ "$mod_version" != "$usr_version" ]; then
    printf 'ZFS module (%s) and userspace (%s) differ.\n' "$mod_version" "$usr_version" >&2
    exit 1
fi

install -D -m 644 "$vm/dracut.conf" /etc/dracut.conf.d/40-ordo-utm.conf
dracut --zstd --no-hostonly --no-early-microcode --force "/boot/initramfs-$release.img" "$release"
install -D -m 644 "$vm/zfsbootmenu.yaml" /etc/zfsbootmenu/config.yaml
generate-zbm --kver "$release"
test -s /efi/EFI/BOOT/BOOTAA64.EFI

# ---- 构建清单（P1-02）----
# VM 装配是清单的第三个生产者：verify 在镜像里只认这份清单，
# 缺了它 `ordo config verify` 恒 exit 2（无法判定）。生成器与 install.sh /
# M2 外置安装共用 scripts/ordo-build-manifest，格式只在那里定义。
# 架构固定 arm64：dev/vm/build-disk.sh 拒绝非 aarch64 宿主机。
sh "$repo/scripts/ordo-build-manifest" / "$(cat /etc/ordo/platform)" arm64
