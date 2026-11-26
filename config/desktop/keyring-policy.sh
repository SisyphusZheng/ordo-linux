#!/bin/sh
# Ordo 密钥服务策略：Secret Service 已回归（2026-11-26 收回旧偏离）。
#
# check 验证「服务确实被声明与接线」，有会话总线时再做一次 secret-tool 往返；
# 三态：0 齐备 | 1 缺件 | 2 无法判定。
# configure 只做幂等声明收敛；remove 保留为空操作，兼容旧镜像的调用点。
set -eu
here=$(dirname "$(readlink -f "$0")")
config=$(dirname "$here")

check() {
    _missing=0

    # 1) world 必须声明 Secret Service 提供者（gnome-keyring）。
    _world=$config/world
    if [ ! -r "$_world" ]; then
        printf '无法判定 %s：文件不存在或不可读\n' "$_world" >&2
        return 2
    fi
    if ! grep -Eq '^[[:space:]]*(app-crypt|gnome-base)/gnome-keyring([[:space:]]|$|::)' "$_world"; then
        printf '缺少 gnome-keyring：world 未声明 Secret Service 提供者（%s）\n' "$_world" >&2
        _missing=1
    fi

    # 2) 任何 package.mask 都不得再遮蔽服务；目录整体缺失视为「无 mask」。
    _maskdir=$config/package.mask
    if [ -d "$_maskdir" ]; then
        for _mask in "$_maskdir"/*; do
            [ -e "$_mask" ] || continue
            if [ ! -r "$_mask" ]; then
                printf '无法判定 %s：文件不可读\n' "$_mask" >&2
                return 2
            fi
            if sed 's/#.*//' "$_mask" |
               grep -Eq '(^|[<>=~])[[:space:]]*((app-crypt|gnome-base)/gnome-keyring|virtual/secret-service|app-crypt/libsecret)([[:space:]]|$|[-:])'; then
                printf 'package.mask 仍在遮蔽密钥服务：%s\n' "$_mask" >&2
                _missing=1
            fi
        done
    fi

    # 3) greetd PAM 必须显式接 auth 与 session 两行（include login 之后）。
    _pam=$config/desktop/greetd/pam.d-greetd
    if [ ! -r "$_pam" ]; then
        printf '无法判定 %s：文件不存在或不可读\n' "$_pam" >&2
        return 2
    fi
    if ! grep -Eq '^[[:space:]]*auth[[:space:]]+optional[[:space:]]+pam_gnome_keyring[.]so([[:space:]]|$)' "$_pam"; then
        printf 'greetd PAM 缺少 auth optional pam_gnome_keyring.so（%s）\n' "$_pam" >&2
        _missing=1
    fi
    if ! grep -Eq '^[[:space:]]*session[[:space:]]+optional[[:space:]]+pam_gnome_keyring[.]so[[:space:]]+auto_start([[:space:]]|$)' "$_pam"; then
        printf 'greetd PAM 缺少 session optional pam_gnome_keyring.so auto_start（%s）\n' "$_pam" >&2
        _missing=1
    fi

    # 4) 会话脚本必须在 D-Bus 之后启动守护进程，并在已有控制目录时去重。
    _session=$config/desktop/umbriel/ordo-umbriel-session
    if [ ! -r "$_session" ]; then
        printf '无法判定 %s：文件不存在或不可读\n' "$_session" >&2
        return 2
    fi
    if ! grep -Fq 'gnome-keyring-daemon --start --components=secrets' "$_session"; then
        printf '会话脚本未启动 gnome-keyring-daemon --start --components=secrets（%s）\n' "$_session" >&2
        _missing=1
    elif ! grep -Fq 'GNOME_KEYRING_CONTROL' "$_session"; then
        printf '会话脚本缺少 GNOME_KEYRING_CONTROL 去重判据（%s）\n' "$_session" >&2
        _missing=1
    fi

    # 5) 运行时往返：声明与接线都对，服务仍可能没起/没解锁。
    #    没有 secret-tool 或会话总线时保持静态结论（doctor 会另报无法判定）。
    if command -v secret-tool >/dev/null 2>&1 && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        _probe="ordo-keyring-policy-$$"
        if printf '%s' "$_probe" | secret-tool store --label='Ordo keyring policy probe' \
               service ordo-keyring-policy probe "$$" >/dev/null 2>&1; then
            _got=$(secret-tool lookup service ordo-keyring-policy probe "$$" 2>/dev/null || true)
            secret-tool clear service ordo-keyring-policy probe "$$" >/dev/null 2>&1 || true
            if [ "$_got" != "$_probe" ]; then
                printf 'Secret Service 运行时往返失败：lookup 结果与写入不一致（login keyring 未解锁？）\n' >&2
                _missing=1
            fi
        else
            printf 'Secret Service 运行时往返失败：secret-tool store 失败（服务未启动？）\n' >&2
            _missing=1
        fi
        unset _probe _got
    fi

    [ "$_missing" -eq 0 ] || return 1
    return 0
}

case "${1:-}" in
    check) check ;;
    configure)
        # 声明收敛：旧镜像的 ordo-keyring mask 会继续遮蔽服务，必须删掉；
        # package.use 文件按仓库内容重写（重复执行结果一致）。
        _dst=/etc/portage/package.use/ordo-keyring
        mkdir -p "$(dirname "$_dst")"
        cp "$config/package.use/ordo-keyring" "$_dst"
        rm -f /etc/portage/package.mask/ordo-keyring
        unset _dst
        ;;
    remove)
        # 旧镜像的 remove 调用点仍在 install.sh / 迁移脚本里：不再移除任何包。
        printf '%s\n' '密钥服务策略已反转：GNOME Keyring 现在是受支持组件，remove 不再移除任何包。' >&2
        printf '%s\n' '旧镜像无需清理；重跑安装器可更新 PAM 与会话脚本并收敛声明。' >&2
        ;;
    *)
        printf 'Usage: %s {configure|remove|check}\n' "$0" >&2
        exit 2
        ;;
esac
