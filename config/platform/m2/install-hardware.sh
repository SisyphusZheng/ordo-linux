#!/bin/sh
# Deploy the local, offline half of the Mac14,2 hardware configuration.
set -eu
here=$(dirname "$(readlink -f "$0")")

mkdir -p /etc/ordo
# 平台标记只补写、不改写：install-native.sh 在原生包集验完后写 m2-native，
# 而 first-desktop.sh 在它之后还会再跑本脚本。旧实现按整串比较内容，注释/空白
# 变体或 vm/bare-metal 标记都会被判成“非 native”并静默改写成 m2。存在即保留：
# 无法识别的旧标记交给 ordo_world 报 exit 2（无法判定），而不是假装成 M2。
if [ ! -e /etc/ordo/platform ]; then
    printf 'm2\n' > /etc/ordo/platform.new
    mv -f /etc/ordo/platform.new /etc/ordo/platform
fi

# /run 是 tmpfs，安装期的 mkdir 不会留到下次启动。掉盘标记与扬声器保护标记
# 都要由会话里的 ordo 用户写，所以用 tmpfiles 在每次启动重建 0770 root:ordo。
mkdir -p /etc/tmpfiles.d
cat > /etc/tmpfiles.d/ordo-runtime.conf <<'RUNTIME'
# Ordo — 运行期共享目录（verify-hardware.sh 以 ordo 用户写标记）
d /run/ordo 0770 root ordo -
RUNTIME
chmod 0644 /etc/tmpfiles.d/ordo-runtime.conf
# 本机当前会话也立即可写（重装/升级时不必等到下次启动）。
mkdir -p /run/ordo
chgrp ordo /run/ordo 2>/dev/null || :
chmod 0770 /run/ordo 2>/dev/null || :

# 充电上限（best-effort）：内核没有该属性时静默跳过，不把缺能力当失败。
install -d -m 0755 /etc/udev/rules.d
install -Dm644 "$here/udev/90-ordo-charge-threshold.rules" \
    /etc/udev/rules.d/90-ordo-charge-threshold.rules || \
    printf '充电上限规则未落位（/etc/udev/rules.d 不可写）\n' >&2
for _bat in /sys/class/power_supply/BAT*; do
    [ -w "$_bat/charge_control_end_threshold" ] || continue
    printf '80\n' > "$_bat/charge_control_end_threshold" 2>/dev/null || :
done

install -Dm755 "$here/verify-hardware.sh" /usr/local/bin/ordo-m2-hardware
install -Dm755 "$here/keyboard-light.sh" /usr/local/bin/ordo-keyboard-light
install -Dm644 "$here/package.use" /etc/portage/package.use/ordo-m2
install -Dm644 "$here/package.accept_keywords" /etc/portage/package.accept_keywords/ordo-m2
install -Dm644 "$here/world" /etc/portage/sets/ordo-m2
# 平台原生包集必须真的被选中：只写 /etc/portage/sets 而不同步 world_sets 时，
# @world 里没有它，一次 emerge --depclean 就能把 speakersafetyd 摘掉（P1-06）。
if [ "$(id -u)" = 0 ]; then
    install -d -m 0755 /var/lib/portage
    : >> /var/lib/portage/world_sets
    grep -Fxq '@ordo-m2' /var/lib/portage/world_sets ||
        printf '%s\n' '@ordo-m2' >> /var/lib/portage/world_sets
fi

# 扬声器保护装配（D1-5）：
# 硬条件只留两个包 —— speakersafetyd 是保护进程本体，asahi-audio 提供 J413
# 校准/DSP。其余文件与版本检查不阻止装配，但缺哪项必须逐条打印：旧版六条件
# 全真的 if 没有 else，版本漂移时静默不装，失败只进一份没人看的报告。
hard_missing=
soft_missing=
portageq has_version / '=sys-apps/speakersafetyd-2.0.1::asahi' ||
    hard_missing="$hard_missing sys-apps/speakersafetyd-2.0.1"
portageq has_version / '~media-libs/asahi-audio-4.1::asahi' ||
    hard_missing="$hard_missing media-libs/asahi-audio-4.1"
[ -x /etc/init.d/speakersafetyd ] ||
    soft_missing="$soft_missing /etc/init.d/speakersafetyd"
[ -r /usr/share/speakersafetyd/apple/j413.conf ] ||
    soft_missing="$soft_missing /usr/share/speakersafetyd/apple/j413.conf"
[ -r /usr/share/asahi-audio/j413/graph.json ] ||
    soft_missing="$soft_missing /usr/share/asahi-audio/j413/graph.json"
[ -r /usr/share/asahi-audio/j413/mic.json ] ||
    soft_missing="$soft_missing /usr/share/asahi-audio/j413/mic.json"
[ -r '/usr/share/alsa/ucm2/conf.d/macaudio/MacBook Air J413.conf' ] ||
    soft_missing="$soft_missing /usr/share/alsa/ucm2/conf.d/macaudio/MacBook Air J413.conf"

if [ -n "$hard_missing" ]; then
    printf '扬声器保护未装配：缺少硬性组件%s\n' "$hard_missing" >&2
elif [ ! -x /etc/init.d/speakersafetyd ]; then
    printf '扬声器保护未装配：包已声明但服务脚本缺失%s\n' "$soft_missing" >&2
else
    [ -z "$soft_missing" ] ||
        printf '扬声器保护降级装配：以下文件缺失，声音可能不完整：%s\n' "$soft_missing" >&2
    install -Dm644 "$here/speakersafetyd.conf" /etc/conf.d/speakersafetyd
    rc-update add speakersafetyd default ||
        printf '扬声器保护服务注册失败（rc-update add speakersafetyd default）\n' >&2
fi
