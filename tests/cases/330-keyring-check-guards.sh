#!/bin/sh
# 回归：keyring-policy.sh check 的「缺 libsecret」「残留 prompter」两处假绿灯
#
# 旧版：
#   1) `portageq has_version / app-crypt/libsecret::local` 是裸命令，set -e 下
#      缺包直接退出 1 且没有任何输出 —— 安装器只能报无关提示；
#   2) 激活文件清单漏掉 org.gnome.keyring.{Private,System}Prompter.service，
#      serial.log 里两者都在，check 却仍返回 0。
set -eu
repo=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)
. "$repo/tests/lib/assert.sh"
scratch=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/services" "$scratch/pam" "$scratch/autostart" "$scratch/none"

# 被测脚本副本：把绝对路径改到 scratch，其余逐字保留。
sed -e "s|/usr/share/dbus-1/services|$scratch/services|g" \
    -e "s|/etc/pam.d/greetd|$scratch/pam/greetd|g" \
    -e "s|/etc/xdg/autostart|$scratch/autostart|g" \
    -e "s|/usr/bin/gnome-keyring|$scratch/none/gnome-keyring|g" \
    -e "s|/lib\*/security|$scratch/none/lib*/security|g" \
    -e "s|/usr/lib\*/security|$scratch/none/usrlib*/security|g" \
    "$repo/config/desktop/keyring-policy.sh" > "$scratch/policy.sh"

portageq_stub() { # libsecret_rc
    cat > "$scratch/bin/portageq" <<EOF
#!/bin/sh
case "\$*" in
    *app-crypt/libsecret::local*) exit $1 ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$scratch/bin/portageq"
}

_rc=0
_out=""
run_check() {
    _rc=0
    _out=$(PATH="$scratch/bin:$PATH" sh "$scratch/policy.sh" check 2>&1) || _rc=$?
}

case_name "缺 libsecret：点名缺的包，不是静默退出"

portageq_stub 1
run_check
assert_rc "$_rc" 1 "缺客户端库返回 1"
assert_contains "$_out" "缺少 app-crypt/libsecret::local" "说明缺的是哪个包"

case_name "portageq 自身异常：返回 2（三态）"

portageq_stub 2
run_check
assert_rc "$_rc" 2 "无法判定返回 2"
assert_contains "$_out" "无法判定" "明确标注无法判定"

case_name "残留 PrivatePrompter：check 必须失败"

portageq_stub 0
: > "$scratch/services/org.gnome.keyring.PrivatePrompter.service"
run_check
assert_rc "$_rc" 1 "残留 prompter 返回 1"
assert_contains "$_out" "org.gnome.keyring.PrivatePrompter.service" "点名残留文件"
rm -f "$scratch/services/org.gnome.keyring.PrivatePrompter.service"

case_name "残留 SystemPrompter：check 必须失败"

: > "$scratch/services/org.gnome.keyring.SystemPrompter.service"
run_check
assert_rc "$_rc" 1 "另一个 prompter 也要拦住"
assert_contains "$_out" "org.gnome.keyring.SystemPrompter.service" "点名残留文件"

case_name "清理干净后通过（不误报）"

rm -f "$scratch/services/org.gnome.keyring.SystemPrompter.service"
run_check
assert_rc "$_rc" 0 "无残留返回 0"
assert_eq "$_out" "" "通过时不输出噪音"

case_name "install.sh 真的调用 keyring 策略"
assert_active_line "$repo/install.sh" 'keyring-policy.sh" configure' "安装前调用 configure"
assert_active_line "$repo/install.sh" 'keyring-policy.sh" remove' "安装后调用 remove"

finish
