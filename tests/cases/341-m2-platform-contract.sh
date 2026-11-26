#!/bin/sh
# P1-06 回归：M2 平台声明不降级、@ordo-m2 进 world_sets、验收失败必须自述原因。
set -eu
cd "$(dirname "$(readlink -f "$0")")/../.."
PYTHONDONTWRITEBYTECODE=1 python3 -B tests/m2_platform_hardware.py
