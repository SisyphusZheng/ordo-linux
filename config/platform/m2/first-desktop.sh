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
install -d -m 755 /var/lib/ordo
cat "$src/greetd/config.toml" "$src/greetd/first-boot.toml" > /etc/greetd/config.toml.new
mv /etc/greetd/config.toml.new /etc/greetd/config.toml
test ! -e /var/lib/ordo/greetd-first-session
if [ -d /etc/ordo ] && [ "$(readlink -f /etc/ordo)" != /opt/ordo/config ]; then
    ln -sfn /opt/ordo/config/check-build /etc/ordo/check-build
    ln -sfn /opt/ordo/config/world.sh /etc/ordo/world.sh
fi
rc-update add greetd default
test -L /etc/runlevels/default/greetd
