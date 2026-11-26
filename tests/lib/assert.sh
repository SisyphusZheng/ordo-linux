#!/bin/sh
# 测试断言（极简；不引外部框架）

_FAILS=0
_CASE=""

case_name() { _CASE="$1"; printf '\n== %s\n' "$1"; }

assert_eq() { # got expected label
    if [ "$1" = "$2" ]; then
        printf '  ok   %s\n' "${3:-值相等}"
    else
        printf '  FAIL %s\n    期望: %s\n    实际: %s\n' "${3:-值相等}" "$2" "$1"
        _FAILS=$((_FAILS + 1))
    fi
}

assert_contains() { # haystack needle label
    case "$1" in
        *"$2"*) printf '  ok   %s\n' "${3:-包含}" ;;
        *) printf '  FAIL %s\n    期望包含: %s\n    实际: %s\n' "${3:-包含}" "$2" "$1"
           _FAILS=$((_FAILS + 1)) ;;
    esac
}

assert_not_contains() { # haystack needle label
    case "$1" in
        *"$2"*) printf '  FAIL %s\n    不应包含: %s\n' "${3:-不包含}" "$2"
                _FAILS=$((_FAILS + 1)) ;;
        *) printf '  ok   %s\n' "${3:-不包含}" ;;
    esac
}

assert_rc() { # actual expected label
    assert_eq "$1" "$2" "${3:-退出码}"
}


assert_active_line() { # file needle label —— 必须存在一行既含 needle 又未被注释
    if grep -F -- "$2" "$1" 2>/dev/null | grep -qE -v '^[[:space:]]*#'; then
        printf '  ok   %s\n' "${3:-$2 未被注释}"
    else
        printf '  FAIL %s\n' "${3:-$2 未被注释}"
        _FAILS=$((_FAILS + 1))
    fi
}

finish() {
    if [ "$_FAILS" -gt 0 ]; then
        printf '\n✘ %d 个断言失败\n' "$_FAILS"
        exit 1
    fi
    printf '\n✔ 全部通过\n'
    exit 0
}
