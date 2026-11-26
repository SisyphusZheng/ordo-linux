#!/bin/sh
# Refresh previously installed M2 command wrappers to the packaged CLI.
set -eu
scripts=/opt/ordo/scripts
bin=/usr/local/bin
mkdir -p "$bin"
set -- ordo sysup ordo-snap ordo-snap-auto ordo-backup ordo-config ordo-migrate ordo-selfcheck ordo-doctor ordo-wifi

for command do
    entry=$command
    [ "$command" != ordo-doctor ] || entry=doctor
    [ -x "$scripts/$entry" ] || { printf '缺少 Ordo CLI：%s\n' "$entry" >&2; exit 1; }
    if [ -d "$bin/$command" ] && [ ! -L "$bin/$command" ]; then
        printf 'Ordo CLI 的路径是目录：%s\n' "$bin/$command" >&2
        exit 1
    fi
done

for command do
    entry=$command
    [ "$command" != ordo-doctor ] || entry=doctor
    ln -sfn "$scripts/$entry" "$bin/$command"
done
"$bin/ordo" --help >/dev/null
