#!/bin/sh
# 回归：P2-11 VM 装配器写死 luciole-0.1.0.ebuild
#       P2-08 VM 镜像只建 /etc/user/runlevels/default/*，不建 user.ordo 实例
#
# configure-root.sh 是 UTM 镜像的根装配器：升级 Luciole 只换 overlay 里的
# ebuild 文件名，装配器必须按 glob 取；钉死版本会在下次升级时静默装错包。
# 用户级 OpenRC 服务同理：没有 user.ordo 实例，/etc/user/runlevels 下的
# dbus/pipewire 软链永远不会被执行。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ordo-vm-root.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

_script="$(cat "$ROOT/dev/vm/configure-root.sh")"

case_name "装配器按 glob 取 ebuild，不钉版本"
assert_not_contains "$_script" 'luciole-0.1.0.ebuild' "不再出现写死的 ebuild 名"
assert_active_line "$ROOT/dev/vm/configure-root.sh" 'for ebuild in "$repo/overlay/$luciole"/*.ebuild; do' \
    "按 overlay 里的实际 ebuild 遍历"
assert_active_line "$ROOT/dev/vm/configure-root.sh" 'install -Dm644 "$repo/overlay/$luciole/Manifest"' \
    "Manifest 仍然被安装"
assert_active_line "$ROOT/dev/vm/configure-root.sh" 'test -f "$ebuild"' \
    "glob 无匹配时失败（不静默跳过）"

block="$(awk 'index($0, "local_repo=$(portageq get_repo_path / local)") == 1 { on = 1 }
              on && /^groupadd -f plugdev$/ { exit }
              on { print }' "$ROOT/dev/vm/configure-root.sh")"
assert_rc "$([ -n "$block" ] && echo 0 || echo 1)" 0 "能抽出 ebuild 安装块"

run_block() { # repo-root local-root
    _repo=$1
    _local=$2
    {
        printf '%s\n' 'set -eu'
        printf '%s\n' 'portageq() { printf "%s\n" "$local"; }'
        printf '%s\n' "$block"
    } > "$tmp/copy.sh"
    repo="$_repo" local="$_local" /bin/sh "$tmp/copy.sh" > "$tmp/out" 2>&1
}

case_name "9.9.9 的 ebuild 也会被装配（版本不是常量）"
mkdir -p "$tmp/repo-bump/overlay/gui-apps/luciole" "$tmp/local-bump/gui-apps/luciole"
printf 'EAPI=8\nLUCIOLE_COMMIT="main"\n' > "$tmp/repo-bump/overlay/gui-apps/luciole/luciole-9.9.9.ebuild"
printf 'DIST luciole-9.9.9\n' > "$tmp/repo-bump/overlay/gui-apps/luciole/Manifest"
run_block "$tmp/repo-bump" "$tmp/local-bump"; rc=$?
assert_eq "$rc" 0 "装配块执行成功"
assert_rc "$([ -f "$tmp/local-bump/gui-apps/luciole/luciole-9.9.9.ebuild" ] && echo 0 || echo 1)" 0 \
    "按实际文件名落 ebuild"
assert_eq "$(cat "$tmp/local-bump/gui-apps/luciole/Manifest" 2>/dev/null)" "DIST luciole-9.9.9" \
    "Manifest 同步落盘"
assert_rc "$([ -e "$tmp/local-bump/gui-apps/luciole/luciole-0.1.0.ebuild" ] && echo 1 || echo 0)" 0 \
    "不产生旧版本文件名"

case_name "overlay 缺 ebuild：装配失败（不静默）"
mkdir -p "$tmp/repo-empty/overlay/gui-apps/luciole" "$tmp/local-empty/gui-apps/luciole"
printf 'DIST none\n' > "$tmp/repo-empty/overlay/gui-apps/luciole/Manifest"
run_block "$tmp/repo-empty" "$tmp/local-empty"; rc=$?
assert_eq "$rc" 1 "缺 ebuild 时退出 1"

case_name "VM 镜像建 user.ordo 实例"
assert_active_line "$ROOT/dev/vm/configure-root.sh" \
    'ln -sfn /etc/init.d/user /etc/init.d/user.ordo' "建 user.ordo 软链"
assert_active_line "$ROOT/dev/vm/configure-root.sh" \
    'rc-update add user.ordo default' "注册 user.ordo 进 default runlevel"
assert_active_line "$ROOT/dev/vm/configure-root.sh" 'test -f /etc/init.d/user' \
    "模板缺失即失败（不静默跳过）"

finish
