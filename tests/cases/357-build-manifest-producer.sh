#!/bin/sh
# 回归：P1-02 构建清单只有 install.sh 生产
#
# 旧状态：写入点只有 install.sh 内的 heredoc；config/platform/m2/install-external.sh
# 与 dev/vm/configure-root.sh 都不产清单 —— M2/UTM 上 `ordo config verify`
# 拿不到期望值，恒 exit 2（无法判定）。
#
# 现在：scripts/ordo-build-manifest 是唯一生产者，三处构建路径共用同一格式。
# 用例既执行生成器（格式、路径视角、三态退出码），也断言三个调用点真实存在。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/scripts/lib.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ordo-build-manifest.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

root="$tmp/root"
mkdir -p "$root/opt/ordo/config/desktop/umbriel" \
         "$root/opt/ordo/config/platform/m2" \
         "$root/opt/ordo/config/apps.d" \
         "$root/opt/ordo/config/package.use" \
         "$root/opt/ordo/config/package.accept_keywords" \
         "$root/opt/ordo/config/package.mask" \
         "$root/usr/local/bin"
for rel in config/world config/world.sh config/world.bare-metal config/world.bare-metal.arm64 \
           config/arch config/dataset config/forbidden-world config/oneshot-packages \
           config/platform/m2/world.base config/platform/m2/world; do
    printf '%s\n' "$rel" > "$root/opt/ordo/$rel"
done
printf '0.1.0\n' > "$root/opt/ordo/version"
printf 'app/one\n' > "$root/opt/ordo/config/apps.d/00-core.list"
printf 'app/two -flag\n' > "$root/opt/ordo/config/package.use/50-fixture"
printf 'app/two ~arm64\n' > "$root/opt/ordo/config/package.accept_keywords/50-fixture"
printf 'app/bad\n' > "$root/opt/ordo/config/package.mask/50-fixture"
printf '#!/bin/sh\n' > "$root/opt/ordo/config/desktop/umbriel/ordo-umbriel-session"
printf '#!/bin/sh\n' > "$root/opt/ordo/config/desktop/ordo-session-env"
printf '#!/bin/sh\n' > "$root/opt/ordo/config/desktop/ffplay"
for _dst in ordo-umbriel-session ordo-session-env ffplay; do
    printf '#!/bin/sh\n' > "$root/usr/local/bin/$_dst"
done
manifest="$root/etc/ordo/build-manifest"

case_name "生成器写入完整清单（目标系统视角的路径）"
sh "$ROOT/scripts/ordo-build-manifest" "$root" bare-metal arm64 > "$tmp/out" 2>&1
assert_rc "$?" 0 "生成器退出 0"
assert_rc "$([ -f "$manifest" ] && echo 0 || echo 1)" 0 "清单写到 <安装根>/etc/ordo/build-manifest"
assert_eq "$(sed -n '1p' "$manifest")" "manifest_version 1" "首行是格式版本"
assert_eq "$(sed -n '2p' "$manifest")" "version 0.1.0" "version 取安装根里的唯一来源"
assert_eq "$(sed -n '3p' "$manifest")" "platform bare-metal" "记录平台"
assert_eq "$(sed -n '4p' "$manifest")" "arch arm64" "记录架构"
assert_contains "$(cat "$manifest")" "decl $(ordo_sha256 "$root/opt/ordo/version") /opt/ordo/version" \
    "decl 行摘要正确且路径是目标系统视角"
assert_contains "$(cat "$manifest")" '/opt/ordo/config/world.bare-metal.arm64' \
    "登记架构对应的 world.bare-metal 分片"
assert_contains "$(cat "$manifest")" '/opt/ordo/config/platform/m2/world.base' \
    "登记平台 world.base"
assert_contains "$(cat "$manifest")" '/opt/ordo/config/apps.d/00-core.list' \
    "登记首启应用清单"
assert_contains "$(cat "$manifest")" \
    "copy $(ordo_sha256 "$root/opt/ordo/config/desktop/umbriel/ordo-umbriel-session") /opt/ordo/config/desktop/umbriel/ordo-umbriel-session /usr/local/bin/ordo-umbriel-session" \
    "copy 行同时记录声明源与部署产物"
assert_eq "$(grep -c '^decl ' "$manifest")" 15 "登记了全部 15 份声明副本"
assert_eq "$(grep -c '^copy ' "$manifest")" 3 "登记了 3 个部署产物"
assert_not_contains "$(cat "$manifest")" "$root" "清单不泄漏安装根路径"

case_name "自定义清单路径与另一平台/架构"
sh "$ROOT/scripts/ordo-build-manifest" "$root" vm amd64 "$tmp/custom-manifest" >/dev/null 2>&1
assert_rc "$?" 0 "自定义路径可用"
assert_eq "$(sed -n '3p' "$tmp/custom-manifest")" "platform vm" "平台随参数"
assert_eq "$(sed -n '4p' "$tmp/custom-manifest")" "arch amd64" "架构随参数"

case_name "不可判定/缺声明按三态退出"
sh "$ROOT/scripts/ordo-build-manifest" "$tmp/absent" vm arm64 >/dev/null 2>&1
assert_rc "$?" 1 "安装根不存在 → 1"
sh "$ROOT/scripts/ordo-build-manifest" "$root" vm riscv >/dev/null 2>&1
assert_rc "$?" 1 "未知架构 → 1"
mkdir -p "$tmp/empty-root"
sh "$ROOT/scripts/ordo-build-manifest" "$tmp/empty-root" vm arm64 >/dev/null 2>&1
assert_rc "$?" 1 "缺 /opt/ordo/version → 1"
assert_rc "$([ -e "$tmp/empty-root/etc/ordo/build-manifest" ] && echo 1 || echo 0)" 0 \
    "失败时不留下半截清单"

case_name "三处构建路径都调用生成器"
assert_active_line "$ROOT/install.sh" \
    'sh /opt/ordo/scripts/ordo-build-manifest / "$ORDO_PLATFORM" "$ARCH"' \
    "install.sh 调用生成器（chroot 内）"
assert_active_line "$ROOT/config/platform/m2/install-external.sh" \
    'chroot "$TARGET" /bin/sh /opt/ordo/scripts/ordo-build-manifest / "$_manifest_platform" arm64' \
    "M2 外置安装调用生成器"
assert_active_line "$ROOT/dev/vm/configure-root.sh" \
    'sh "$repo/scripts/ordo-build-manifest" / "$(cat /etc/ordo/platform)" arm64' \
    "VM 装配调用生成器"
assert_rc "$([ -x "$ROOT/scripts/ordo-build-manifest" ] && echo 0 || echo 1)" 0 \
    "生成器可执行"

finish
