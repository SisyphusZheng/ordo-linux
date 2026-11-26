#!/bin/sh
# P1-06 / B4 回归：M2 硬件验收报告格式契约 -> doctor 三态消费（2 不得当通过）。
set -eu
cd "$(dirname "$(readlink -f "$0")")/../.."
sh -n scripts/doctor
sh -n config/platform/m2/verify-hardware.sh
PYTHONDONTWRITEBYTECODE=1 python3 -B tests/m2_hardware_report.py
