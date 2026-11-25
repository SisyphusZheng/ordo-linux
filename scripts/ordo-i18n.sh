#!/bin/sh
# ordo-i18n.sh — 极简双语支持（无 gettext 依赖）
#
# 用法：
#   . ordo-i18n.sh
#   msg "中文" "English"
#
# 语言检测：$LANG / $LC_ALL / $LC_MESSAGES 的前两位
#   zh_* → 中文
#   其他 → 英文
#
# 设计理由（符合"薄"的公理）：
#   - 不需要 .po/.mo 构建链
#   - 每个字符串就地双语，可读性最好
#   - 新增语言只需扩 case 分支

ordo_lang() {
    _l="${LC_ALL:-${LC_MESSAGES:-${LANG:-en}}}"
    case "${_l}" in
        zh*) echo zh ;;
        *)   echo en ;;
    esac
}

msg() {
    # $1 = 中文, $2 = English
    if [ "$(ordo_lang)" = "zh" ]; then
        printf '%s\n' "$1"
    else
        printf '%s\n' "${2:-$1}"
    fi
}

# 无换行版本（用于 prompt）
msg_n() {
    if [ "$(ordo_lang)" = "zh" ]; then
        printf '%s' "$1"
    else
        printf '%s' "${2:-$1}"
    fi
}

# 错误输出到 stderr
err() {
    if [ "$(ordo_lang)" = "zh" ]; then
        printf '%s\n' "$1" >&2
    else
        printf '%s\n' "${2:-$1}" >&2
    fi
}
