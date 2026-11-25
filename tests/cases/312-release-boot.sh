#!/bin/sh
set -eu
root=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)
python3 -B "$root/tests/m2_generic_initrd.py"
python3 -B "$root/tests/release_macos.py"
