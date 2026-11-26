#!/bin/sh
# 回归：C1 密钥服务运行时、C2 门户、以及 syslog / 睡眠策略 / 维护 cron /
#       wezterm 属主的 doctor 判据
#
# 判据全部是行为断言：doctor 在临时根里跑，假 secret-tool / busctl /
# xdg-desktop-portal / rc-service / rc-update 记录调用并控制三态。
# 任何一项被还原（删判据、把失败当通过、把无法判定当通过）都会变红。
set -eu
repo=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)
. "$repo/tests/lib/assert.sh"
scratch=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$scratch"' EXIT

mkdir -p "$scratch/root/scripts" "$scratch/root/config" "$scratch/bin" \
    "$scratch/home/.local/state" "$scratch/etc/ordo" "$scratch/etc/init.d" \
    "$scratch/etc/elogind/logind.conf.d" "$scratch/lib/elogind/system-sleep" \
    "$scratch/etc/xdg-desktop-portal" "$scratch/var/log" "$scratch/cron.d" \
    "$scratch/cron.monthly" "$scratch/db" "$scratch/bin-nost"

printf 'POOL=rpool\nDATASET=rpool/root/ordo\nHOME_DATASET=rpool/home\n' > "$scratch/root/config/dataset"
: > "$scratch/root/config/forbidden-world"
printf 'sys-apps/baseline\n' > "$scratch/world"
printf 'linux,dummy-virt\000' > "$scratch/compatible"
cp "$repo/scripts/lib.sh" "$scratch/root/scripts/lib.sh"
cp "$repo/scripts/ordo-maintenance" "$scratch/root/scripts/ordo-maintenance"

# doctor 里所有会落到宿主 /etc 与 /var 的路径都改到临时根；
# 用户级路径（HOME/.config）由 HOME 控制，不需要 sed。
sed \
    -e "s|/proc/device-tree/compatible|$scratch/compatible|g" \
    -e "s|/var/lib/portage/world|$scratch/world|g" \
    -e "s|/var/db/pkg|$scratch/db|g" \
    -e "s|/etc/init.d/sysklogd|$scratch/etc/init.d/sysklogd|g" \
    -e "s|/var/log/messages|$scratch/var/log/messages|g" \
    -e "s|/etc/ordo/platform|$scratch/etc/ordo/platform|g" \
    -e "s|/etc/elogind/logind.conf.d|$scratch/etc/elogind/logind.conf.d|g" \
    -e "s|/lib/elogind/system-sleep|$scratch/lib/elogind/system-sleep|g" \
    -e "s|/etc/xdg-desktop-portal/portals.conf|$scratch/etc/xdg-desktop-portal/portals.conf|g" \
    "$repo/scripts/doctor" > "$scratch/root/scripts/doctor"

# ---- 假命令 ----
cat > "$scratch/bin/secret-tool" <<'ST'
#!/bin/sh
case "$1" in
    store)  cat > "$SS_FILE" ;;
    lookup)
        case "${SS_MODE:-ok}" in
            mismatch) printf 'wrong-value' ;;
            *) cat "$SS_FILE" 2>/dev/null || : ;;
        esac ;;
    clear)  rm -f "$SS_FILE" ;;
esac
[ "${SS_MODE:-ok}" = fail ] && [ "$1" = store ] && exit 1
exit 0
ST

cat > "$scratch/bin/busctl" <<'BUS'
#!/bin/sh
[ "${BUS_MODE:-ok}" = ok ] || exit 1
printf 'org.freedesktop.portal.Desktop\n'
exit 0
BUS

cat > "$scratch/bin/xdg-desktop-portal" <<'PORTAL'
#!/bin/sh
exit 0
PORTAL

cat > "$scratch/bin/rc-service" <<'RCS'
#!/bin/sh
case "$1" in
    sysklogd) [ "${SYSLOG_STARTED:-1}" = 1 ] && printf ' * status: started\n' || printf ' * status: stopped\n' ;;
    cronie)   printf ' * status: started\n' ;;
    *)        printf ' * status: started\n' ;;
esac
exit 0
RCS

cat > "$scratch/bin/rc-update" <<'RCU'
#!/bin/sh
if [ "$1" = show ]; then
    [ "${CRON_ADDED:-1}" = 1 ] && printf '  cronie\n'
fi
exit 0
RCU

cat > "$scratch/bin/zpool" <<'ZPOOL'
#!/bin/sh
exit 1
ZPOOL

cat > "$scratch/bin/pgrep" <<'PGREP'
#!/bin/sh
exit 0
PGREP

cat > "$scratch/bin/flatpak" <<'FLATPAK'
#!/bin/sh
case "$1" in
    remotes|remote-list) printf 'flathub\thttps://flathub.org/repo/flathub.flatpakrepo\n' ;;
    list) ;;
    run) exit 0 ;;
esac
exit 0
FLATPAK

cat > "$scratch/bin/findmnt" <<'FM'
#!/bin/sh
exit 1
FM

chmod 755 "$scratch/bin"/*
# 去掉 secret-tool 的 PATH（验证「缺工具 = 无法判定」）
for _f in "$scratch/bin"/*; do
    case "${_f##*/}" in
        secret-tool) continue ;;
    esac
    ln -s "$_f" "$scratch/bin-nost/${_f##*/}"
done
unset _f

_doctor() {
    if [ "${NO_BUS:-0}" = 1 ]; then
        unset DBUS_SESSION_BUS_ADDRESS
    else
        DBUS_SESSION_BUS_ADDRESS="unix:path=$scratch/bus"
        export DBUS_SESSION_BUS_ADDRESS
    fi
    PATH="${DOCTOR_PATH:-$scratch/bin:$PATH}" HOME="$scratch/home" \
        XDG_CONFIG_HOME="$scratch/home/.config" \
        ORDO_CRON_DIR="$scratch/cron.d" ORDO_CRON_MONTHLY="$scratch/cron.monthly" \
        SS_FILE="$scratch/ss" SS_MODE="${SS_MODE:-ok}" \
        BUS_MODE="${BUS_MODE:-ok}" SYSLOG_STARTED="${SYSLOG_STARTED:-1}" \
        CRON_ADDED="${CRON_ADDED:-1}" \
        sh "$scratch/root/scripts/doctor" 2>&1 || true
}

_skip_mark=$(printf '\033[36m-\033[0m')
_bad_mark=$(printf '\033[31m✘\033[0m')
_ok_mark=$(printf '\033[32m✔\033[0m')

# 默认环境：portal 命令存在、平台 m2、syslog 运行、用户级 portals.conf。
printf 'm2\n' > "$scratch/etc/ordo/platform"
: > "$scratch/etc/init.d/sysklogd"
: > "$scratch/var/log/messages"
mkdir -p "$scratch/home/.config/xdg-desktop-portal"
cat > "$scratch/home/.config/xdg-desktop-portal/portals.conf" <<'PCONF'
[preferred]
default=gtk
org.freedesktop.impl.portal.FileChooser=umbriel
org.freedesktop.impl.portal.Screenshot=umbriel
org.freedesktop.impl.portal.ScreenCast=umbriel
PCONF

case_name "C1 缺 secret-tool：skip，不是通过"
_out=$(DOCTOR_PATH="$scratch/bin-nost:$PATH" _doctor)
assert_contains "$_out" "$_skip_mark secret-tool 不可用" "缺工具映射为无法判定"
assert_not_contains "$_out" "$_ok_mark Secret Service 往返通过" "缺工具不得打绿勾"

case_name "C1 无会话总线：skip，不是通过"
_out=$(NO_BUS=1 _doctor)
assert_contains "$_out" "$_skip_mark 无会话总线，无法验收密钥服务" "无总线映射为无法判定"
assert_not_contains "$_out" "$_bad_mark Secret Service" "无总线不等于服务故障"

case_name "C1 store 失败：报问题"
_out=$(SS_MODE=fail _doctor)
assert_contains "$_out" "$_bad_mark Secret Service 不可用" "store 失败映射为问题"
assert_not_contains "$_out" "$_ok_mark Secret Service 往返通过" "失败不得打绿勾"

case_name "C1 lookup 不一致：报问题"
_out=$(SS_MODE=mismatch _doctor)
assert_contains "$_out" "$_bad_mark Secret Service 往返失败（lookup 结果与写入不一致" \
    "往返不一致必须报出"
assert_not_contains "$_out" "$_ok_mark Secret Service 往返通过" "不一致不得打绿勾"

case_name "C1 往返成功：通过"
_out=$(_doctor)
assert_contains "$_out" "$_ok_mark Secret Service 往返通过" "store + lookup 成功映射为通过"
assert_not_contains "$_out" "$_bad_mark Secret Service" "成功不得报问题"

case_name "C1 keyring-policy check 同步运行时往返"
_rc=0
DBUS_SESSION_BUS_ADDRESS="unix:path=$scratch/bus" SS_FILE="$scratch/ss" SS_MODE=ok \
    PATH="$scratch/bin:$PATH" sh "$repo/config/desktop/keyring-policy.sh" check || _rc=$?
assert_rc "$_rc" 0 "往返成功时 check 退 0"
_rc=0
DBUS_SESSION_BUS_ADDRESS="unix:path=$scratch/bus" SS_FILE="$scratch/ss" SS_MODE=fail \
    PATH="$scratch/bin:$PATH" sh "$repo/config/desktop/keyring-policy.sh" check 2>/dev/null || _rc=$?
assert_rc "$_rc" 1 "store 失败时 check 退 1"
_rc=0
DBUS_SESSION_BUS_ADDRESS="unix:path=$scratch/bus" SS_FILE="$scratch/ss" SS_MODE=mismatch \
    PATH="$scratch/bin:$PATH" sh "$repo/config/desktop/keyring-policy.sh" check 2>/dev/null || _rc=$?
assert_rc "$_rc" 1 "lookup 不一致时 check 退 1"

case_name "C2 portals.conf 三项指向 umbriel：通过"
_out=$(_doctor)
assert_contains "$_out" "$_ok_mark 门户后端指向 umbriel" "三项齐全时打绿勾"
assert_contains "$_out" "$_ok_mark xdg-desktop-portal 在会话总线上可内省" "busctl 通过"

case_name "C2 portals.conf 缺 Screenshot：报问题"
sed -i.bak '/Screenshot/d' "$scratch/home/.config/xdg-desktop-portal/portals.conf"
_out=$(_doctor)
assert_contains "$_out" "未把 Screenshot 指向 umbriel" "缺项必须点名"
assert_not_contains "$_out" "$_ok_mark 门户后端指向 umbriel" "缺项不得打绿勾"
mv "$scratch/home/.config/xdg-desktop-portal/portals.conf.bak" \
    "$scratch/home/.config/xdg-desktop-portal/portals.conf"

case_name "C2 portals.conf 缺失：报问题（默认会落到 gtk）"
mv "$scratch/home/.config/xdg-desktop-portal/portals.conf" "$scratch/portals.keep"
_out=$(_doctor)
assert_contains "$_out" "缺少 portals.conf" "缺文件必须报问题"
mv "$scratch/portals.keep" "$scratch/home/.config/xdg-desktop-portal/portals.conf"

case_name "C2 busctl 失败：报问题"
_out=$(BUS_MODE=fail _doctor)
assert_contains "$_out" "$_bad_mark xdg-desktop-portal 不在会话总线上" "内省失败映射为问题"
assert_not_contains "$_out" "$_ok_mark xdg-desktop-portal 在会话总线上可内省" "失败不得打绿勾"

case_name "syslog 在跑：通过"
_out=$(_doctor)
assert_contains "$_out" "$_ok_mark syslog 运行中" "sysklogd started 映射为通过"

case_name "syslog 停了：报问题"
_out=$(SYSLOG_STARTED=0 _doctor)
assert_contains "$_out" "$_bad_mark sysklogd 未运行" "未运行映射为问题"

case_name "syslog 未安装：Ordo 安装上必须报问题"
rm -f "$scratch/etc/init.d/sysklogd"
# 宿主自带 /usr/sbin/syslogd：用不含 /usr/sbin 的 PATH 才测得到「未安装」。
_out=$(DOCTOR_PATH="$scratch/bin:/usr/bin:/bin" _doctor)
assert_contains "$_out" "$_bad_mark syslog 未安装" "Ordo 平台缺 syslog 是问题"
: > "$scratch/etc/init.d/sysklogd"

case_name "外接盘睡眠策略：完整通过、缺项报问题"
cat > "$scratch/etc/elogind/logind.conf.d/10-ordo-external-root.conf" <<'SLEEP'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
SLEEP
cat > "$scratch/lib/elogind/system-sleep/50-ordo-root-pool.sh" <<'HOOK'
#!/bin/sh
exit 0
HOOK
chmod 755 "$scratch/lib/elogind/system-sleep/50-ordo-root-pool.sh"
_out=$(_doctor)
assert_contains "$_out" "$_ok_mark 外接盘睡眠策略完整" "四项 ignore + 钩子齐全时通过"
sed -i.bak '/HandleSuspendKey/d' "$scratch/etc/elogind/logind.conf.d/10-ordo-external-root.conf"
_out=$(_doctor)
assert_contains "$_out" "外接盘睡眠策略不完整" "缺项必须报出"
assert_contains "$_out" "HandleSuspendKey" "点名缺的键"
assert_not_contains "$_out" "$_ok_mark 外接盘睡眠策略完整" "缺项不得打绿勾"
mv "$scratch/etc/elogind/logind.conf.d/10-ordo-external-root.conf.bak" \
    "$scratch/etc/elogind/logind.conf.d/10-ordo-external-root.conf"

case_name "维护 cron：完整通过、缺件报问题"
printf '# x\n17 * * * * root /usr/local/bin/ordo-snap-auto >/dev/null 2>&1\n' > "$scratch/cron.d/ordo-snapshot"
printf '#!/bin/sh\nzpool scrub "$POOL"\n' > "$scratch/cron.monthly/zfs-scrub"
chmod 755 "$scratch/cron.monthly/zfs-scrub"
_out=$(_doctor)
assert_contains "$_out" "$_ok_mark 维护任务完整" "两个 cron 文件齐全时通过"
rm -f "$scratch/cron.monthly/zfs-scrub"
_out=$(_doctor)
assert_contains "$_out" "$_bad_mark 维护任务缺件" "缺 scrub 必须报问题"
assert_not_contains "$_out" "$_ok_mark 维护任务完整" "缺件不得打绿勾"
printf '#!/bin/sh\nzpool scrub "$POOL"\n' > "$scratch/cron.monthly/zfs-scrub"
chmod 755 "$scratch/cron.monthly/zfs-scrub"

case_name "wezterm：旧镜像软链报问题，真实可写文件通过"
mkdir -p "$scratch/home/.config/wezterm"
printf '# template\n' > "$scratch/wezterm-src.lua"
ln -sfn "$scratch/wezterm-src.lua" "$scratch/home/.config/wezterm/wezterm.lua"
_out=$(_doctor)
assert_contains "$_out" "$_bad_mark wezterm.lua 仍是软链" "软链必须报问题"
rm -f "$scratch/home/.config/wezterm/wezterm.lua"
printf '# template\n' > "$scratch/home/.config/wezterm/wezterm.lua"
chmod 644 "$scratch/home/.config/wezterm/wezterm.lua"
_out=$(_doctor)
assert_contains "$_out" "$_ok_mark wezterm.lua 是用户可写的真实副本" "真实副本通过"
chmod 444 "$scratch/home/.config/wezterm/wezterm.lua"
_out=$(_doctor)
assert_contains "$_out" "$_bad_mark wezterm.lua 不可写" "只读副本必须报问题"
assert_not_contains "$_out" "$_ok_mark wezterm.lua 是用户可写" "不可写不得打绿勾"
chmod 644 "$scratch/home/.config/wezterm/wezterm.lua"

finish
