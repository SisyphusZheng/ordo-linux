#!/bin/sh
# Exercise the signature policy with GPG status and cleartext fixtures.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat > "$tmp/bin/gpg" <<'GPG'
#!/bin/sh
for arg in "$@"; do
    case "$arg" in
        --import|--recv-keys) exit 0 ;;
        --decrypt)
            printf '%s\n' "$SIGNATURE_STATUS" >&3
            printf '%s\n' "$DIGEST_LINE" > stage3.clear
            exit "${GPG_RC:-0}"
            ;;
    esac
done
exit 99
GPG
chmod +x "$tmp/bin/gpg"
export PATH="$tmp/bin:$PATH"

. "$ROOT/config/arch"
archive=stage3-fixture.tar.xz
hash=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
good_status="[GNUPG:] VALIDSIG AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 2026-01-01 0 0 4 0 1 8 01 $STAGE3_GPG_FINGERPRINT"

verify() {
    mkdir "$tmp/$1"
    SIGNATURE_STATUS="$2" DIGEST_LINE="$3" GPG_RC="${4:-0}" \
        sh "$ROOT/config/verify-stage3" "$tmp/$1" "$STAGE3_GPG_FINGERPRINT" "$archive"
}

case_name "只接受固定主钥认证、与预期归档绑定的摘要"
verify good "$good_status" "$hash  $archive"
assert_rc "$?" 0 "接受固定主钥的签名子钥"
assert_eq "$(cat "$tmp/good/stage3.verified")" "$hash  $archive" "输出仅包含预期文件的摘要"

verify wrong-signer "${good_status% *} BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB" "$hash  $archive"
assert_rc "$?" 1 "拒绝其他有效签名"
verify wrong-file "$good_status" "$hash  other.tar.xz"
assert_rc "$?" 1 "拒绝为其他归档签发的摘要"
verify unsigned '' "$hash  $archive"
assert_rc "$?" 1 "拒绝无签名摘要"
verify bad-signature "$good_status" "$hash  $archive" 1
assert_rc "$?" 1 "GPG 失败时中止"

finish
