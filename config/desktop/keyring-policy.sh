#!/bin/sh
# Deploy the Ordo client-only Secret Service library policy.
set -eu
here=$(dirname "$(readlink -f "$0")")
config=$(dirname "$here")
repo=$(dirname "$config")

check() {
    # 【P1-05】set -e 下裸 portageq 缺包即静默退出 1：安装器只会报
    # 「旧版密钥服务 / 硬件包引入了密钥服务」这类无关提示。缺包必须自己
    # 说清缺的是哪个包；portageq 自身异常按「无法判定」返回 2。
    if portageq has_version / app-crypt/libsecret::local; then
        :
    else
        _rc=$?
        case "$_rc" in
            1)
                printf '%s\n' '缺少 app-crypt/libsecret::local（Secret Service 客户端库未安装）' >&2
                return 1 ;;
            *)
                printf '无法判定 app-crypt/libsecret::local 的安装状态（portageq 退出码 %s）\n' "$_rc" >&2
                return 2 ;;
        esac
    fi
    if portageq has_version / app-crypt/pinentry; then
        portageq has_version / "app-crypt/pinentry[-gtk,-keyring,ncurses]" || return 1
    else
        [ "$?" -eq 1 ] || return 2
    fi
    for atom in gnome-base/gnome-keyring virtual/secret-service; do
        if portageq has_version / "$atom"; then
            printf 'Unexpected installed package: %s\n' "$atom" >&2
            return 1
        else
            [ "$?" -eq 1 ] || return 2
        fi
    done
    for path in /usr/bin/gnome-keyring-daemon /usr/bin/gnome-keyring \
        /usr/share/dbus-1/services/org.freedesktop.secrets.service \
        /usr/share/dbus-1/services/org.freedesktop.impl.portal.Secret.service \
        /usr/share/dbus-1/services/org.gnome.keyring.service \
        /usr/share/dbus-1/services/org.gnome.keyring.PrivatePrompter.service \
        /usr/share/dbus-1/services/org.gnome.keyring.SystemPrompter.service \
        /etc/xdg/autostart/gnome-keyring-*.desktop \
        /lib*/security/pam_gnome_keyring.so /usr/lib*/security/pam_gnome_keyring.so; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            printf 'Unexpected keyring activation file: %s\n' "$path" >&2
            return 1
        fi
    done
    if [ -r /etc/pam.d/greetd ] && grep -Eq '^[[:space:]]*[^#[:space:]].*pam_gnome_keyring[.]so' /etc/pam.d/greetd; then
        printf '%s\n' 'Unexpected GNOME Keyring PAM configuration' >&2
        return 1
    fi
    return 0
}

case "${1:-}" in
    check) check ;;
    configure)
        local_repo=$(portageq get_repo_path / local)
        case "$local_repo" in /*) ;; *) exit 1 ;; esac
        for file in Manifest libsecret-0.21.8.2-r100.ebuild metadata.xml \
            files/libsecret-0.21.7-optional-vala-tests.patch files/libsecret-0.21.8.2-musl-fcntl.patch; do
            install -Dm644 "$repo/overlay/app-crypt/libsecret/$file" "$local_repo/app-crypt/libsecret/$file"
        done
        install -Dm644 "$config/package.mask/ordo-keyring" /etc/portage/package.mask/ordo-keyring
        install -Dm644 "$config/package.use/ordo-keyring" /etc/portage/package.use/ordo-keyring
        ;;
    remove)
        portageq has_version / app-crypt/libsecret::local
        if [ -f /etc/pam.d/greetd ]; then
            install -m 644 "$here/greetd/pam.d-greetd" /etc/pam.d/greetd
        fi
        # Remove the virtual first. Its installed dependency can protect the daemon
        # from being removed in the same depclean invocation.
        for atom in virtual/secret-service gnome-base/gnome-keyring; do
            if portageq has_version / "$atom"; then
                emerge --ask=n --deselect "$atom"
                emerge --ask=n --depclean "$atom"
            else
                [ "$?" -eq 1 ] || exit 2
            fi
        done
        check
        ;;
    *)
        printf 'Usage: %s {configure|remove|check}\n' "$0" >&2
        exit 2
        ;;
esac
