#!/bin/sh
# 旧镜像补丁：把第四轮的运行时接线部署到已装系统（幂等）。
#
# 覆盖四件事：
#   1. Secret Service 的 PAM/会话接线（旧镜像没有密钥服务，Wi-Fi 密码存不住）；
#   2. 门户后端与输入法环境（portals.conf / 99imm）；
#   3. 睡眠策略与唤醒钩子（外接根池禁用合盖睡眠）；
#   4. 掉盘播报 zedlet、扬声器保护配置与 /run/ordo 权限。
#
# 只从 /opt/ordo 的当前声明部署，不联网、不重装；缺文件就跳过并计数。
set -eu

repo=/opt/ordo
[ -d "$repo" ] || { printf '缺少 %s，跳过运行时接线迁移\n' "$repo" >&2; exit 0; }

deployed=0
missing=0

put() { # <源> <目标> <模式>
    [ -f "$1" ] || { printf '缺少声明文件，跳过：%s\n' "$1" >&2; missing=$((missing + 1)); return 0; }
    install -Dm"$3" "$1" "$2" && deployed=$((deployed + 1))
}

# 1) Secret Service
sh "$repo/config/desktop/keyring-policy.sh" configure || printf '密钥服务声明收敛失败（继续）\n' >&2
put "$repo/config/desktop/greetd/pam.d-greetd" /etc/pam.d/greetd 644
put "$repo/config/desktop/umbriel/ordo-umbriel-session" /usr/local/bin/ordo-umbriel-session 755
put "$repo/config/desktop/ordo-session-env" /usr/local/bin/ordo-session-env 755

# 2) 门户与输入法环境
put "$repo/config/desktop/portals.conf" /etc/xdg-desktop-portal/portals.conf 644
put "$repo/config/desktop/99imm" /etc/env.d/99imm 644
command -v env-update >/dev/null 2>&1 && env-update >/dev/null 2>&1 || :

# 3) 睡眠策略（只在根池不是 NVMe 时落）
_root_dev=$(findmnt -no SOURCE / 2>/dev/null || :)
case "$_root_dev" in
    /dev/nvme*) printf '根在内置 NVMe，保留 elogind 默认电源策略\n' ;;
    *)
        put "$repo/config/desktop/elogind/logind.conf.d/10-ordo-external-root.conf" \
            /etc/elogind/logind.conf.d/10-ordo-external-root.conf 644
        put "$repo/config/desktop/elogind/system-sleep/50-ordo-root-pool.sh" \
            /lib/elogind/system-sleep/50-ordo-root-pool.sh 755
        ;;
esac

# 4) 掉盘播报 / 扬声器保护 / 运行时目录
put "$repo/config/platform/m2/zed.d/statechange-ordo.sh" /etc/zfs/zed.d/statechange-ordo.sh 755
put "$repo/config/platform/m2/speakersafetyd.conf" /etc/conf.d/speakersafetyd 644
if [ -f "$repo/config/platform/m2/install-hardware.sh" ] && command -v rc-update >/dev/null 2>&1; then
    rc-update add speakersafetyd default >/dev/null 2>&1 || :
fi

printf '运行时接线迁移完成：部署 %s 项，缺声明 %s 项\n' "$deployed" "$missing"
