#!/bin/sh
# 回归：C1 首启 marker 幂等 + runfile 不随根 BE 回滚；C2 M2 补 user.ordo 实例
#
# 旧版三处叠加：
#   1) first-desktop.sh 用 `test ! -e /var/lib/ordo/greetd-first-session` 断言首启：
#      重装（marker 已存在）直接退出 1，install-external.sh 的 `|| die` 中断安装；
#   2) greetd 的 runfile 放在 /var/lib（根数据集），回滚根 BE 会把「已首启」
#      状态一起回滚，下次开机再次自动登录；
#   3) M2 路径只装 /etc/user/runlevels/default/* 软链，从不建 user.ordo 实例，
#      用户级 dbus / pipewire 永远不会被 OpenRC 拉起。
set -eu
repo=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)
. "$repo/tests/lib/assert.sh"
scratch=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$scratch"' EXIT

mkdir -p "$scratch/bin" \
    "$scratch/opt/ordo/config/desktop/greetd" \
    "$scratch/opt/ordo/config/desktop/umbriel" \
    "$scratch/opt/ordo/config/desktop/wallpapers" \
    "$scratch/opt/ordo/config/platform/m2" \
    "$scratch/opt/ordo/scripts" \
    "$scratch/usr/bin" "$scratch/usr/local/bin" "$scratch/usr/local/sbin" \
    "$scratch/etc/greetd" "$scratch/etc/init.d" "$scratch/etc/runlevels/default" \
    "$scratch/etc/ordo" "$scratch/etc/local.d" \
    "$scratch/home/ordo/.config/umbriel" "$scratch/home/ordo/.config/noctalia" \
    "$scratch/home/.ordo" "$scratch/var/lib/ordo" "$scratch/usr/share/backgrounds"

# first-desktop.sh 读取的声明与工具（内容不参与本用例）。
cp "$repo/config/desktop/greetd/config.toml" "$scratch/opt/ordo/config/desktop/greetd/"
cp "$repo/config/desktop/greetd/first-boot.toml" "$scratch/opt/ordo/config/desktop/greetd/"
for f in config/desktop/m2-desktop-fix.sh config/desktop/ordo-session-env \
         config/desktop/umbriel/ordo-umbriel-session \
         config/desktop/wallpapers/wallpaper-blackhole.png \
         config/platform/m2/install-hardware.sh config/platform/m2/first-apps.sh \
         config/platform/m2/repair-package-defaults.py; do
    : > "$scratch/opt/ordo/$f"
done
: > "$scratch/home/ordo/.config/umbriel/config.toml"
: > "$scratch/home/ordo/.config/noctalia/config.toml"
: > "$scratch/etc/init.d/greetd"
chmod +x "$scratch/etc/init.d/greetd"
: > "$scratch/etc/init.d/user"
ln -s ../init.d/greetd "$scratch/etc/runlevels/default/greetd"
for cmd in umbriel start-umbriel noctalia greetd noctalia-greeter-session; do
    printf '#!/bin/sh\nexit 0\n' > "$scratch/usr/bin/$cmd"
    chmod +x "$scratch/usr/bin/$cmd"
done
printf '#!/bin/sh\nexit 0\n' > "$scratch/opt/ordo/scripts/ordo-config"
chmod +x "$scratch/opt/ordo/scripts/ordo-config"

# 最小 install 桩：只实现 `-d` 建目录（开发机 BSD install 没有 -D）。
cat > "$scratch/bin/install" <<'STUB'
#!/bin/sh
set -eu
make_dir=0
paths=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -d) make_dir=1; shift ;;
        -Dm*) shift ;;
        -m) shift; [ "$#" -gt 0 ] && shift ;;
        -*) shift ;;
        *) paths="$paths $1"; shift ;;
    esac
done
if [ "$make_dir" -eq 1 ]; then
    for p in $paths; do mkdir -p "$p"; done
fi
exit 0
STUB
printf '#!/bin/sh\nexit 0\n' > "$scratch/bin/getent"
printf '#!/bin/sh\nexit 0\n' > "$scratch/bin/chown"
cat > "$scratch/bin/rc-update" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$scratch/rc.log"
exit 0
EOF
chmod +x "$scratch/bin/install" "$scratch/bin/getent" "$scratch/bin/chown" \
    "$scratch/bin/rc-update"

# 绝对路径换到夹具，逻辑逐字保留。
sed -e "s|/opt/ordo|$scratch/opt/ordo|g" \
    -e "s|/usr/local/sbin|$scratch/usr/local/sbin|g" \
    -e "s|/usr/local/bin|$scratch/usr/local/bin|g" \
    -e "s|/usr/bin/|$scratch/usr/bin/|g" \
    -e "s|/etc/greetd|$scratch/etc/greetd|g" \
    -e "s|/etc/init.d|$scratch/etc/init.d|g" \
    -e "s|/etc/runlevels|$scratch/etc/runlevels|g" \
    -e "s|/etc/local.d|$scratch/etc/local.d|g" \
    -e "s|/etc/ordo|$scratch/etc/ordo|g" \
    -e "s|/home/ordo|$scratch/home/ordo|g" \
    -e "s|/home/.ordo|$scratch/home/.ordo|g" \
    -e "s|/var/lib/ordo|$scratch/var/lib/ordo|g" \
    -e "s|/usr/share/backgrounds|$scratch/usr/share/backgrounds|g" \
    "$repo/config/platform/m2/first-desktop.sh" > "$scratch/first-desktop.sh"

_run_installer() {
    _rc=0
    : > "$scratch/rc.log"
    PATH="$scratch/bin:$PATH" HOME="$scratch/root" \
        sh "$scratch/first-desktop.sh" >"$scratch/out" 2>"$scratch/err" || _rc=$?
}

_marker_new="$scratch/home/.ordo/greetd-first-session"
_marker_old="$scratch/var/lib/ordo/greetd-first-session"

case_name "C1 新装：部署首启配置，marker 留给 greetd 创建"

_run_installer
assert_rc "$_rc" 0 "新装退出 0"
assert_contains "$(cat "$scratch/etc/greetd/config.toml")" "[initial_session]" "写入首启自动登录段"
assert_rc "$([ -d "$scratch/home/.ordo" ] && echo 0 || echo 1)" 0 "创建 /home/.ordo（独立数据集上的 marker 目录）"
assert_rc "$([ -e "$_marker_new" ] && echo 1 || echo 0)" 0 "安装器不伪造 marker"

case_name "C1 重装（marker 已存在）幂等，不再 die"

printf 'done\n' > "$_marker_new"
_run_installer
assert_rc "$_rc" 0 "marker 存在时重装退出 0（旧版 test ! -e 会 die）"
assert_eq "$(cat "$_marker_new")" "done" "重装保留已有 marker"

case_name "C1 旧版 marker 从 /var/lib 迁移到 /home"

rm -f "$_marker_new"
printf 'old\n' > "$_marker_old"
_run_installer
assert_rc "$_rc" 0 "带旧 marker 的升级退出 0"
assert_rc "$([ -e "$_marker_old" ] && echo 1 || echo 0)" 0 "旧位置 marker 已移走"
assert_eq "$(cat "$_marker_new" 2>/dev/null || :)" "old" "内容迁到不随 BE 回滚的位置"

case_name "C1 runfile 声明在 /home（根 BE 回滚不会带回自动登录）"

_runfile="$(sed -n 's/^runfile = "\(.*\)"$/\1/p' "$repo/config/desktop/greetd/first-boot.toml")"
case "$_runfile" in
    /home/*) assert_rc 0 0 "runfile 在 /home（$_runfile）" ;;
    *) assert_rc 1 0 "runfile 在 /home（实际: ${_runfile:-未声明}）" ;;
esac
assert_not_contains "$(cat "$repo/config/desktop/greetd/first-boot.toml")" \
    'runfile = "/var/lib' "runfile 不再指向根数据集"

case_name "C2 M2 建 user.ordo 实例并进 default runlevel"

assert_eq "$(readlink "$scratch/etc/init.d/user.ordo" 2>/dev/null || :)" \
    "$scratch/etc/init.d/user" "user.ordo 软链到 openrc 用户服务模板"
assert_contains "$(cat "$scratch/rc.log")" "add user.ordo default" "注册到 default runlevel"

case_name "C2 缺 /etc/init.d/user 时点名失败，不静默跳过"

rm -f "$scratch/etc/init.d/user.ordo" "$scratch/etc/init.d/user"
_run_installer
assert_rc "$_rc" 1 "缺模板退出 1"
assert_contains "$(cat "$scratch/err")" "user（openrc 用户服务模板）" "说明缺的是哪个模板"

finish
