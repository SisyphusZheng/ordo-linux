#!/bin/sh
# L1 静态门禁：语法 + shellcheck + 配置文件解析
#
# 用法: tests/lint.sh
# 退出: 0 全绿 | 1 有问题 | 2 无法判定（有 skip 就不是通过）
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
# 根解析失败时（例如 POSIX 工具不全）不能继续用空路径跑出一片绿。
if [ ! -f config/world ] || [ ! -d scripts ]; then
    printf '!! 未找到仓库根（解析为 %s）\n' "$ROOT" >&2
    exit 1
fi

_n=0
_fail=0
_skip=0

pass() { printf '  ok   %s\n' "$*"; _n=$((_n + 1)); }
fail() { printf '  FAIL %s\n' "$*"; _fail=$((_fail + 1)); }
# skip 也是"无法判定"：必须计入 _skip，汇总不能输出绿勾（AGENTS.md：2 不是通过）
skip() { printf '  skip %s\n' "$*"; _skip=$((_skip + 1)); }

printf '== shell 语法 ==\n'
for f in install.sh scripts/* config/check-build config/verify-stage3 config/world.sh config/dataset config/arch config/desktop/ordo-session-env config/desktop/umbriel/ordo-*; do
    [ -f "$f" ] || continue
    case "$f" in *.md|*.png) continue ;; esac
    if sh -n "$f" 2>/dev/null; then
        pass "$f"
    else
        fail "${f}（sh -n 失败）"
    fi
done

printf '\n== shellcheck ==\n'
if command -v shellcheck >/dev/null 2>&1; then
    # 只跑 error+warning；style 建议不阻断
    _sc_out="$(shellcheck -S warning -f gcc scripts/* install.sh config/check-build config/verify-stage3 config/world.sh config/desktop/ordo-session-env config/desktop/umbriel/ordo-* 2>&1)"
    if [ -z "$_sc_out" ]; then
        pass "shellcheck（scripts/ + install.sh）"
    else
        printf '%s\n' "$_sc_out" | sed 's/^/       /'
        fail "shellcheck 有警告"
    fi
    # 用例不在上面的清单里：只跑 error 级，warning 级留给各自负责人清理。
    _sc_cases="$(shellcheck -S error -f gcc tests/cases/*.sh 2>&1)"
    if [ -z "$_sc_cases" ]; then
        pass "shellcheck（tests/cases，仅 error）"
    else
        printf '%s\n' "$_sc_cases" | sed 's/^/       /'
        fail "tests/cases 的 shellcheck error"
    fi
else
    skip "未安装 shellcheck（不当作通过）"
fi

printf '\n== 配置文件解析 ==\n'
# TOML
if command -v python3 >/dev/null 2>&1; then
    # 覆盖 config/ 下全部 TOML（含 greetd/config.toml —— 曾是门禁盲区）
    for f in $(find config -name '*.toml' -not -path '*/.git/*' 2>/dev/null) ; do
        [ -f "$f" ] || continue
        if python3 -c "import sys,tomllib;tomllib.load(open(sys.argv[1],'rb'))" "$f" 2>/dev/null; then
            pass "$f"
        else
            fail "${f}（TOML 解析失败）"
        fi
    done
else
    skip "无 python3，跳过 TOML 解析"
fi

# JSON
if command -v python3 >/dev/null 2>&1; then
    for f in $(find config/desktop -name '*.json' -not -path '*/.git/*' 2>/dev/null); do
        [ -f "$f" ] || continue
        if python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$f" 2>/dev/null; then
            pass "$f"
        else
            fail "${f}（JSON 解析失败）"
        fi
    done
else
    skip "无 python3，跳过 JSON 解析"
fi

# world 必须是裸 atom（无行内注释、无节标题残留）
printf '\n== 声明层格式 ==\n'
_bad_world="$(awk 'NF && $0 !~ /^[[:space:]]*#/ {
        if ($0 ~ /#/ || NF != 1) print NR": "$0
    }' config/world)"
if [ -z "$_bad_world" ]; then
    pass "config/world 是裸 atom 列表"
else
    printf '%s\n' "$_bad_world" | sed 's/^/       /'
    fail "config/world 含行内注释或多余字段"
fi

# package.use：每个包行必须紧跟至少一行注释（AGENTS.md「每行一个包，附原因」）。
# 包行 = 首列是 category/pkg 的行；裸包名（无 USE 值）本身也是违规——
# USE 文件里混包清单会让 install.sh 把包名当 USE 值塞给 Portage。
printf '\n== package.use 注释紧贴 ==\n'
if command -v python3 >/dev/null 2>&1; then
python3 - <<'PY'
import pathlib, re, sys
bad = []
for f in sorted(pathlib.Path("config/package.use").glob("*")):
    if not f.is_file():
        continue
    lines = f.read_text().splitlines()
    for i, line in enumerate(lines):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        first = s.split()[0]
        if "/" not in first:
            continue
        if not re.match(r"^[a-zA-Z0-9+_.-]+/[a-zA-Z0-9+_-]+$", first):
            continue
        # 裸包名（行内只有 atom，无 USE 值）
        if len(s.split()) == 1:
            bad.append(f"{f}:{i+1} 裸包名（USE 文件里只该有 USE 标志）: {first}")
            continue
        # 紧跟的下一行必须是注释
        nxt = lines[i+1].strip() if i+1 < len(lines) else ""
        if not nxt.startswith("#"):
            bad.append(f"{f}:{i+1} 包行缺紧跟注释: {first}")
if bad:
    for b in bad:
        print(f"       {b}")
    sys.exit(1)
sys.exit(0)
PY
    if [ $? -eq 0 ]; then
        pass "package.use 包行都有紧跟注释"
    else
        fail "package.use 注释规则违规"
    fi
else
    skip "无 python3，跳过 package.use 注释检查"
fi

# keys.md 与 umbriel [keybinds] 一致：keys.md 出现的每个 Mod+ 组合
# 都必须在 keybinds 里（方向箭头按 Left/Right/Up/Down 展开；
# 含 TODO 的行豁免；keys.md「已知限制」里描述为无效的键名不写 Mod+ 前缀）。
printf '\n== keys.md × keybinds 一致 ==\n'
if command -v python3 >/dev/null 2>&1; then
python3 - <<'PY'
import re, sys, tomllib, pathlib
root = pathlib.Path(".")
try:
    kb = tomllib.load(open(root / "config/desktop/umbriel/config.toml", "rb")).get("keybinds", {})
except Exception as e:
    print(f"       umbriel config.toml 解析失败: {e}")
    sys.exit(1)
text = "\n".join(l for l in (root / "config/desktop/keys.md").read_text().splitlines()
                 if "TODO" not in l)
arrow = {"←": "Left", "→": "Right", "↑": "Up", "↓": "Down"}
alias = {"Enter": "Return"}  # 键名规范：config 用 Return，keys.md 允许写 Enter
tok = re.compile(r"Mod\+([A-Za-z0-9←→↑↓]+(?:/[A-Za-z0-9←→↑↓]+)*(?:\+[A-Za-z0-9←→↑↓]+(?:/[A-Za-z0-9←→↑↓]+)*)*)")
required = set()
for m in tok.finditer(text):
    body = m.group(1)
    parts = body.split("+")
    alt_keys, mods = [], []
    for idx, part in enumerate(parts):
        if all(c in arrow for c in part) and part:
            alt_keys = list(part)               # ←→↑↓ 连写形态（同组修饰 × 多方向）
        elif idx == len(parts) - 1 and "/" in part:
            alt_keys = part.split("/")          # H/J/K 复选形态
        else:
            mods.append(part)
    if not alt_keys and mods:
        alt_keys = [mods.pop()]             # 末段即键名（Mod+S、Mod+Ctrl+L、Mod+Shift+1…）
    if not alt_keys:
        continue
    for k in alt_keys:
        key = alias.get(arrow.get(k, k), arrow.get(k, k))
        required.add("+".join(["Mod"] + mods + [key]))
missing = sorted(r for r in required if r not in kb)
# 反向校验：config 绑定了的 Mod+ 键，keys.md 也必须记载（XF86/无 Mod 修饰的键不在约束内）
extra = sorted(k for k in kb if k.startswith("Mod") and k not in required)
# 手册 03 的 Mod+ 组合也必须真实绑定：keys.md 与 03 都是面向用户的键位说明，
# 只核对 keys.md 会放过手册里的旧键（例如已改名的 Mod+Space）。
manual = root / "docs/manual/03-hotkeys.md"
if not manual.is_file():
    print("       缺少 docs/manual/03-hotkeys.md")
    sys.exit(1)
manual_required = set()
for m in tok.finditer(manual.read_text()):
    body = m.group(1)
    parts = body.split("+")
    alt_keys, mods = [], []
    for idx, part in enumerate(parts):
        if all(c in arrow for c in part) and part:
            alt_keys = list(part)
        elif idx == len(parts) - 1 and "/" in part:
            alt_keys = part.split("/")
        else:
            mods.append(part)
    if not alt_keys and mods:
        alt_keys = [mods.pop()]
    for k in alt_keys:
        key = alias.get(arrow.get(k, k), arrow.get(k, k))
        manual_required.add("+".join(["Mod"] + mods + [key]))
manual_missing = sorted(r for r in manual_required if r not in kb)
for miss in missing:
    print(f"       keys.md 有 {miss}，umbriel [keybinds] 未绑定")
for k in extra:
    print(f"       umbriel [keybinds] 有 {k}，keys.md 未记载")
for miss in manual_missing:
    print(f"       docs/manual/03-hotkeys.md 有 {miss}，umbriel [keybinds] 未绑定")
if missing or extra or manual_missing:
    sys.exit(1)
sys.exit(0)
PY
    if [ $? -eq 0 ]; then
        pass "keys.md 的 Mod+ 组合都在 [keybinds] 中"
    else
        fail "keys.md 与 keybinds 不一致"
    fi
else
    skip "无 python3，跳过 keys.md × keybinds 检查"
fi

# overlay 的 Manifest 必须随包入库：overlay/.gitignore 曾用
# `gui-apps/*/Manifest` 忽略新包的清单，新增覆盖包会静默丢校验文件。
printf '\n== overlay Manifest ==\n'
_bad_manifest=""
_n_manifest=0
for _d in overlay/gui-apps/*/; do
    [ -d "$_d" ] || continue
    _n_manifest=$((_n_manifest + 1))
    [ -f "$_d/Manifest" ] || _bad_manifest="$_bad_manifest ${_d}Manifest"
done
if [ -z "$_bad_manifest" ]; then
    pass "overlay/gui-apps 的 $_n_manifest 个包都带 Manifest"
else
    fail "overlay 包缺少 Manifest:$_bad_manifest"
fi

# 占位符：make.conf.example 的 @X@ 必须都能被 install.sh 替换
printf '\n== 模板占位符 ==\n'
_missing=""
for _ph in $(grep -o '@[A-Z_]*@' config/make.conf.example 2>/dev/null | sort -u); do
    grep -q -- "$_ph" install.sh || _missing="$_missing $_ph"
done
if [ -z "$_missing" ]; then
    pass "make.conf.example 的占位符都有对应的 sed 替换"
else
    fail "install.sh 未替换占位符:$_missing"
fi

printf '\n'
if [ "$_fail" -gt 0 ]; then
    printf '✘ %d 项失败（共 %d 项检查）\n' "$_fail" "$_n"
    [ "$_skip" -gt 0 ] && printf '? %d 项无法判定（不计入通过）\n' "$_skip"
    exit 1
fi
if [ "$_skip" -gt 0 ]; then
    printf '? %d 项无法判定（不计入通过）\n' "$_skip"
    exit 2
fi
printf '✔ %d 项检查全部通过\n' "$_n"
exit 0
