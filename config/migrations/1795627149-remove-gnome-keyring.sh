#!/bin/sh
set -eu
here=$(dirname "$(readlink -f "$0")")
policy=$here/../desktop/keyring-policy.sh
sh "$policy" configure
if ! portageq has_version / app-crypt/libsecret::local ||
   ! portageq has_version / "app-crypt/pinentry[-gtk,-keyring,ncurses]"; then
    sh "$here/../check-build" jobs "$(portageq envvar MAKEOPTS)"
    sh "$here/../check-build" arc
    emerge --ask=n --oneshot --newuse app-crypt/libsecret::local app-crypt/pinentry
fi
sh "$policy" remove
