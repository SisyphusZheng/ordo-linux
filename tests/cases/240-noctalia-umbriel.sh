#!/bin/sh
# 门禁：Noctalia / Umbriel 纳入套件
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

case_name "配置存在且可解析"

for f in config/desktop/noctalia/config.toml config/desktop/umbriel/config.toml; do
    assert_rc "$([ -f "$ROOT/$f" ] && echo 0 || echo 1)" 0 "$(basename "$f") 存在"
done

python3 - "$ROOT" <<'PY'
import sys, tomllib, pathlib
root = pathlib.Path(sys.argv[1])
ok = True
for f in ["config/desktop/noctalia/config.toml", "config/desktop/umbriel/config.toml"]:
    try:
        tomllib.load(open(root / f, "rb"))
    except Exception as e:
        print(f"  FAIL {f}: {e}")
        ok = False
sys.exit(0 if ok else 1)
PY
assert_rc "$?" 0 "两个 TOML 都能解析"

case_name "键位不重复（Umbriel 对重复键是硬错误）"

# 旧版只打印键位数，从不比较——是假断言。TOML 解析能抓字面重复键，
# 这里再抓语义重复：修饰键顺序不同（Shift+Mod+F vs Mod+Shift+F）是两个
# 不同的 TOML 键，但 Umbriel 视作同一绑定，后者静默覆盖前者。
python3 - "$ROOT" <<'PY'
import sys, tomllib, pathlib
root = pathlib.Path(sys.argv[1])
cfg = tomllib.load(open(root / "config/desktop/umbriel/config.toml", "rb"))
kb = cfg.get("keybinds", {})
print(f"  键位数: {len(kb)}")

def norm(k):
    parts = k.split("+")
    if len(parts) > 1:
        return "+".join(sorted(m.strip().lower() for m in parts[:-1]) + [parts[-1]])
    return k

seen = {}
dups = []
for k in kb:
    n = norm(k)
    if n in seen:
        dups.append((seen[n], k))
    else:
        seen[n] = k
for a, b in dups:
    print(f"  FAIL 语义重复键位: {a} 与 {b}")
sys.exit(1 if dups else 0)
PY
assert_rc "$?" 0 "keybinds 无重复键（含修饰键顺序不同的语义重复）"

case_name "不引用 niri 专属路径"

_um="$(cat "$ROOT/config/desktop/umbriel/config.toml")"
assert_not_contains "$_um" "NIRI_SOCKET" "Umbriel 配置不含 niri socket"
assert_not_contains "$_um" "niri msg" "Umbriel 配置不调用 niri 命令"

case_name "session 脚本共用环境初始化"

_se="$ROOT/config/desktop/ordo-session-env"
assert_rc "$([ -f "$_se" ] && echo 0 || echo 1)" 0 "ordo-session-env 存在"
assert_contains "$(cat "$_se")" "LIBSEAT_BACKEND" "修复 libseat 后端"
assert_contains "$(cat "$_se")" "dbus-daemon" "启动会话总线"

_us="$ROOT/config/desktop/umbriel/ordo-umbriel-session"
assert_contains "$(cat "$_us")" "ordo-session-env" "Umbriel session 复用它"
assert_contains "$(cat "$_us")" "start-umbriel" "启动 Umbriel"

case_name "全家桶五件套齐全"

for atom in gui-apps/noctalia gui-wm/umbriel gui-apps/luciole gui-apps/noctalia-greeter; do
    assert_contains "$(cat "$ROOT/config/world")" "$atom" "world 含 $atom"
done
# portal 不直接进 world：它由 umbriel 的 screencast USE 拉入
assert_rc "$([ -d "$ROOT" ] && echo 0 || echo 1)" 0 "portal 由 umbriel[screencast] 提供"

case_name "Luciole ebuild 存在且依赖正确"

_lc="$ROOT/overlay/gui-apps/luciole/luciole-0.1.0.ebuild"
assert_rc "$([ -f "$_lc" ] && echo 0 || echo 1)" 0 "luciole ebuild 存在"
_lct="$(cat "$_lc")"
# 这些包名踩过坑，写错会直接解析失败
assert_contains "$_lct" "app-arch/libarchive" "用 app-arch/ 而非 sys-libs/"
assert_contains "$_lct" "dev-build/meson" "用 dev-build/ 而非 dev-util/"
assert_contains "$_lct" "virtual/acl" "acl 走 virtual/"
# 上游无 tag，必须用快照 tarball
assert_contains "$_lct" "archive/" "用 archive/ 快照而非 tag"

case_name "greetd 指向 Noctalia Greeter"

_gt="$(cat "$ROOT/config/desktop/greetd/config.toml")"
assert_contains "$_gt" "noctalia-greeter-session" "greetd 调用 greeter 会话"

case_name "world 与 install.sh 一致"

_w="$(cat "$ROOT/config/world")"
assert_contains "$_w" "gui-apps/noctalia" "world 含 noctalia"
assert_contains "$_w" "gui-wm/umbriel" "world 含 umbriel"
_i="$(cat "$ROOT/install.sh")"
assert_contains "$_i" "ordo-session-env" "install.sh 部署环境脚本"
assert_contains "$_i" "ordo-umbriel-session" "install.sh 部署 umbriel session"

finish
