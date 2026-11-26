#!/bin/sh
# P1-04 回归：M2 首启按用户身份消费 apps.d，行内注释不得当 app id。
set -eu
cd "$(dirname "$(readlink -f "$0")")/../.."
sh -n config/platform/m2/first-apps.sh
sh -n config/platform/m2/first-desktop.sh
PYTHONDONTWRITEBYTECODE=1 python3 -B tests/m2_first_apps.py
