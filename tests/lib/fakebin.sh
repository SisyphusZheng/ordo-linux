#!/bin/sh
# 测试辅助：在临时目录里造假命令，供用例塞进 PATH。
#
# 用法：
#   . "$(dirname "$0")/../lib/fakebin.sh"
#   d=$(mk_fakebin_dir)
#   mk_fake "$d" findmnt "rpool/root/ordo"
#   PATH="$d:$PATH"

mk_fakebin_dir() {
    mktemp -d "${TMPDIR:-/tmp}/ordo-fakebin.XXXXXX"
}

# mk_fake <dir> <name> [stdout] [exit-code]
mk_fake() {
    _dir="$1"; _name="$2"; _out="${3:-}"; _rc="${4:-0}"
    {
        printf '#!/bin/sh\n'
        printf "printf '%%s\\\\n' '%s'\n" "$_out"
        printf 'exit %s\n' "$_rc"
    } > "$_dir/$_name"
    chmod 755 "$_dir/$_name"
}
