#!/bin/sh
# lib.sh — ordo 脚本公共辅助（只放共享机制，保持薄）
#
# 入口脚本须先解软链再 source 本文件（安装后入口软链在 /usr/local/bin）：
#   _self="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
#   . "$(dirname "$_self")/lib.sh"

set -u

ordo_m2_boot() {
    [ ! -e /proc/device-tree/chosen/asahi,efi-system-partition ] || return 0
    [ -r /etc/ordo/platform ] || return 1
    case "$(cat /etc/ordo/platform)" in
        m2|m2-native) return 0 ;;
        *) return 1 ;;
    esac
}

# 退出码：0 通过 / 1 有问题 / 2 无法判定。2 不等于通过。
# shellcheck disable=SC2034  # 供 source 本文件的脚本使用
ORDO_EXIT_OK=0
# shellcheck disable=SC2034
ORDO_EXIT_BAD=1
# shellcheck disable=SC2034
ORDO_EXIT_UNKNOWN=2

# 脚本真实所在目录（解软链）
ordo_self_dir() {
    _o_self="$1"
    _o_real="$(readlink -f "$_o_self" 2>/dev/null || true)"
    [ -n "$_o_real" ] || _o_real="$_o_self"
    dirname "$_o_real"
}

# 仓库/安装根：脚本目录的上一级（scripts/ → 根）
ORDO_ROOT="$(cd "$(ordo_self_dir "$0")/.." && pwd)"
export ORDO_ROOT

# 数据集布局：config/dataset 提供**默认值**，运行时以实际挂载为准
# 查找顺序: $ORDO_CONFIG > /etc/ordo/dataset（已安装副本）> 仓库内 config/
if [ -n "${ORDO_CONFIG:-}" ] && [ -r "$ORDO_CONFIG" ]; then
    # shellcheck disable=SC1090  # 路径在运行时决定
    . "$ORDO_CONFIG"
elif [ -r /etc/ordo/dataset ]; then
    # shellcheck disable=SC1091
    . /etc/ordo/dataset
elif [ -r "$ORDO_ROOT/config/dataset" ]; then
    # shellcheck disable=SC1090
    . "$ORDO_ROOT/config/dataset"
else
    POOL="${POOL:-rpool}"
    DATASET="${DATASET:-$POOL/root/ordo}"
    HOME_DATASET="${HOME_DATASET:-$POOL/home}"
fi

export POOL DATASET HOME_DATASET

# 构建清单：install.sh 在装机结束前逐文件写下「声明副本 + 部署产物」的 sha256。
# verify 的期望值只认这份清单 —— 拿运行机 /opt/ordo 里的旧副本自证，
# 等于让装机副本给自己判卷（P1-02）。清单缺失 = 无法判定，不是通过。
ORDO_BUILD_MANIFEST="${ORDO_BUILD_MANIFEST:-/etc/ordo/build-manifest}"
export ORDO_BUILD_MANIFEST

# sha256 摘要：Linux 用 sha256sum，BSD/macOS 用 shasum，再退回 openssl。
# 三者都不可用时返回 2 —— 调用方必须把它当「无法判定」，不得当通过。
ordo_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    else
        return 2
    fi
}

# 运行时根数据集。
# 回滚后系统运行在 clone 上，此时 DATASET 指向的是未运行的旧系统。
# 快照与属性操作的对象必须是 RUNNING_ROOT，不是 DATASET。

detect_running_root() {
    # findmnt 是 util-linux 提供的标准工具，输出形如 rpool/root/ordo
    # 只能识别 ZFS 根；非 ZFS / 工具缺失返回空（调用方必须能区分这两种情况）
    command -v findmnt >/dev/null 2>&1 || return 0
    _src="$(findmnt -no SOURCE / 2>/dev/null || true)"
    case "$_src" in
        # 只认 "pool/dataset[@snap]"：/dev/sda1 也含 /，必须先排除设备路径
        /dev/*) : ;;
        */*)
            # 再用 zfs 二次确认（避免把非 ZFS 的 "overlay/..." 当成数据集）。
            # zfs 不在时退回形状判断（开发机 / 容器）。
            if command -v zfs >/dev/null 2>&1; then
                zfs list -H -o name "$_src" >/dev/null 2>&1 && printf '%s\n' "$_src"
            else
                printf '%s\n' "$_src"
            fi
            ;;
        *) : ;;
    esac
}

RUNNING_ROOT="$(detect_running_root)"
# 兜底：识别不出来时用配置值（非 ZFS 环境或 findmnt 不可用）
[ -n "$RUNNING_ROOT" ] || RUNNING_ROOT="$DATASET"
export RUNNING_ROOT

# 构建/验收期的测试 BE：由 config/dataset 的 TEST_BE 显式登记。
# 它是声明的身份，不是回滚 clone —— ordo snap 不该提示 promote/rename。
is_test_be() {
    [ -n "${TEST_BE:-}" ] && [ "$RUNNING_ROOT" = "$TEST_BE" ]
}

# 构建/验收期的临时数据集：config/dataset 的 BUILD_DATASETS（空格分隔 glob）。
# 命中 = 可销毁的构建残留，不属于发行布局。
ordo_is_ephemeral_dataset() { # dataset
    _odo_ds=$1
    if [ -n "${TEST_BE:-}" ] && [ "$_odo_ds" = "$TEST_BE" ]; then
        return 0
    fi
    # 故意不加引号：BUILD_DATASETS 是 glob 列表，不是单个路径。
    # shellcheck disable=SC2086,SC2254
    for _odo_pat in ${BUILD_DATASETS:-}; do
        case "$_odo_ds" in $_odo_pat) return 0 ;; esac
    done
    return 1
}

# 当前是否运行在「非规范」数据集上（回滚后的 clone）。
# 声明的测试 BE 不算回滚：它没有 clone 依赖，也没有可 promote 的源快照。
is_rolled_back_env() {
    [ "$RUNNING_ROOT" != "$DATASET" ] || return 1
    if is_test_be; then
        return 1
    fi
    return 0
}

# 给用户看的身份提示（只在漂移时输出，避免噪音）
warn_if_identity_drift() {
    if is_rolled_back_env; then
        printf '注意：当前运行于 %s（非规范数据集 %s）\n' "$RUNNING_ROOT" "$DATASET" >&2
        printf 'Note: running on %s (canonical dataset is %s)\n' "$RUNNING_ROOT" "$DATASET" >&2
    fi
}

# 策略数据目录：已安装系统用 /etc/ordo，开发环境用仓库 config/
# 安装后配置在 /etc/ordo；开发时在仓库的 config/。
# 判据不能只看目录存在 —— 旧版本可能留下只有几个文件的 /etc/ordo，
# 导致 apply/verify 找不到 desktop/ 子目录。要求关键子目录存在才算安装态。
if ordo_m2_boot && [ -d "$ORDO_ROOT/config/desktop" ]; then
    CONF_DIR="$ORDO_ROOT/config"
elif [ -d /etc/ordo/desktop ] || [ -d /etc/ordo/manual ]; then
    CONF_DIR="/etc/ordo"
elif [ -d /etc/ordo ]; then
    # /etc/ordo 存在但不完整（旧安装残留）：优先用仓库/安装目录的 config
    if [ -d "$ORDO_ROOT/config/desktop" ]; then
        CONF_DIR="$ORDO_ROOT/config"
    else
        CONF_DIR="/etc/ordo"
    fi
else
    CONF_DIR="$ORDO_ROOT/config"
fi
export CONF_DIR

# 必需工具检查。受限 PATH 下缺失时直接 exit 2，避免带半截结论继续执行。
ordo_require_tools() {
    _missing=""
    for _t in "$@"; do
        command -v "$_t" >/dev/null 2>&1 || _missing="$_missing $_t"
    done
    if [ -n "$_missing" ]; then
        printf '!! 缺少必需命令:%s\n' "$_missing" >&2
        printf '   本脚本无法在任何环境下给出可信结论（退出码 2=无法判定）\n' >&2
        exit "$ORDO_EXIT_UNKNOWN"
    fi
}

# ---------------------------------------------------------------------------
# 通用输出（统一措辞，避免每个脚本各写一套）
# ---------------------------------------------------------------------------
ordo_say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
ordo_ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
ordo_warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
ordo_bad()  { printf '  \033[31m✘\033[0m %s\n' "$*" >&2; }
ordo_die()  { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit "${ORDO_EXIT_BAD}"; }

# require_root [命令说明...] — 说明会拼进提示，不传则用脚本名。
require_root() {
    [ "$(id -u)" -eq 0 ] && return 0
    if [ "$#" -gt 0 ]; then
        printf '需要 root：doas %s\n' "$*" >&2
    else
        printf '需要 root：doas %s\n' "${ORDO_SELF_NAME:-$0}" >&2
    fi
    exit "$ORDO_EXIT_BAD"
}
