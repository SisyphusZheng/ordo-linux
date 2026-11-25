#!/bin/sh
set -eu
cd "$(dirname "$(readlink -f "$0")")/../.."
python3 -B tests/doctor_execution_context.py
