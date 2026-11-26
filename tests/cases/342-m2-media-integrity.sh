#!/bin/sh
# P1-01 回归：介质侧 rootfs 分片门禁、默认引导读回、模块索引与备份清理。
set -eu
cd "$(dirname "$(readlink -f "$0")")/../.."
sh -n config/platform/m2/install-external.sh
sh -n config/platform/m2/install-display.sh
PYTHONDONTWRITEBYTECODE=1 python3 -B tests/m2_media_integrity.py
