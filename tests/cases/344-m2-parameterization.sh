#!/bin/sh
# P2-11 回归：内核版本与 ebuild 名从声明派生，安装器/构建器不得写死。
set -eu
cd "$(dirname "$(readlink -f "$0")")/../.."
PYTHONDONTWRITEBYTECODE=1 python3 -B tests/m2_parameterization.py
