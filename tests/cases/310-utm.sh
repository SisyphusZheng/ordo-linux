#!/bin/sh
set -eu
here=$(dirname "$(readlink -f "$0")")
python3 "$here/../vm_utm.py"
