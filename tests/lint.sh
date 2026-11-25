#!/bin/sh
# L1 静态门禁：语法 + shellcheck + 配置文件解析
#
# 用法: tests/lint.sh
# 退出: 0 全绿 | 1 有问题
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

_n=0
_fail=0

pass() { printf '  ok   %s\n' "$*"; _n=$((_n + 1)); }
fail() { printf '  FAIL %s\n' "$*"; _fail=$((_fail + 1)); }
skip() { printf '  skip %s\n' "$*"; }

printf '== shell 语法 ==\n'
for f in install.sh scripts/* config/check-build config/verify-stage3 config/world.sh config/desktop/ordo-session-env config/desktop/umbriel/ordo-*; do
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
    for f in config/desktop/**/*.json; do
        [ -f "$f" ] || continue
        if python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$f" 2>/dev/null; then
            pass "$f"
        else
            fail "${f}（JSON 解析失败）"
        fi
    done
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
for miss in missing:
    print(f"       keys.md 有 {miss}，umbriel [keybinds] 未绑定")
for k in extra:
    print(f"       umbriel [keybinds] 有 {k}，keys.md 未记载")
if missing or extra:
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
    exit 1
fi
printf '✔ %d 项检查全部通过\n' "$_n"
exit 0
