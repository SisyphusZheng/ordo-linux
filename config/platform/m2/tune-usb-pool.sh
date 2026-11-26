#!/bin/sh
# USB 根池健康参数：优先 autotrim=on，失败时落月检 TRIM cron 兜底（D3-4）。
#
# 用法：tune-usb-pool.sh <池名> [安装根，默认 /]
# 退出：0 已开启 autotrim，或兜底 cron 已落盘
#       1 autotrim 与兜底 cron 都没成功
#       2 用法错误（无法判定）
#
# 为什么不在 zpool create 时 -o autotrim=on：有些 USB-SATA/UAS 桥不报告 TRIM
# 能力，create 会直接失败、整次安装中止。建池后单独 set，失败只降级不中断。
set -u

if [ "$#" -lt 1 ] || [ -z "$1" ]; then
    printf '用法：%s <池名> [安装根]\n' "$0" >&2
    exit 2
fi
pool=$1
root=${2:-/}
cron_dir=$root/etc/cron.d
cron=$cron_dir/ordo-trim

if zpool set autotrim=on "$pool" 2>/dev/null; then
    # autotrim 由内核按空闲块触发；撤掉旧兜底，避免每月重复 TRIM。
    rm -f "$cron" 2>/dev/null || :
    printf 'autotrim=on：%s\n' "$pool"
    exit 0
fi

printf '警告：%s 的 autotrim 开启失败（USB 桥可能不支持 TRIM），改落月检 cron\n' "$pool" >&2
mkdir -p "$cron_dir" 2>/dev/null || {
    printf '无法创建 %s，TRIM 兜底未落地\n' "$cron_dir" >&2
    exit 1
}
tmp=$cron.$$
if ! cat >"$tmp" <<EOF
# Ordo — 外接系统盘不支持 autotrim 时的兜底（由 tune-usb-pool.sh 生成）
# 每月 1 日 03:17 手动 TRIM；桥不支持 TRIM 时命令失败，只记日志不重试。
SHELL=/bin/sh
PATH=/sbin:/bin:/usr/sbin:/usr/bin
17 3 1 * * root zpool trim $pool >/dev/null 2>&1 || logger -t ordo-trim 'zpool trim $pool 失败（USB 桥可能不支持 TRIM）'
EOF
then
    rm -f "$tmp"
    printf '无法写 %s，TRIM 兜底未落地\n' "$cron" >&2
    exit 1
fi
chmod 0644 "$tmp" && mv -f "$tmp" "$cron" || {
    rm -f "$tmp"
    printf '无法落盘 %s，TRIM 兜底未生效\n' "$cron" >&2
    exit 1
}
printf '已落月检 TRIM：%s\n' "$cron"
exit 0
