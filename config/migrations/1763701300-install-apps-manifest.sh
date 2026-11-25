#!/bin/sh
# 首启应用清单（评审 P1-12）
#
# 旧版本没有任何 Flatpak 应用清单，装完机器上没有浏览器。
# 本迁移把 config/apps.d/00-core.list 里的应用装上（已装的跳过）。
set -eu

command -v flatpak >/dev/null 2>&1 || exit 0

# 找清单：优先已安装副本，其次仓库
for _d in /etc/ordo/apps.d /opt/ordo/config/apps.d; do
    [ -d "$_d" ] && { APPS_DIR="$_d"; break; }
done
[ -n "${APPS_DIR:-}" ] || exit 0

for _list in "$APPS_DIR"/*.list; do
    [ -f "$_list" ] || continue
    case "$_list" in *optional*) continue ;; esac
    while IFS= read -r _app; do
        case "$_app" in ''|\#*) continue ;; esac
        flatpak install --user --noninteractive -y flathub "$_app" >/dev/null 2>&1 \
            && echo "  已安装 $_app" \
            || echo "  跳过 $_app（已装或网络不可用）" >&2
    done < "$_list"
done
