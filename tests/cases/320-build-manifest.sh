#!/bin/sh
# 回归：P1-02 verify 必须读「构建清单」，不能用运行机 /opt/ordo 旧副本自证
#
# 曾经：scripts/ordo-config verify 拿 /opt/ordo/config 的声明与由它自己
# 派生出的 /etc/portage/sets/ordo-core 比 —— 两边同源，恒绿。镜像里
# world 少 4 个 atom、会话脚本 1777B（仓库 1456B）、version 三处不一致，
# verify 照样「配置与系统完全一致」。
#
# 现在：install.sh 装机时写 /etc/ordo/build-manifest（逐文件 sha256），
# verify 只认这份清单；清单缺失 = 无法判定（退出码 2），不是通过。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ordo-manifest.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# 取生产函数的原文（与 040 用同一手法），不复制规则
sed -n '/^_manifest_field()/,/^}/p; /^_verify_build_manifest()/,/^}/p' \
    "$ROOT/scripts/ordo-config" > "$tmp/functions.sh"
n_funcs="$(grep -c '^_manifest_field()\|^_verify_build_manifest()' "$tmp/functions.sh")"
assert_eq "$n_funcs" 2 "生产脚本提供了构建清单检查函数"

# lib.sh 的摘要helper：Linux/macOS 都要能算 sha256
. "$ROOT/scripts/lib.sh"
_sha_want="$(shasum -a 256 "$ROOT/version" 2>/dev/null | awk '{print $1}')"
assert_eq "$(ordo_sha256 "$ROOT/version")" "$_sha_want" "ordo_sha256 与 shasum 口径一致"

# 隔离环境：清单路径由 lib.sh 的 ORDO_BUILD_MANIFEST 决定（可覆盖）
ORDO_BUILD_MANIFEST="$tmp/build-manifest"
ORDO_ROOT="$tmp/install-root"
mkdir -p "$ORDO_ROOT"
printf '9.9.9\n' > "$ORDO_ROOT/version"

. "$tmp/functions.sh"

n_bad=0
n_skip=0
n_ok=0
bad_inc()  { n_bad=$((n_bad + 1)); }
skip_inc() { n_skip=$((n_skip + 1)); }
ok()       { n_ok=$((n_ok + 1)); }
info()     { :; }

case_name "清单缺失 → 无法判定（不是通过）"
_verify_build_manifest
assert_eq "$n_skip" 1 "缺清单计入 skip"
assert_eq "$n_bad" 0 "缺清单不报问题"

case_name "版本三处不一致要红"
n_bad=0; n_skip=0; n_ok=0
printf 'a\n' > "$tmp/decl-a"
printf 'manifest_version 1\nversion 0.1.0\ndecl %s %s\n' \
    "$(ordo_sha256 "$tmp/decl-a")" "$tmp/decl-a" > "$ORDO_BUILD_MANIFEST"
_verify_build_manifest
assert_eq "$n_bad" 1 "装机 version 与清单 version 不一致时报问题"

case_name "声明副本被改（旧构建副本）要红"
n_bad=0; n_skip=0; n_ok=0
printf '9.9.9\n' > "$ORDO_ROOT/version"
printf 'manifest_version 1\nversion 9.9.9\ndecl %s %s\n' \
    "0000000000000000000000000000000000000000000000000000000000000000" "$tmp/decl-a" \
    > "$ORDO_BUILD_MANIFEST"
_verify_build_manifest
assert_eq "$n_bad" 1 "摘要不符的声明副本报问题"

case_name "缺失的声明副本要红"
n_bad=0; n_skip=0; n_ok=0
printf 'manifest_version 1\nversion 9.9.9\ndecl %s %s\n' \
    "0000000000000000000000000000000000000000000000000000000000000000" "$tmp/nonexistent" \
    > "$ORDO_BUILD_MANIFEST"
_verify_build_manifest
assert_eq "$n_bad" 1 "缺失的声明副本报问题"

case_name "全部一致时给 ok，不报问题"
n_bad=0; n_skip=0; n_ok=0
printf 'session\n' > "$tmp/session"
printf 'manifest_version 1\nversion 9.9.9\n' > "$ORDO_BUILD_MANIFEST"
printf 'decl %s %s\n' "$(ordo_sha256 "$tmp/decl-a")" "$tmp/decl-a" >> "$ORDO_BUILD_MANIFEST"
printf 'copy %s %s %s\n' "$(ordo_sha256 "$tmp/session")" "$tmp/decl-a" "$tmp/session" \
    >> "$ORDO_BUILD_MANIFEST"
_verify_build_manifest
assert_eq "$n_bad" 0 "一致时不报问题"
assert_eq "$n_ok" 1 "一致时给出通过项"

case_name "部署产物与声明不一致要红（会话脚本 1777B 那类）"
n_bad=0; n_skip=0; n_ok=0
printf 'tampered\n' > "$tmp/session"
_verify_build_manifest
assert_eq "$n_bad" 1 "摘要不符的部署产物报问题"

case_name "构建清单的生产者抽到 scripts/ordo-build-manifest"
_install="$(cat "$ROOT/install.sh")"
_generator="$(cat "$ROOT/scripts/ordo-build-manifest" 2>/dev/null)"
assert_contains "$_generator" "printf 'manifest_version 1" "生成器写格式版本"
assert_contains "$_generator" "printf 'version %s\\n'" "生成器的 version 取自安装根的 /opt/ordo/version"
assert_contains "$_generator" 'config/world config/world.sh' "清单覆盖 world 声明"
assert_contains "$_generator" '/usr/local/bin/ordo-umbriel-session' "清单覆盖部署的会话脚本"
assert_contains "$_generator" 'ordo_sha256' "清单用 sha256 摘要"
assert_contains "$_install" '/opt/ordo/scripts/ordo-build-manifest' "install.sh 调用生成器"
assert_contains "$_install" '/etc/ordo/build-manifest' "安装器仍写 /etc/ordo/build-manifest"

case_name "镜像构建器也产清单（M2 外置安装 / VM 装配）"
assert_active_line "$ROOT/install.sh" \
    'sh /opt/ordo/scripts/ordo-build-manifest / "$ORDO_PLATFORM" "$ARCH"' \
    "install.sh 调用生成器"
assert_active_line "$ROOT/config/platform/m2/install-external.sh" \
    'chroot "$TARGET" /bin/sh /opt/ordo/scripts/ordo-build-manifest / "$_manifest_platform" arm64' \
    "M2 外置安装调用生成器"
assert_active_line "$ROOT/dev/vm/configure-root.sh" \
    'sh "$repo/scripts/ordo-build-manifest" / "$(cat /etc/ordo/platform)" arm64' \
    "VM 装配调用生成器"
case_name "verify 把清单检查接进主流程"
_conf="$(cat "$ROOT/scripts/ordo-config")"
assert_contains "$_conf" '[0] 构建清单' "verify 有构建清单段"
assert_active_line "$ROOT/scripts/ordo-config" "    _verify_build_manifest" "verify 主流程调用构建清单（不是注释）"
assert_contains "$_conf" '_verify_build_manifest' "verify 调用清单检查"
assert_contains "$_conf" 'ORDO_BUILD_MANIFEST' "清单路径来自 lib.sh（可覆盖）"
assert_contains "$(cat "$ROOT/scripts/lib.sh")" 'ORDO_BUILD_MANIFEST' "lib.sh 定义清单路径"

finish
