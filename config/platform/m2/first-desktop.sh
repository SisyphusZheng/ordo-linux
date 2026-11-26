#!/bin/sh
set -eu
src=/opt/ordo/config/desktop
getent passwd ordo >/dev/null
python3 /opt/ordo/config/platform/m2/repair-package-defaults.py
sh "$src/m2-desktop-fix.sh"
sh /opt/ordo/config/platform/m2/install-hardware.sh
for program in /usr/bin/umbriel /usr/bin/start-umbriel /usr/bin/noctalia /usr/bin/greetd /usr/bin/noctalia-greeter-session /etc/init.d/greetd; do
    [ -x "$program" ] || { echo "Missing $program" >&2; exit 1; }
done
install -m 755 "$src/umbriel/ordo-umbriel-session" /usr/local/bin/
install -m 755 "$src/ordo-session-env" /usr/local/bin/
install -Dm644 "$src/wallpapers/wallpaper-blackhole.png" /usr/share/backgrounds/ordo/wallpaper-blackhole.png
HOME=/home/ordo XDG_CONFIG_HOME=/home/ordo/.config ORDO_CONF_DIR=/opt/ordo/config /opt/ordo/scripts/ordo-config apply desktop
chown -hR ordo:ordo /home/ordo/.config
test -r /home/ordo/.config/umbriel/config.toml
test -r /home/ordo/.config/noctalia/config.toml
install -d -m 755 /var/lib/ordo /home/.ordo
# 首启 marker 在 /home（独立数据集），系统 BE 回滚不会把它带回「未首启」。
# 旧版放在 /var/lib/ordo（根数据集）：升级时搬过去，否则回滚后还会自动登录一次。
if [ -e /var/lib/ordo/greetd-first-session ]; then
    if [ -e /home/.ordo/greetd-first-session ]; then
        rm -f /var/lib/ordo/greetd-first-session
    else
        mv /var/lib/ordo/greetd-first-session /home/.ordo/greetd-first-session
    fi
fi
cat "$src/greetd/config.toml" "$src/greetd/first-boot.toml" > /etc/greetd/config.toml.new
mv /etc/greetd/config.toml.new /etc/greetd/config.toml
# 重装幂等：marker 已存在说明首启已完成，保留即可，不能 die（旧版 test ! -e 会中断安装）。
if [ -d /etc/ordo ] && [ "$(readlink -f /etc/ordo)" != /opt/ordo/config ]; then
    ln -sfn /opt/ordo/config/check-build /etc/ordo/check-build
    ln -sfn /opt/ordo/config/world.sh /etc/ordo/world.sh
fi
rc-update add greetd default
test -L /etc/runlevels/default/greetd

# 【P2-08】用户级 dbus / pipewire 服务要以 user.<用户> 实例进 runlevel 才会被拉起；
# M2 路径过去只装 /etc/user/runlevels/default/* 软链，从不建实例（install.sh 已有）。
if [ -f /etc/init.d/user ]; then
    ln -sfn /etc/init.d/user /etc/init.d/user.ordo
    rc-update add user.ordo default || { echo "user.ordo 注册失败" >&2; exit 1; }
else
    echo "缺少 /etc/init.d/user（openrc 用户服务模板）" >&2
    exit 1
fi

# 首启应用清单（P1-04）：M2 路径过去不读 config/apps.d，装完没有浏览器与商店。
# 安装器不假设联网，只登记 local.d 一次性任务；首启由 ordo 用户装清单里的应用。
install -m 755 /opt/ordo/config/platform/m2/first-apps.sh /usr/local/sbin/ordo-first-apps
# oneshot 只有在 local 进了默认 runlevel 才会跑
if [ -x /etc/init.d/local ]; then
    rc-update add local default
fi
install -d -m 755 /etc/local.d
cat > /etc/local.d/70-ordo-first-apps.start <<'FIRSTAPPS'
#!/bin/sh
exec /usr/local/sbin/ordo-first-apps
FIRSTAPPS
chmod 755 /etc/local.d/70-ordo-first-apps.start
