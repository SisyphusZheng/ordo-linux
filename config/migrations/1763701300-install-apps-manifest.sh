#!/bin/sh
# 首启应用清单（评审 P1-12）
#
# 旧版本没有任何 Flatpak 应用清单，装完机器上没有浏览器。
# 本迁移把 config/apps.d/00-core.list 里的应用装上（已装的跳过）。
#
# 【P1-04 修复】两处与 install.sh 同源的缺陷：
#   1) 只跳 `#` 开头的行 → `org.mozilla.firefox   # 浏览器` 整行被当 app id；
#      解析统一走 flatpak_apps_of（剥行内注释后取第一列）。
#   2) root 跑 `flatpak install --user` 会把应用装进 /root/.local/share/flatpak，
#      首启登录的 ordo 看不到 → 以桌面用户身份执行，remote 同样 --user。
set -eu

command -v flatpak >/dev/null 2>&1 || exit 0

# 找清单：优先已安装副本，其次仓库
for _d in /etc/ordo/apps.d /opt/ordo/config/apps.d; do
    [ -d "$_d" ] && { APPS_DIR="$_d"; break; }
done
[ -n "${APPS_DIR:-}" ] || exit 0

DESKTOP_USER="${ORDO_DESKTOP_USER:-ordo}"
id -u "$DESKTOP_USER" >/dev/null 2>&1 || exit 0

# apps.d 的格式允许行尾理由：剥掉 `#` 之后的部分再取第一列。
flatpak_apps_of() {
    sed -e 's/#.*//' "$1" | awk 'NF { print $1 }'
}
as_desktop_user() { su -s /bin/sh - "$DESKTOP_USER" -c "$1"; }

# remote 必须与安装同一作用域（--user），否则 install 找不到 flathub
as_desktop_user 'flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo' \
    || echo "  跳过 flathub remote（已存在或网络不可用）" >&2

for _list in "$APPS_DIR"/*.list; do
    [ -f "$_list" ] || continue
    case "$_list" in *optional*) continue ;; esac
    flatpak_apps_of "$_list" | while IFS= read -r _app; do
        if as_desktop_user "flatpak install --user --noninteractive -y flathub '$_app'" >/dev/null 2>&1; then
            echo "  已安装 $_app"
        else
            echo "  跳过 $_app（已装或网络不可用）" >&2
        fi
    done
done
