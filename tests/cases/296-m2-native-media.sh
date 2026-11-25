#!/bin/sh
set -eu
cd "$(dirname "$(readlink -f "$0")")/../.."
sh -n config/platform/m2/install-native.sh
PYTHONDONTWRITEBYTECODE=1 python3 tests/m2_native_payload.py
