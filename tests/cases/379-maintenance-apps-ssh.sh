#!/bin/sh
# 回归：A3 维护定时任务共享入口；A4 首启应用触发与 remote 幂等；A8 SSH 入口
#
# 缺陷证据（D1-6 / D1-1 / D1-2）：
#   - install.sh 自己写 cron 文件，M2 外置安装只 rc-update add cronie 从不写文件，
#     VM 装配器另写一套：装完看起来有 cron，实际没有快照任务。
#   - 首启应用只挂 /etc/local.d，那时可能还没有网，flatpak 必然失败；
#     `ordo app install` 不确保用户级 flathub remote，旧镜像直接报错。
#   - 装机后没有开 SSH 的入口，只能自己查 rc-update 与 sshd_config。
#
# 判据都是行为断言：假的 rc-update / rc-service / flatpak / sshd 记录调用，
# 真脚本在临时目录里跑完整路径。
set -eu
cd "$(dirname "$(readlink -f "$0")")/../.."
. "tests/lib/assert.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ordo-maint.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"
mkdir -p "$bin" "$tmp/cron.d" "$tmp/cron.monthly"

cat > "$bin/id" <<'ID'
#!/bin/sh
printf '0\n'
ID
cat > "$bin/rc-update" <<'RCU'
#!/bin/sh
printf '%s\n' "$*" >> "$RC_LOG"
case "$1" in
    show) [ -f "$RC_STATE" ] && printf '  cronie\n  sshd\n' ;;
    add)  printf '%s\n' "$2" > "$RC_STATE" ;;
    del)  rm -f "$RC_STATE" ;;
esac
exit 0
RCU
cat > "$bin/rc-service" <<'RCS'
#!/bin/sh
printf '%s\n' "$*" >> "$RCS_LOG"
printf ' * status: started\n'
exit "${RCS_RC:-0}"
RCS
cat > "$bin/findmnt" <<'FM'
#!/bin/sh
exit 1
FM
chmod 755 "$bin/id" "$bin/rc-update" "$bin/rc-service" "$bin/findmnt"

run_maint() {
    PATH="$bin:$PATH" RC_LOG="$tmp/rc.log" RCS_LOG="$tmp/rcs.log" \
    RC_STATE="$tmp/rc.state" \
    ORDO_CRON_DIR="$tmp/cron.d" ORDO_CRON_MONTHLY="$tmp/cron.monthly" \
    LC_ALL= LANG=zh_CN.UTF-8 \
    "$@"
}

case_name "A3 三个安装路径共用 ordo-maintenance enable"

assert_rc "$([ -x scripts/ordo-maintenance ] && echo 0 || echo 1)" 0 "scripts/ordo-maintenance 可执行"
for f in install.sh config/platform/m2/first-desktop.sh dev/vm/configure-root.sh; do
    assert_contains "$(cat "$f")" "ordo-maintenance" "$f 调用维护入口"
done
assert_contains "$(cat install.sh)" "ordo-maintenance enable" "install.sh 调 install 入口"
assert_contains "$(cat config/platform/m2/first-desktop.sh)" "ordo-maintenance enable" \
    "M2 首启配置调 install 入口"
assert_contains "$(cat dev/vm/configure-root.sh)" "ordo-maintenance" "VM 装配器调维护入口"
assert_contains "$(cat scripts/ordo-snap)" "ordo-maintenance" "ordo snap auto on 转发到同一入口"

case_name "A3 enable 写出两个 cron 文件（M2 过去一个都没有）"

: > "$tmp/rc.log"
rc=0
run_maint sh scripts/ordo-maintenance enable > "$tmp/e1" 2> "$tmp/ee1" || rc=$?
assert_rc "$rc" 0 "enable 退出 0"
assert_rc "$([ -f "$tmp/cron.d/ordo-snapshot" ] && echo 0 || echo 1)" 0 "快照 cron 已写"
assert_rc "$([ -x "$tmp/cron.monthly/zfs-scrub" ] && echo 0 || echo 1)" 0 "scrub 可执行（run-parts 要求）"
assert_active_line "$tmp/cron.d/ordo-snapshot" "17 * * * * root /usr/local/bin/ordo-snap-auto" \
    "快照任务指向 ordo-snap-auto"
assert_active_line "$tmp/cron.monthly/zfs-scrub" 'zpool scrub' "scrub 调用 zpool scrub"
assert_active_line "$tmp/cron.monthly/zfs-scrub" 'POOL="${ORDO_POOL:-rpool}"' \
    "scrub 的池名来自声明（可在运行期覆盖）"
assert_eq "$(awk '$1 == "add" && $2 == "cronie" {n++} END {print n+0}' "$tmp/rc.log")" "1" \
    "cronie 被注册进 default runlevel"

case_name "A3 enable 幂等（重复执行不改内容、不重复注册）"

_c1="$(cksum < "$tmp/cron.d/ordo-snapshot")"
_c2="$(cksum < "$tmp/cron.monthly/zfs-scrub")"
rc=0
run_maint sh scripts/ordo-maintenance enable > "$tmp/e2" 2> "$tmp/ee2" || rc=$?
assert_rc "$rc" 0 "第二次 enable 退出 0"
assert_eq "$(cksum < "$tmp/cron.d/ordo-snapshot")" "$_c1" "快照 cron 内容不变"
assert_eq "$(cksum < "$tmp/cron.monthly/zfs-scrub")" "$_c2" "scrub 内容不变"
assert_eq "$(awk '$1 == "add" && $2 == "cronie" {n++} END {print n+0}' "$tmp/rc.log")" "1" \
    "第二次不再重复 add cronie"

case_name "A3 status 三态：齐备 0、缺件 1"

rc=0
run_maint sh scripts/ordo-maintenance status > "$tmp/s1" 2>&1 || rc=$?
assert_rc "$rc" 0 "齐备时 status 退出 0"
rm -f "$tmp/cron.monthly/zfs-scrub"
rc=0
run_maint sh scripts/ordo-maintenance status > "$tmp/s2" 2>&1 || rc=$?
assert_rc "$rc" 1 "缺 scrub 时 status 退出 1"
assert_contains "$(cat "$tmp/s2")" "缺少 scrub" "点名缺的是 scrub"

case_name "A3 ordo snap auto on 与安装器写同一份文本"

rm -f "$tmp/cron.d/ordo-snapshot" "$tmp/cron.monthly/zfs-scrub"
rc=0
run_maint sh scripts/ordo-snap auto on > "$tmp/a1" 2> "$tmp/ae1" || rc=$?
assert_rc "$rc" 0 "auto on 退出 0"
assert_rc "$([ -f "$tmp/cron.d/ordo-snapshot" ] && echo 0 || echo 1)" 0 "auto on 写出快照 cron"
assert_rc "$([ -x "$tmp/cron.monthly/zfs-scrub" ] && echo 0 || echo 1)" 0 "auto on 同时写出 scrub"
assert_eq "$(cksum < "$tmp/cron.d/ordo-snapshot")" "$_c1" "与 enable 写出的文本一致"

case_name "A4 ordo app install 先幂等补齐用户级 flathub remote"

cat > "$bin/flatpak" <<'FP'
#!/bin/sh
printf '%s\n' "$*" >> "$FP_LOG"
case "$1" in
    remote-add) exit "${REMOTE_RC:-0}" ;;
    list) exit 0 ;;
    install) exit 0 ;;
esac
exit 0
FP
chmod 755 "$bin/flatpak"
: > "$tmp/fp.log"
rc=0
PATH="$bin:$PATH" FP_LOG="$tmp/fp.log" LC_ALL= LANG=zh_CN.UTF-8 \
    sh scripts/ordo app install org.example.App > "$tmp/f1" 2> "$tmp/fe1" || rc=$?
assert_rc "$rc" 0 "app install 退出 0"
assert_eq "$(sed -n '1p' "$tmp/fp.log")" \
    "remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo" \
    "install 前先加 --user remote（幂等）"
assert_eq "$(sed -n '2p' "$tmp/fp.log")" \
    "install --user --noninteractive flathub org.example.App" "再安装应用"

: > "$tmp/fp.log"
rc=0
PATH="$bin:$PATH" FP_LOG="$tmp/fp.log" REMOTE_RC=1 LC_ALL= LANG=zh_CN.UTF-8 \
    sh scripts/ordo app install org.example.App > "$tmp/f2" 2> "$tmp/fe2" || rc=$?
assert_rc "$rc" 1 "remote 加不上时退出 1（不吞）"
assert_contains "$(cat "$tmp/fe2")" "flathub remote" "点名 flathub remote"
assert_eq "$(awk '$1 == "install" {n++} END {print n+0}' "$tmp/fp.log")" "0" \
    "remote 失败后不再盲目安装"

case_name "A4 app list 为空时给出下一步"

rc=0
PATH="$bin:$PATH" LC_ALL= LANG=zh_CN.UTF-8 \
    sh scripts/ordo app list > "$tmp/f3" 2> "$tmp/fe3" || rc=$?
assert_rc "$rc" 0 "空列表退出 0"
assert_contains "$(cat "$tmp/fe3")" "app install" "提示下一步命令"

case_name "A4 首启触发：NM dispatcher 主触发 + nm-online 兜底"

_first="$(cat config/platform/m2/first-desktop.sh)"
assert_contains "$_first" "/etc/NetworkManager/dispatcher.d/90-ordo-first-apps" "装 NM dispatcher"

# 兜底脚本的正文单独抽出来断言「生效行」，不看注释里的字样。
awk "/cat > \/etc\/local.d\/70-ordo-first-apps.start <<'FIRSTAPPS'/{f=1;next}
     f && /^FIRSTAPPS\$/{f=0;next} f" config/platform/m2/first-desktop.sh > "$tmp/locald.raw"
assert_rc "$([ -s "$tmp/locald.raw" ] && echo 0 || echo 1)" 0 "能抽出 local.d 兜底正文"
assert_active_line "$tmp/locald.raw" 'nm-online -q' "兜底先等网络（nm-online）"
assert_active_line "$tmp/locald.raw" 'exec /usr/local/sbin/ordo-first-apps' "兜底执行同一入口"

# 抽出 dispatcher 的正文，换掉绝对路径后在临时目录里真跑。
awk "/cat > \/etc\/NetworkManager\/dispatcher.d\/90-ordo-first-apps <<'DISPATCH'/{f=1;next}
     f && /^DISPATCH\$/{f=0;next} f" config/platform/m2/first-desktop.sh > "$tmp/dispatcher.raw"
assert_rc "$([ -s "$tmp/dispatcher.raw" ] && echo 0 || echo 1)" 0 "能抽出 dispatcher 正文"
sed -e "s|/var/lib/ordo/first-apps.done|$tmp/state/first-apps.done|g" \
    -e "s|/usr/local/sbin/ordo-first-apps|$tmp/ordo-first-apps|g" \
    -e "s|/run/ordo/first-apps-notified|$tmp/run/first-apps-notified|g" \
    "$tmp/dispatcher.raw" > "$tmp/dispatcher"
cat > "$tmp/ordo-first-apps" <<'FA'
#!/bin/sh
printf 'called\n' >> "$FA_LOG"
exit "${FA_RC:-0}"
FA
chmod 755 "$tmp/ordo-first-apps"
mkdir -p "$tmp/state"

: > "$tmp/fa.log"
rc=0
PATH="$bin:$PATH" FA_LOG="$tmp/fa.log" sh "$tmp/dispatcher" eth0 down || rc=$?
assert_rc "$rc" 0 "down 事件退出 0"
assert_rc "$([ -s "$tmp/fa.log" ] && echo 1 || echo 0)" 0 "down 事件不触发安装"

: > "$tmp/fa.log"
rc=0
PATH="$bin:$PATH" FA_LOG="$tmp/fa.log" sh "$tmp/dispatcher" eth0 up || rc=$?
assert_rc "$rc" 0 "up 事件退出 0"
assert_eq "$(wc -l < "$tmp/fa.log" | tr -d ' ')" "1" "up 事件触发一次安装"

: > "$tmp/fa.log"
rc=0
PATH="$bin:$PATH" FA_LOG="$tmp/fa.log" VPN_IP_IFACE=ppp0 sh "$tmp/dispatcher" eth0 up || rc=$?
assert_rc "$([ -s "$tmp/fa.log" ] && echo 1 || echo 0)" 0 "VPN 接口 up 不触发"

: > "$tmp/fa.log"
: > "$tmp/state/first-apps.done"
PATH="$bin:$PATH" FA_LOG="$tmp/fa.log" sh "$tmp/dispatcher" eth0 up || true
assert_rc "$([ -s "$tmp/fa.log" ] && echo 1 || echo 0)" 0 "已完成时不再触发"
rm -f "$tmp/state/first-apps.done"

# 失败不阻断 NM（退出 0），并留下一次性播报标记。
rc=0
PATH="$bin:$PATH" FA_LOG="$tmp/fa.log" FA_RC=1 sh "$tmp/dispatcher" eth0 up || rc=$?
assert_rc "$rc" 0 "安装失败不阻断 NetworkManager"
assert_rc "$([ -f "$tmp/run/first-apps-notified" ] && echo 0 || echo 1)" 0 "留下一次性播报标记"

case_name "A8 ordo ssh on：最小策略 + 幂等"

mkdir -p "$tmp/ssh/sshd_config.d"
printf '#Port 22\n' > "$tmp/ssh/sshd_config"
cat > "$bin/sshd" <<'SSHD'
#!/bin/sh
printf 'sshd %s\n' "$*" >> "$SSHD_LOG"
exit "${SSHD_RC:-0}"
SSHD
cat > "$bin/ssh-keygen" <<'SK'
#!/bin/sh
printf 'ssh-keygen %s\n' "$*" >> "$SSHD_LOG"
exit 0
SK
chmod 755 "$bin/sshd" "$bin/ssh-keygen"
: > "$tmp/rc.log"
: > "$tmp/rcs.log"

run_ssh() {
    PATH="$bin:$PATH" RC_LOG="$tmp/rc.log" RCS_LOG="$tmp/rcs.log" \
    RC_STATE="$tmp/rc.state" SSHD_LOG="$tmp/sshd.log" SSHD_RC="${SSHD_RC:-0}" \
    RCS_RC="${RCS_RC:-0}" \
    ORDO_SSH_CONFIG="$tmp/ssh/sshd_config" \
    ORDO_SSH_DROPIN_DIR="$tmp/ssh/sshd_config.d" \
    LC_ALL= LANG=zh_CN.UTF-8 \
    sh scripts/ordo ssh "$@"
}

rm -f "$tmp/rc.state"
rc=0
run_ssh on > "$tmp/ssh1" 2> "$tmp/sshe1" || rc=$?
assert_rc "$rc" 0 "ssh on 退出 0"
_dropin="$tmp/ssh/sshd_config.d/10-ordo.conf"
assert_active_line "$_dropin" "PermitRootLogin no" "禁止 root 直登"
assert_active_line "$_dropin" "PasswordAuthentication yes" "允许用户口令登录"
assert_active_line "$_dropin" "KbdInteractiveAuthentication no" "关闭键盘交互认证"
assert_eq "$(awk -v inc="Include $tmp/ssh/sshd_config.d/*.conf" '$0 == inc {n++} END {print n+0}' "$tmp/ssh/sshd_config")" \
    "1" "sshd_config 补一行 Include（drop-in 才会生效）"
assert_eq "$(awk '$1 == "add" && $2 == "sshd" {n++} END {print n+0}' "$tmp/rc.log")" "1" \
    "sshd 注册进 default runlevel"
# 主机密钥必须先于 sshd -t 生成：镜像里没有主机密钥，先校验必然失败。
assert_eq "$(awk '/ssh-keygen/ {k=NR} /sshd -t/ {t=NR} END {print (k && t && k < t) ? 1 : 0}' "$tmp/sshd.log")" \
    "1" "ssh-keygen -A 先于 sshd -t"
assert_contains "$(cat "$tmp/rcs.log")" "sshd start" "启动 sshd"

_c_dropin="$(cksum < "$_dropin")"
_c_conf="$(cksum < "$tmp/ssh/sshd_config")"
rc=0
run_ssh on > "$tmp/ssh2" 2> "$tmp/sshe2" || rc=$?
assert_rc "$rc" 0 "第二次 ssh on 退出 0（幂等）"
assert_eq "$(cksum < "$_dropin")" "$_c_dropin" "drop-in 内容不变"
assert_eq "$(cksum < "$tmp/ssh/sshd_config")" "$_c_conf" "sshd_config 不再叠加 Include"

case_name "A8 sshd 配置不合法时拒绝启用"

rm -f "$tmp/rc.state"
: > "$tmp/rc.log"
rc=0
SSHD_RC=1 run_ssh on > "$tmp/ssh3" 2> "$tmp/sshe3" || rc=$?
assert_rc "$rc" 1 "sshd -t 失败时退出 1"
assert_contains "$(cat "$tmp/sshe3")" "配置校验失败" "点名校验失败"
assert_eq "$(awk '$1 == "add" && $2 == "sshd" {n++} END {print n+0}' "$tmp/rc.log")" "0" \
    "校验失败时不注册服务"

case_name "A8 sshd 启动失败时不得报已开启"

rm -f "$tmp/rc.state"
: > "$tmp/rc.log"
rc=0
SSHD_RC=0 RCS_RC=1 run_ssh on > "$tmp/ssh5" 2> "$tmp/sshe5" || rc=$?
assert_rc "$rc" 1 "启动失败退出 1"
assert_contains "$(cat "$tmp/ssh5" "$tmp/sshe5" 2>/dev/null)" "并未开启" "点明 SSH 并未开启"

case_name "A8 ordo ssh off：移除策略并停服务（幂等）"

: > "$tmp/rc.log"
: > "$tmp/rcs.log"
rc=0
run_ssh off > "$tmp/ssh4" 2> "$tmp/sshe4" || rc=$?
assert_rc "$rc" 0 "ssh off 退出 0"
assert_rc "$([ -e "$tmp/ssh/sshd_config.d/10-ordo.conf" ] && echo 1 || echo 0)" 0 "drop-in 已移除"
assert_contains "$(cat "$tmp/rc.log")" "del sshd default" "移出 default runlevel"
assert_contains "$(cat "$tmp/rcs.log")" "sshd stop" "停止 sshd"
rc=0
run_ssh off > "$tmp/ssh5" 2> "$tmp/sshe5" || rc=$?
assert_rc "$rc" 0 "第二次 ssh off 退出 0（幂等）"

case_name "A8 手册与命令一致"

_manual="$(cat docs/manual/09-x86-install.md)"
assert_contains "$_manual" "ordo ssh on" "手册给出开启入口"
assert_contains "$_manual" "休眠" "手册写明不支持休眠"
assert_not_contains "$_manual" "echo -n mem > /sys/power/state" "不再教用 echo mem 睡眠"

finish
