#!/bin/sh
set -eu
cd "$(dirname "$(readlink -f "$0")")/../.."
python3 -B tests/m2_package_defaults.py
