#!/bin/sh
# Merge verified local native binary packages into the freshly installed BE.
set -eu
release=$1
root_id=$2
native=/var/tmp/ordo-native
platform=/opt/ordo/config/platform/m2
repository=/var/db/repos/ordo-asahi
revision=$(cat "$platform/asahi-revision")

# Portage reads env.d during each offline merge, before first-desktop runs.
sh /opt/ordo/config/desktop/m2-desktop-fix.sh

if [ ! -e "$repository" ]; then
    install -d /var/db/repos
    temporary=$(mktemp -d /var/db/repos/.ordo-asahi.XXXXXX)
    trap 'rm -rf "$temporary"' EXIT
    chmod 0755 "$temporary"
    tar --no-same-owner -xzf "$native/asahi-repo.tar.gz" -C "$temporary"
    printf '%s\n' "$revision" > "$temporary/.ordo-revision"
    mv -T "$temporary" "$repository"
    trap - EXIT
fi
test "$(cat "$repository/.ordo-revision")" = "$revision"
test "$(cat "$repository/profiles/repo_name")" = asahi
install -Dm644 "$platform/asahi.conf" /etc/portage/repos.conf/ordo-asahi.conf

[ -s "$native/package-atoms" ] && [ -s "$native/binpkgs/Packages" ]
set --
while IFS= read -r atom; do
    case "$atom" in
        (=*/*-[0-9]*) set -- "$@" "$atom" ;;
        (*) exit 1 ;;
    esac
done < "$native/package-atoms"
[ "$#" -gt 0 ]

# The installer's pinned archive authenticates the local binary packages.
# Keep the target's configured remote-binhost signature policy in place.
FEATURES="-binpkg-request-signature -getbinpkg -buildpkg" PKGDIR="$native/binpkgs" \
    EMERGE_DEFAULT_OPTS='' PORTAGE_BINHOST='' \
    emerge --ask=n --oneshot --usepkgonly --getbinpkg=n --with-bdeps=n "$@"
for atom do
    portageq has_version / "$atom"
done
FEATURES="-binpkg-request-signature -getbinpkg -buildpkg" PKGDIR="$native/binpkgs" \
    EMERGE_DEFAULT_OPTS='' PORTAGE_BINHOST='' \
    emerge --ask=n --select --noreplace --usepkgonly --getbinpkg=n --with-bdeps=n @ordo-m2
while IFS= read -r atom || [ -n "$atom" ]; do
    case "$atom" in ''|'#'*) continue ;; esac
    portageq has_version / "$atom"
done < /etc/portage/sets/ordo-m2

depmod "$release"
modinfo -k "$release" asahi >/dev/null
module_version=$(modinfo -k "$release" -F version zfs)
user_version=$(zfs version | sed -n '1s/^zfs-//p')
[ -n "$module_version" ] && [ "$module_version" = "$user_version" ]
# shellcheck disable=SC2034 # read by the sourced boot helper
ORDO_ROOT=/opt/ordo
# shellcheck source=config/platform/m2/boot-sync.sh
. "$platform/boot-sync.sh"
m2_boot_check_native_install "$native" "$release" "$root_id" "$module_version"

install -d -m 0755 /etc/ordo
marker=$(mktemp /etc/ordo/.platform.XXXXXX)
trap 'rm -f "$marker"' EXIT
printf '%s\n' m2-native > "$marker"
chmod 0644 "$marker"
mv -f "$marker" /etc/ordo/platform
