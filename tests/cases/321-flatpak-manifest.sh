#!/bin/sh
# 回归：P1-04 首启 Flatpak 链 —— root 装 remote、--user 装应用、apps.d 行内注释
#
# 三处断点（审计原文）：
#   1) install.sh 的 `flatpak remote-add` 没有 --user → remote 落在**系统**仓库，
#      而应用装到 --user（root 的 --user 是 /root/.local/share/flatpak）→ 首启无应用。
#   2) `config/apps.d/00-core.list` 的行带行尾理由，安装器只跳过 `#` 开头的行，
#      整行 `org.mozilla.firefox   # 浏览器` 被当成 app id。
#   3) 迁移脚本同样只跳 `#`，且以 root 执行 `--user` 安装。
#
# 本用例**真跑**安装器第 15 段的清单消费逻辑（假 flatpak/su/id），
# 断言它请求安装的恰好是清单里的 app id —— 不是只对文本做字符串检查。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ordo-flatpak.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# 假 flatpak：把请求的参数逐行记下来
cat > "$tmp/bin/flatpak" <<'FAKE'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_FLATPAK_LOG"
FAKE
# 假 su：忽略选项，把 -c 后面的命令按 sh 跑（模拟以桌面用户身份执行）
cat > "$tmp/bin/su" <<'FAKE'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    case "$1" in
        -c) shift; cmd=$1; shift ;;
        *) shift ;;
    esac
done
[ -n "${cmd:-}" ] || exit 1
sh -c "$cmd"
FAKE
# 假 id：`id -u <用户>` 恒成立（测试机没有 ordo 用户）
cat > "$tmp/bin/id" <<'FAKE'
#!/bin/sh
case "${1:-}" in
    -u) exit 0 ;;
    *) exec /usr/bin/id "$@" ;;
esac
FAKE
chmod +x "$tmp/bin/flatpak" "$tmp/bin/su" "$tmp/bin/id"
export PATH="$tmp/bin:$PATH"
export FAKE_FLATPAK_LOG="$tmp/flatpak.log"
: > "$FAKE_FLATPAK_LOG"

case_name "install.sh 的清单解析：剥行内注释后取第一列"
parse="$(sed -n '/^flatpak_apps_of()/,/^}/p' "$ROOT/install.sh")"
assert_rc "$([ -n "$parse" ] && echo 0 || echo 1)" 0 "install.sh 提供统一的清单解析函数"
eval "$parse"
# 夹具：与 config/apps.d 同格式，覆盖行内注释、纯注释、空行、缩进
cat > "$tmp/fixture.list" <<'LIST'
# 注释行
org.mozilla.firefox          # 浏览器（默认）
   io.github.flattool.Warehouse   # 商店

org.gnome.TextEditor   #编辑器
LIST
assert_eq "$(flatpak_apps_of "$tmp/fixture.list" | tr '\n' ' ')" \
    "org.mozilla.firefox io.github.flattool.Warehouse org.gnome.TextEditor " \
    "行内注释被剥掉，只保留 app id"

case_name "install.sh 第 15 段：真跑消费逻辑，请求的就是清单里的 app"
# 取安装器第 15 段原文（改前/改后同样的抽取范围），把清单目录换成仓库的真实声明
sed -n '/^# ---- 15) Flatpak 应用清单/,/^# ---- 16)/p' "$ROOT/install.sh" \
    | sed "s|/opt/ordo/config/apps.d|$ROOT/config/apps.d|g" > "$tmp/section.sh"
say()  { :; }
warn() { :; }
. "$tmp/section.sh"

assert_rc "$?" 0 "第 15 段执行成功"

_log="$(cat "$FAKE_FLATPAK_LOG")"
app_ids="$(printf '%s\n' "$_log" | awk '$1 == "install" { print $NF }' | sort -u)"
assert_contains "$_log" "remote-add --user" "remote 加在用户作用域（--user）"
assert_eq "$app_ids" "io.github.flattool.Warehouse
org.mozilla.firefox" "安装的 app id 恰好是 00-core 的两条"
assert_not_contains "$_log" "#" "没有把行尾理由当 app id"
assert_not_contains "$_log" "Chrome" "01-optional 不自动安装"
assert_not_contains "$_log" "浏览器" "没有把中文理由传给 flatpak"
for _line in $(printf '%s\n' "$_log" | grep ' install '); do
    assert_contains "$_line" "--user" "安装走 --user：$_line"
done

case_name "迁移脚本与安装器同一口径、同一作用域"
_mig="$ROOT/config/migrations/1763701300-install-apps-manifest.sh"
_mig_parse="$(sed -n '/^flatpak_apps_of()/,/^}/p' "$_mig")"
assert_rc "$([ -n "$_mig_parse" ] && echo 0 || echo 1)" 0 "迁移脚本有清单解析函数"
eval "$_mig_parse"
assert_eq "$(flatpak_apps_of "$tmp/fixture.list" | wc -l | tr -d ' ')" "3" \
    "迁移解析可执行"
assert_eq "$(flatpak_apps_of "$tmp/fixture.list" | tr '\n' ' ')" \
    "$(printf '%s\n' 'org.mozilla.firefox io.github.flattool.Warehouse org.gnome.TextEditor ')" \
    "迁移脚本与安装器解析结果一致"
assert_contains "$(cat "$_mig")" 'su -s /bin/sh - "$DESKTOP_USER"' "迁移以桌面用户身份执行"
assert_contains "$(cat "$_mig")" 'remote-add --user' "迁移先建用户级 remote"

case_name "根因回归：旧的 root 作用域与整行当 id 的写法已消失"
_install="$(cat "$ROOT/install.sh")"
assert_not_contains "$_install" 'flatpak remote-add --if-not-exists flathub \
    https://flathub.org/repo/flathub.flatpakrepo \' "不再以 root 加系统级 remote"
assert_not_contains "$_install" "case \"\$_app\" in ''|\\\\#*)" "不再只跳 # 开头的行"
assert_not_contains "$(cat "$_mig")" "case \"\$_app\" in ''|\\\\#*)" "迁移不再只跳 # 开头的行"

finish
