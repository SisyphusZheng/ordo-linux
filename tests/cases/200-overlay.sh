#!/bin/sh
# 门禁：本地 overlay 结构与内容完整
#
# 背景：Luciole 既不在 GURU 也不在主树（2026-11-22 核实），
# 需要自备 ebuild。overlay 必须随仓库分发，否则重装系统后
# 文件管理器会缺失。
set -u
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

case_name "overlay 结构完整"

for p in overlay/README.md overlay/metadata/layout.conf overlay/profiles/repo_name; do
    assert_rc "$([ -f "$ROOT/$p" ] && echo 0 || echo 1)" 0 "$p 存在"
done

assert_contains "$(cat "$ROOT/overlay/metadata/layout.conf")" "masters = gentoo" "layout.conf 声明 master"
assert_eq "$(cat "$ROOT/overlay/profiles/repo_name" | tr -d '[:space:]')" "local" "repo_name 为 local"

case_name "luciole ebuild 存在且关键字段正确"

_eb="$ROOT/overlay/gui-apps/luciole/luciole-0.1.0.ebuild"
assert_rc "$([ -f "$_eb" ] && echo 0 || echo 1)" 0 "luciole-0.1.0.ebuild 存在"

_ebt="$(cat "$_eb")"
# 上游无任何 release tag，只能用 archive/ 快照
assert_contains "$_ebt" "archive/" "用 archive/ 快照（上游无 tag）"
assert_contains "$_ebt" "app-arch/libarchive" "libarchive 用 app-arch/（不是 sys-libs/）"
assert_contains "$_ebt" "dev-build/meson" "meson 用 dev-build/（不是 dev-util/）"
assert_contains "$_ebt" "virtual/acl" "acl 走 virtual/"
assert_contains "$_ebt" "wayland-protocols" "声明 wayland-protocols 依赖"

case_name "Luciole 归档钉到提交并随 overlay 分发校验清单"

python3 - "$_eb" <<'PYTHON'
from hashlib import blake2b, sha512
from pathlib import Path
import re
import sys

ebuild = Path(sys.argv[1])
source = ebuild.read_bytes()
commit, = re.findall(rb'^LUCIOLE_COMMIT="([a-f0-9]{40})"$', source, flags=re.M)
assert b'/archive/${LUCIOLE_COMMIT}.tar.gz -> ${P}-${LUCIOLE_COMMIT}.tar.gz' in source
assert b'S="${WORKDIR}/${PN}-${LUCIOLE_COMMIT}"' in source
manifest = [line.split() for line in ebuild.with_name('Manifest').read_text().splitlines()]
dist, recipe = manifest
archive_name = f'{ebuild.stem}-{commit.decode()}.tar.gz'
assert dist[:2] == ['DIST', archive_name]
assert int(dist[2]) > 0
assert dist[3::2] == ['BLAKE2B', 'SHA512']
assert all(re.fullmatch(r'[a-f0-9]{128}', digest) for digest in dist[4::2])
assert recipe == ['EBUILD', ebuild.name, str(len(source)), 'BLAKE2B', blake2b(source).hexdigest(),
                  'SHA512', sha512(source).hexdigest()]
PYTHON
assert_rc "$?" 0 "固定归档名与清单一致，ebuild 哈希正确"
assert_not_contains "$(cat "$ROOT/overlay/.gitignore")" "gui-apps/*/Manifest" \
    "没有忽略 gui-apps 的 Manifest 规则"
assert_rc "$(cd "$ROOT" && git check-ignore -q --no-index overlay/gui-apps/luciole/Manifest; echo $?)" 1 \
    "Luciole Manifest 不被忽略"
# 已跟踪文件在普通模式下恒返回「未忽略」；必须用 --no-index + 尚未存在的新包
# 路径，才能探到会吞掉未来 Manifest 的规则。
assert_rc "$(cd "$ROOT" && git check-ignore -q --no-index overlay/gui-apps/newpkg/Manifest; echo $?)" 1 \
    "假想新包的 Manifest 不被忽略（--no-index 探测）"

case_name "已下线的 overlay 包不再存在"

assert_rc "$([ -e "$ROOT/overlay/gui-apps/ashell" ] && echo 1 || echo 0)" 0 \
    "ashell overlay 已随旧栈移除"

finish
