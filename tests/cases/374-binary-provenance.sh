#!/bin/sh
# 回归：入库的 M2 原生二进制必须有摘要与产地
#
# P2-12：dev/m2/display/modules.tar.gz 与 dev/m2/power/macsmc-power.ko
# 随仓库分发，但既没有 sha256 记录，产地说明也被删掉；介质构建读到被改写的
# 文件时无法发现。摘要与产地登记在 config/release/0.1.0/SOURCES。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

_src="$ROOT/config/release/0.1.0/SOURCES"

case_name "二进制摘要与产地登记在发布锚点"

python3 - "$ROOT" <<'PY'
from pathlib import Path
import hashlib
import sys

root = Path(sys.argv[1])
text = (root / "config/release/0.1.0/SOURCES").read_text()
values = {}
for line in text.splitlines():
    stripped = line.strip()
    if not stripped or stripped.startswith("#") or "=" not in stripped:
        continue
    key, value = stripped.split("=", 1)
    values[key] = value

required = [
    "m2_display_modules", "m2_display_modules_sha256", "m2_display_rebuild",
    "m2_power_module", "m2_power_module_sha256", "m2_power_rebuild",
]
missing = [key for key in required if not values.get(key)]
if missing:
    print(f"       SOURCES 缺少字段：{missing}")
    sys.exit(1)

for path_key, digest_key, rebuild_key, label in (
    ("m2_display_modules", "m2_display_modules_sha256", "m2_display_rebuild", "内屏模块包"),
    ("m2_power_module", "m2_power_module_sha256", "m2_power_rebuild", "电池模块"),
):
    artifact = root / values[path_key]
    if not artifact.is_file():
        print(f"       {label} 不存在：{values[path_key]}")
        sys.exit(1)
    actual = hashlib.sha256(artifact.read_bytes()).hexdigest()
    if actual != values[digest_key]:
        print(f"       {label} 摘要不符：{values[path_key]}")
        print(f"         记录 {values[digest_key]}")
        print(f"         实际 {actual}")
        sys.exit(1)
    if not (root / values[rebuild_key]).is_file():
        print(f"       {label} 的重建脚本不存在：{values[rebuild_key]}")
        sys.exit(1)

for fact in ("7.0.9-asahi-2", "modules.tar.gz", "macsmc-power.ko", "M2"):
    if fact not in text:
        print(f"       SOURCES 缺少产地事实：{fact}")
        sys.exit(1)
PY
assert_rc "$?" 0 "摘要与实际文件一致，产地可复核"

finish
