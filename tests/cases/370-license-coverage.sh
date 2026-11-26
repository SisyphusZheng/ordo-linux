#!/bin/sh
# 回归：许可必须覆盖每一个入库文件，且 LICENSE 与 LICENSE-NOTES 的类别一致
#
# 曾经：LICENSE 收窄后把 dev/、overlay/ 和根目录 Markdown 排出许可范围，
# 而 LICENSE-NOTES 的表仍列着它们 —— 两个文件各自表述，谁也没被机器核对。
# 这里把 LICENSE-NOTES 的逐路径表当作唯一事实来源：每个 git 跟踪文件都必须
# 落在某一类，且具体类别不得回落到更宽的类别。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

case_name "逐路径许可表覆盖所有入库文件"

python3 - "$ROOT" <<'PY'
from pathlib import Path
import re
import subprocess
import sys

root = Path(sys.argv[1])
notes = (root / "LICENSE-NOTES.md").read_text()
rows = []
for line in notes.splitlines():
    if not line.startswith("| `"):
        continue
    cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
    if len(cells) < 3:
        continue
    patterns = re.findall(r"`([^`]+)`", cells[0])
    if patterns:
        rows.append((patterns, cells[1]))

def glob(pattern):
    out = []
    index = 0
    while index < len(pattern):
        if pattern.startswith("**", index):
            out.append(".*")
            index += 2
        elif pattern[index] == "*":
            out.append("[^/]*")
            index += 1
        else:
            out.append(re.escape(pattern[index]))
            index += 1
    return re.compile("^" + "".join(out) + "$")

compiled = [([glob(p) for p in patterns], license_cell)
            for patterns, license_cell in rows]

def classify(path):
    for patterns, license_cell in compiled:
        if any(pattern.match(path) for pattern in patterns):
            return license_cell
    return None

tracked = subprocess.run(["git", "-C", str(root), "ls-files", "-z"],
                         check=True, capture_output=True).stdout.decode().split("\0")
# 已从工作区删除、但尚未提交的删除不应计入覆盖。
bad = [path for path in tracked
       if path and path != "LICENSE" and (root / path).is_file() and classify(path) is None]
if bad:
    print("       未落入任何许可类别：")
    for path in bad:
        print(f"         {path}")
    sys.exit(1)

expected = {
    "dev/vm/configure-root.sh": "GPL-2.0-or-later",
    "overlay/gui-apps/luciole/Manifest": "GPL-2.0-or-later",
    "config/world": "GPL-2.0-or-later",
    "README.md": "CC BY-SA 4.0",
    "AGENTS.md": "CC BY-SA 4.0",
    "docs/manual/01-install.md": "CC BY-SA 4.0",
    "config/desktop/wallpapers/wallpaper-seven.png": "CC BY-SA 4.0",
    "assets/branding/ordo-mark.svg": "CC BY-SA 4.0",
}
wrong = []
for path, want in expected.items():
    got = classify(path) or ""
    if want not in got:
        wrong.append(f"{path}: 期望 {want}，实际 {got or '未分类'}")
if wrong:
    print("       具体类别回落到错误类别：")
    for item in wrong:
        print(f"         {item}")
    sys.exit(1)
PY
assert_rc "$?" 0 "每个跟踪文件都有类别，且具体路径优先"

case_name "LICENSE 与 LICENSE-NOTES 共用同一套类别"

_lic="$(cat "$ROOT/LICENSE")"
_missing=""
for _token in install.sh scripts/ tests/ dev/ overlay/ config/ docs/ '*.md' \
              README.md AGENTS.md CONTRIBUTING.md CHANGELOG.md \
              assets/branding/ config/desktop/wallpapers/ licenses/ LICENSE-NOTES.md; do
    case "$_lic" in
        *"$_token"*) ;;
        *) _missing="$_missing $_token" ;;
    esac
done
assert_eq "$_missing" "" "LICENSE 覆盖表里的所有类别"

assert_contains "$_lic" "LICENSE-NOTES.md" "LICENSE 指明逐路径表的出处"

finish
