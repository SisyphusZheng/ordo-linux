#!/bin/sh
# 回归：M2/VM 的 greetd 自有 initd 不能被 doctor 报成「无图形登录界面」
#
# serial.log 实机：M2 由 first-desktop.sh / install-external.sh 装 greetd 自带
# initd（provide display-manager），从不写 /etc/conf.d/display-manager；
# 旧版 doctor 只看后者，M2 上恒定告警「无图形登录界面」。
set -eu
repo=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)
. "$repo/tests/lib/assert.sh"
scratch=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/root/scripts" "$scratch/root/config/desktop" "$scratch/bin" \
    "$scratch/etc/init.d" "$scratch/etc/runlevels/default" "$scratch/etc/greetd" \
    "$scratch/etc/ordo" "$scratch/usr/share/wayland-sessions"

printf 'POOL=rpool\nDATASET=rpool/root/ordo\nHOME_DATASET=rpool/home\n' > "$scratch/root/config/dataset"
: > "$scratch/root/config/forbidden-world"
printf 'sys-apps/baseline\n' > "$scratch/world"
cp "$repo/scripts/lib.sh" "$scratch/root/scripts/lib.sh"
sed -e "s|/etc/conf.d/display-manager|$scratch/etc/conf.d/display-manager|g" \
    -e "s|/etc/init.d/greetd|$scratch/etc/init.d/greetd|g" \
    -e "s|/etc/runlevels/default/greetd|$scratch/etc/runlevels/default/greetd|g" \
    -e "s|/etc/greetd/config.toml|$scratch/etc/greetd/config.toml|g" \
    -e "s|/usr/share/wayland-sessions|$scratch/usr/share/wayland-sessions|g" \
    -e "s|/etc/ordo/platform|$scratch/etc/ordo/platform|g" \
    -e "s|/var/lib/portage/world|$scratch/world|g" \
    "$repo/scripts/doctor" > "$scratch/root/scripts/doctor"

# greetd 自有 initd：有 /etc/init.d/greetd 与 runlevel 链接，没有 display-manager conf。
: > "$scratch/etc/init.d/greetd"
ln -sfn ../init.d/greetd "$scratch/etc/runlevels/default/greetd"
: > "$scratch/etc/greetd/config.toml"
: > "$scratch/usr/share/wayland-sessions/umbriel.desktop"
printf 'm2\n' > "$scratch/etc/ordo/platform"
for cmd in noctalia-greeter-session umbriel noctalia luciole fcitx5 pgrep; do
    printf '#!/bin/sh\nexit 0\n' > "$scratch/bin/$cmd"
    chmod +x "$scratch/bin/$cmd"
done
printf '#!/bin/sh\nexit 0\n' > "$scratch/root/scripts/ordo-config"
chmod +x "$scratch/root/scripts/ordo-config"

doctor() {
    PATH="$scratch/bin:$PATH" HOME="$scratch/nohome" \
        sh "$scratch/root/scripts/doctor" 2>&1 || true
}

case_name "M2 平台：认出 greetd 自有 initd，不误报"

_out=$(doctor)
assert_contains "$_out" "登录管理器 greetd（自有 initd" "认 greetd 入口"
assert_not_contains "$_out" "无图形登录界面" "不再误报缺少 display-manager"

case_name "greetd 未进 default runlevel：必须报问题"

rm -f "$scratch/etc/runlevels/default/greetd"
_out=$(doctor)
assert_contains "$_out" "greetd 未加入 default runlevel" "报告未启用"
assert_not_contains "$_out" "登录管理器 greetd（自有 initd" "未启用时不打绿勾"

case_name "平台未知的旧镜像：仍告警（不替它开绿灯）"

ln -sfn ../init.d/greetd "$scratch/etc/runlevels/default/greetd"
printf 'bare-metal\n' > "$scratch/etc/ordo/platform"
_out=$(doctor)
assert_contains "$_out" "无图形登录界面" "非 m2/vm 且无 display-manager 配置仍告警"

finish
