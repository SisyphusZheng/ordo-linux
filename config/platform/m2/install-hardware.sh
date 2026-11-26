#!/bin/sh
# Deploy the local, offline half of the Mac14,2 hardware configuration.
set -eu
here=$(dirname "$(readlink -f "$0")")

install -d -m 0755 /etc/ordo
# 只在平台文件缺失时补写：已经写成 m2-native 的机器不能被这一步降级成 m2，
# 否则 @ordo-m2 包集与 AGX 渲染等待都会悄悄失效（P1-06）。
if [ ! -e /etc/ordo/platform ]; then
    printf 'm2\n' > /etc/ordo/platform.new
    mv -f /etc/ordo/platform.new /etc/ordo/platform
fi

install -Dm755 "$here/verify-hardware.sh" /usr/local/bin/ordo-m2-hardware
install -Dm755 "$here/keyboard-light.sh" /usr/local/bin/ordo-keyboard-light
install -Dm644 "$here/package.use" /etc/portage/package.use/ordo-m2
install -Dm644 "$here/package.accept_keywords" /etc/portage/package.accept_keywords/ordo-m2
install -Dm644 "$here/world" /etc/portage/sets/ordo-m2
# 平台原生包集必须真的被选中：只写 /etc/portage/sets 而不同步 world_sets 时，
# @world 里没有它，一次 emerge --depclean 就能把 speakersafetyd 摘掉（P1-06）。
if [ "$(id -u)" = 0 ]; then
    install -d -m 0755 /var/lib/portage
    : >> /var/lib/portage/world_sets
    grep -Fxq '@ordo-m2' /var/lib/portage/world_sets ||
        printf '%s\n' '@ordo-m2' >> /var/lib/portage/world_sets
fi

# A partially populated package staging area must never activate speakers.
if [ -x /etc/init.d/speakersafetyd ] &&
   [ -r /usr/share/speakersafetyd/apple/j413.conf ] &&
   [ -r /usr/share/asahi-audio/j413/graph.json ] &&
   [ -r /usr/share/asahi-audio/j413/mic.json ] &&
   [ -r '/usr/share/alsa/ucm2/conf.d/macaudio/MacBook Air J413.conf' ] &&
   portageq has_version / '=sys-apps/speakersafetyd-2.0.1::asahi' &&
   portageq has_version / '~media-libs/asahi-audio-4.1::asahi' &&
   portageq has_version / '=media-libs/alsa-ucm-conf-asahi-10::asahi'; then
    install -Dm644 "$here/speakersafetyd.conf" /etc/conf.d/speakersafetyd
    rc-update add speakersafetyd default
fi
