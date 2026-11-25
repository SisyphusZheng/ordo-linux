#!/bin/sh
set -eu
cd "$(dirname "$(readlink -f "$0")")/../.."
PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import sys
from xml.etree import ElementTree
sys.path.insert(0, "dev/m2")
from boot_art import MARK
from brand_boot import brand_stage1

# The visible mark consists entirely of two clipped fills of one path.
root = ElementTree.parse(MARK).getroot()
ns = {"s": "http://www.w3.org/2000/svg"}
assert [e.get("href") for e in root.findall("s:use", ns)] == ["#ring", "#ring"]
assert not root.findall(".//s:image", ns)
try:
    brand_stage1(b"unknown")
except ValueError:
    pass
else:
    raise AssertionError("unexpected stage 1 accepted")
PY
