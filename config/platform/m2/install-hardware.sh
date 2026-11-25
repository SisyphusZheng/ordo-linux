#!/bin/sh
# Deploy the local, offline half of the Mac14,2 hardware configuration.
set -eu
here=$(dirname "$(readlink -f "$0")")

install -d -m 0755 /etc/ordo
if [ ! -f /etc/ordo/platform ] || [ "$(cat /etc/ordo/platform)" != m2-native ]; then
    printf 'm2\n' > /etc/ordo/platform.new
    mv -f /etc/ordo/platform.new /etc/ordo/platform
fi

install -Dm755 "$here/verify-hardware.sh" /usr/local/bin/ordo-m2-hardware
install -Dm755 "$here/keyboard-light.sh" /usr/local/bin/ordo-keyboard-light
install -Dm644 "$here/package.use" /etc/portage/package.use/ordo-m2
install -Dm644 "$here/package.accept_keywords" /etc/portage/package.accept_keywords/ordo-m2
install -Dm644 "$here/world" /etc/portage/sets/ordo-m2

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
