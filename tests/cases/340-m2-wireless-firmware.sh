#!/bin/sh
# P1-03 回归：无线固件「源文件名 → 驱动请求名」映射一处定义、四处共用。
set -eu
cd "$(dirname "$(readlink -f "$0")")/../.."
PYTHONDONTWRITEBYTECODE=1 python3 -B tests/m2_firmware_map.py
