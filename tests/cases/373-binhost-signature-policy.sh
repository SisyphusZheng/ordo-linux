#!/bin/sh
# 回归：禁用 binpkg 验签的调用必须同时断掉远端通道
#
# P2-12：install-native.sh 在本地 merge 里关闭 binpkg-request-signature，
# 若仍保留 PORTAGE_BINHOST 或允许 --getbinpkg，就成了一条拉未签名包的路径。
# 策略文字见 docs/decisions/0014-binpkg签名策略.md。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

_inst="$ROOT/config/platform/m2/install-native.sh"
_adr="$ROOT/docs/decisions/0014-binpkg签名策略.md"

case_name "签名策略有书面决定"

assert_rc "$([ -f "$_adr" ] && echo 0 || echo 1)" 0 "ADR 0014 存在"
_adr_text="$(cat "$_adr")"
assert_contains "$_adr_text" "binpkg-request-signature" "登记了验签开关"
assert_contains "$_adr_text" "binpkg-signing" "登记了签名方式"
assert_contains "$_adr_text" "PORTAGE_BINHOST" "登记了远端通道的约束"
assert_contains "$_adr_text" "M2-SHA256SUMS" "登记了离线介质的信任锚"
assert_contains "$(cat "$ROOT/docs/decisions/README.md")" "(0014" "ADR 索引已登记 0014"

case_name "禁用验签只允许出现在离线本地 merge"

python3 - "$_inst" <<'PY'
from pathlib import Path
import sys

lines = Path(sys.argv[1]).read_text().splitlines()
found = 0
bad = []
for index, line in enumerate(lines):
    if "FEATURES=" not in line or "-binpkg-request-signature" not in line:
        continue
    found += 1
    command = "\n".join(lines[index:index + 4])
    for token, label in (("PORTAGE_BINHOST=''", "清空 PORTAGE_BINHOST"),
                         ("--getbinpkg=n", "显式 --getbinpkg=n"),
                         ("--usepkgonly", "只使用本地包")):
        if token not in command:
            bad.append(f"第 {index + 1} 行禁用验签但未{label}")
if found == 0:
    bad.append("install-native.sh 不再禁用验签；请同步 ADR 0014 与本用例")
if bad:
    for item in bad:
        print(f"       {item}")
    sys.exit(1)
PY
assert_rc "$?" 0 "关闭验签的命令同时锁定为本地离线"

case_name "远端通道上线前 BINHOST 为空"

assert_contains "$(cat "$ROOT/config/make.conf.example")" 'BINHOST=""' \
    "BINHOST 未启用（与 ADR 0014 一致）"

finish
