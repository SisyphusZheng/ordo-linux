#!/bin/sh
set -eu
src=/opt/ordo/config/desktop
getent passwd ordo >/dev/null
python3 /opt/ordo/config/platform/m2/repair-package-defaults.py
sh "$src/m2-desktop-fix.sh"
sh /opt/ordo/config/platform/m2/install-hardware.sh
for program in /usr/bin/umbriel /usr/bin/start-umbriel /usr/bin/noctalia /usr/bin/greetd /usr/bin/noctalia-greeter-session /etc/init.d/greetd; do
    [ -x "$program" ] || { echo "Missing $program" >&2; exit 1; }
done
install -m 755 "$src/umbriel/ordo-umbriel-session" /usr/local/bin/
install -m 755 "$src/ordo-session-env" /usr/local/bin/
install -Dm644 "$src/wallpapers/wallpaper-blackhole.png" /usr/share/backgrounds/ordo/wallpaper-blackhole.png
HOME=/home/ordo XDG_CONFIG_HOME=/home/ordo/.config ORDO_CONF_DIR=/opt/ordo/config /opt/ordo/scripts/ordo-config apply desktop
chown -hR ordo:ordo /home/ordo/.config
test -r /home/ordo/.config/umbriel/config.toml
test -r /home/ordo/.config/noctalia/config.toml
install -d -m 755 /var/lib/ordo /home/.ordo
# 首启 marker 在 /home（独立数据集），系统 BE 回滚不会把它带回「未首启」。
# 旧版放在 /var/lib/ordo（根数据集）：升级时搬过去，否则回滚后还会自动登录一次。
if [ -e /var/lib/ordo/greetd-first-session ]; then
    if [ -e /home/.ordo/greetd-first-session ]; then
        rm -f /var/lib/ordo/greetd-first-session
    else
        mv /var/lib/ordo/greetd-first-session /home/.ordo/greetd-first-session
    fi
fi
cat "$src/greetd/config.toml" "$src/greetd/first-boot.toml" > /etc/greetd/config.toml.new
mv /etc/greetd/config.toml.new /etc/greetd/config.toml
# 重装幂等：marker 已存在说明首启已完成，保留即可，不能 die（旧版 test ! -e 会中断安装）。
if [ -d /etc/ordo ] && [ "$(readlink -f /etc/ordo)" != /opt/ordo/config ]; then
    ln -sfn /opt/ordo/config/check-build /etc/ordo/check-build
    ln -sfn /opt/ordo/config/world.sh /etc/ordo/world.sh
fi
rc-update add greetd default
test -L /etc/runlevels/default/greetd

# 【P2-08】用户级 dbus / pipewire 服务要以 user.<用户> 实例进 runlevel 才会被拉起；
# M2 路径过去只装 /etc/user/runlevels/default/* 软链，从不建实例（install.sh 已有）。
if [ -f /etc/init.d/user ]; then
    ln -sfn /etc/init.d/user /etc/init.d/user.ordo
    rc-update add user.ordo default || { echo "user.ordo 注册失败" >&2; exit 1; }
else
    echo "缺少 /etc/init.d/user（openrc 用户服务模板）" >&2
    exit 1
fi

# 首启应用清单（P1-04）：M2 路径过去不读 config/apps.d，装完没有浏览器与商店。
# 安装器不假设联网，只登记 local.d 一次性任务；首启由 ordo 用户装清单里的应用。
install -m 755 /opt/ordo/config/platform/m2/first-apps.sh /usr/local/sbin/ordo-first-apps
# oneshot 只有在 local 进了默认 runlevel 才会跑
if [ -x /etc/init.d/local ]; then
    rc-update add local default
fi
install -d -m 755 /etc/local.d
# 兜底触发点：local 在 boot 阶段跑，那时可能还没有默认路由。
# 先用 nm-online -q 等到 NetworkManager 认为在线（最多 180s），等不到就
# 退出，交给下面的 dispatcher 在链路 up 时再来一次 —— 两条路径都幂等。
cat > /etc/local.d/70-ordo-first-apps.start <<'FIRSTAPPS'
#!/bin/sh
# 首启应用的兜底入口（主入口是 NM dispatcher 90-ordo-first-apps）
command -v nm-online >/dev/null 2>&1 || exit 0
nm-online -q -t 180 >/dev/null 2>&1 || exit 0
exec /usr/local/sbin/ordo-first-apps
FIRSTAPPS
chmod 755 /etc/local.d/70-ordo-first-apps.start

# 主触发点（D1-1）：NetworkManager 在接口 up 时执行。
# 旧版只有 local.d：/local 在 net 之前跑，flatpak install 没有网络必然失败，
# 首启应用链因此从未成功过。dispatcher 参数：$1 接口，$2 动作。
# 【判据】NetworkManager 没装时不创建它的目录：空目录会让「有 dispatcher」
# 看起来成立，实际没有任何进程会读它。判据用包自己的文件，不用命令名。
if [ -f /etc/NetworkManager/NetworkManager.conf ] || [ -x /usr/sbin/NetworkManager ] \
   || [ -d /etc/NetworkManager/dispatcher.d ]; then
install -d -m 755 /etc/NetworkManager/dispatcher.d
cat > /etc/NetworkManager/dispatcher.d/90-ordo-first-apps <<'DISPATCH'
#!/bin/sh
# 首启应用的主触发点：只在接口 up（非 VPN）时执行，失败只播报一次。
[ "${2:-}" = up ] || exit 0
[ -z "${VPN_IP_IFACE:-}" ] || exit 0
[ -e /var/lib/ordo/first-apps.done ] && exit 0
[ -x /usr/local/sbin/ordo-first-apps ] || exit 0

if /usr/local/sbin/ordo-first-apps; then
    exit 0
fi

# 失败只报一次：NM 每次链路 up 都会重跑，重复弹窗等于噪音。
_flag=/run/ordo/first-apps-notified
[ -e "$_flag" ] && exit 0
mkdir -p "${_flag%/*}" 2>/dev/null || true
: > "$_flag" 2>/dev/null || true
_uid=$(id -u ordo 2>/dev/null || true)
if [ -n "$_uid" ] && [ -S "/run/user/$_uid/bus" ] && command -v notify-send >/dev/null 2>&1; then
    su -s /bin/sh - ordo -c "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$_uid/bus notify-send -u critical -a ordo '首启应用未装完' '检查网络后重跑：doas /usr/local/sbin/ordo-first-apps'" >/dev/null 2>&1 || true
fi
exit 0
DISPATCH
chmod 755 /etc/NetworkManager/dispatcher.d/90-ordo-first-apps
else
    echo "缺少 NetworkManager：首启应用只剩 /etc/local.d 的 nm-online 兜底" >&2
fi

# 维护定时任务（D1-6）：M2 路径过去只 rc-update add cronie，从不写
# /etc/cron.d/ordo-snapshot，也不写每月 scrub。装配入口与 install.sh /
# VM 装配器共用 scripts/ordo-maintenance，文本只定义一次。
# 失败只告警不中断：桌面本身可用，缺失项可事后 `ordo snap auto on` 补；
# 但必须喊出来，否则又回到「装了 cron 服务、没有任何任务」的静默状态。
if [ -x /opt/ordo/scripts/ordo-maintenance ]; then
    sh /opt/ordo/scripts/ordo-maintenance enable \
        || echo "维护定时任务装配失败（快照与 scrub 不会运行；可运行 ordo snap auto on 重试）" >&2
else
    echo "缺少 /opt/ordo/scripts/ordo-maintenance（安装包不完整；快照与 scrub 不会运行）" >&2
fi
