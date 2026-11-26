#!/bin/sh
# 首启应用清单消费器（P1-04）。
#
# M2 路径过去只有 world 没有 app 步骤：装完机器上没有浏览器、没有可视化商店。
# 本脚本由 /etc/local.d 在首启跑一次，以桌面用户身份装 config/apps.d 里声明的应用。
# 幂等：已装应用跳过；成功后才写 /var/lib/ordo/first-apps.done，失败下次启动重试。
set -eu

marker=${ORDO_FIRST_APPS_MARKER:-/var/lib/ordo/first-apps.done}
apps=${ORDO_APPS_DIR:-/opt/ordo/config/apps.d}
flathub=${ORDO_FLATHUB:-https://flathub.org/repo/flathub.flatpakrepo}

[ -e "$marker" ] && exit 0
[ -d "$apps" ] || exit 0
command -v flatpak >/dev/null 2>&1 || exit 0

warn() { printf '!! %s\n' "$*" >&2; }

# 以桌面用户身份执行：用户级 remote 与 --user 安装必须落在 /home/ordo。
as_ordo() {
    if [ "$(id -u)" = 0 ]; then
        su - ordo -c "$1"
    else
        sh -c "$1"
    fi
}

# 消费端统一先洗行内注释再取第一列：# 后面的说明文字不是 app id。
app_ids() {
    sed 's/#.*//' "$1" | awk 'NF { print $1 }'
}

as_ordo "flatpak remote-add --user --if-not-exists flathub '$flathub'" >/dev/null 2>&1 || {
    warn "无法为用户级 flathub remote 落库（网络不可用？），首启应用将在下次启动重试"
    exit 1
}

installed=$(as_ordo 'flatpak list --user --app --columns=application' 2>/dev/null) || installed=

failed=0
for list in "$apps"/*.list; do
    [ -f "$list" ] || continue
    case "$list" in *optional*) continue ;; esac
    app_ids "$list" | while IFS= read -r app; do
        case "$app" in
            *.*.*) ;;
            *) warn "跳过非法 app id：$app"; continue ;;
        esac
        if printf '%s\n' "$installed" | grep -Fxq "$app"; then
            continue
        fi
        if as_ordo "flatpak install --user --noninteractive -y flathub '$app'" >/dev/null 2>&1; then
            printf '已安装 %s\n' "$app"
        else
            warn "未能安装 $app"
            exit 1
        fi
    done || failed=1
done

[ "$failed" = 0 ] || exit 1
mkdir -p "${marker%/*}"
: > "$marker"
