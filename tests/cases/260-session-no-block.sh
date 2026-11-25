#!/bin/sh
# 回归：会话入口不得被前台阻塞的命令卡住
#
# 实测事故（2026-11-23）：ordo-umbriel-session 以 `if ! gentoo-pipewire-launcher`
# 同步调用启动音频栈，而该脚本末尾是 `exec /usr/bin/wireplumber`，永远不返回。
# 结果：greetd 登录后黑屏卡死，会话 shell 停在 do_wait，子进程只剩 wireplumber，
# 最后一行的 `exec start-umbriel` 从未执行。
#
# 判据：会话脚本里出现的任何「启动即阻塞」类命令必须带 & 后台化。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

SESSIONS="config/desktop/umbriel/ordo-umbriel-session"

case_name "会话脚本存在"

for f in $SESSIONS; do
    assert_rc "$([ -f "$ROOT/$f" ] && echo 0 || echo 1)" 0 "$(basename "$f") 存在"
done

case_name "音频启动器必须后台化"

# gentoo-pipewire-launcher 的末行是 exec wireplumber（永不自退）。
# 允许的写法：`gentoo-pipewire-launcher ... &`（结尾是后台操作符）
# 禁止的写法：出现在 if/while 条件里，或行尾不是 &
# 注意：不能简单匹配 `&`——`2>&1` 里也有 &，会造成漏判（本用例第一版就栽在这）。
bad=""
for f in $SESSIONS; do
    [ -f "$ROOT/$f" ] || continue
    while IFS= read -r line; do
        case "$line" in
            \#*) continue ;;
            *gentoo-pipewire-launcher*)
                # 剥掉重定向记号，再去掉行尾空白，末字符必须是 &
                clean=$(printf '%s' "$line" | sed 's/[0-9]*>&[0-9-]*//g; s/>&[0-9-]*//g')
                clean=${clean%"${clean##*[! ]}"}
                case "$clean" in
                    *'&') : ;;
                    *) bad="$bad $(basename "$f"):$line" ;;
                esac
                ;;
        esac
    done < "$ROOT/$f"
done
assert_eq "$bad" "" "gentoo-pipewire-launcher 都带 & 后台运行"

case_name "会话以 exec 合成器收尾"

# 最后一条可执行语句必须是 exec start-umbriel，否则 greetd 等不到会话进程
last=""
for f in $SESSIONS; do
    [ -f "$ROOT/$f" ] || continue
    last=$(grep -vE '^[[:space:]]*(#|$)' "$ROOT/$f" | tail -1)
done
assert_contains "$last" "exec start-umbriel" "末行 exec 合成器"
