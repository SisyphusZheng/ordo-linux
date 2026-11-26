#!/bin/sh
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
if /usr/bin/ordo-install --apply; then
    printf '\n安装完成。输入 poweroff 关机，再从同一块 USB 盘启动。\n'
else
    printf '\n安装器已停止。可以在此检查现场，再运行 ordo-install --check。\n'
fi
exec /usr/bin/bash -il
