#!/bin/sh
set -eu

if [ ! -s /etc/machine-id ]; then
    temp_id=$(mktemp /etc/.machine-id.XXXXXX)
    trap 'rm -f "$temp_id"' EXIT HUP INT TERM
    dbus-uuidgen > "$temp_id"
    chmod 444 "$temp_id"
    mv -f "$temp_id" /etc/machine-id
    trap - EXIT HUP INT TERM
fi

password_status=$(LC_ALL=C passwd -S ordo | awk '{ print $2 }')
[ "$password_status" != P ] || exit 0

# greetd starts after firstboot, so tty1 is available until passwd succeeds.
chvt 1
exec </dev/tty1 >/dev/tty1 2>&1
printf '\nOrdo Linux\nSet the password for the local ordo account.\n\n'
while ! setsid --ctty --wait passwd ordo; do
    printf '\nTry again to set the ordo password.\n'
done
