#!/bin/sh
# 门禁：仓库里不得出现过程性产物
#
# 这个仓只放「系统是什么」，不放「我是怎么做出来的」。
# 过程性产物（工作日志、进度快照、评审记录、截图、团队内部文档）
# 对读者没有长期价值，且会迅速过时变成误导。
#
# 曾经出过的问题：
#   - docs/screenshots/ 51 个 PNG（35 个是调试迭代图，5 个是第三方素材）
#   - docs/status-*.md "供重启后新会话接续使用"
#   - docs/desktop-visual-progress.md "视觉复刻进度"
#   - docs/team/、docs/reviews/ 内部管理文档
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

case_name "禁止的目录不存在"

bad=""
for d in docs/screenshots docs/team docs/reviews docs/playbooks; do
    [ -e "$ROOT/$d" ] && bad="$bad $d"
done
assert_eq "$bad" "" "过程性目录已清除"

case_name "禁止的文件模式不存在"

bad=""
for pat in 'docs/status-*.md' 'docs/*progress*.md' 'docs/*breakthrough*.md' \
           'docs/install-notes.md' 'docs/user-dbus*.md' 'docs/*-2026-*.md'; do
    for f in "$ROOT"/$pat; do
        [ -e "$f" ] && bad="$bad $(basename "$f")"
    done
done
assert_eq "$bad" "" "没有日期命名的工作日志"

case_name "仓库里没有 PNG 截图"

# 例外：config/desktop/wallpapers/*.png 是运行时壁纸（swaybg 加载），不是截图
shots="$(cd "$ROOT" && git ls-files '*.png' 2>/dev/null | grep -v '^config/desktop/wallpapers/' || true)"
assert_eq "$shots" "" "除了运行时壁纸外没有图片"

case_name "文档标题里没有过程性措辞"

bad=""
for f in "$ROOT"/docs/*.md; do
    [ -f "$f" ] || continue
    # 标题（第一行）出现这些词 → 过程性文档
    head1="$(head -1 "$f")"
    case "$head1" in
        *进度*|*快照*|*实录*|*战役*|*接续*|*突破*|*复盘*)
            bad="$bad $(basename "$f")" ;;
    esac
done
assert_eq "$bad" "" "文档标题不含过程性措辞"

case_name "dev/ 只放可执行工具的源码，不放实验产物"

extra=""
for f in "$ROOT"/dev/*; do
    [ -e "$f" ] || continue
    case "$(basename "$f")" in
        gen-branding.sh|gen-wallpaper.py|build|m2|release|vm) ;;   # 构建期工具
        *) extra="$extra $(basename "$f")" ;;
    esac
done
assert_eq "$extra" "" "dev/ 没有实验 demo"

case_name "docs 下只剩三类内容"

# 允许：manual/（用户手册）、decisions/（ADR）、upstream/（上游材料）、design/（设计规范）、
#       deviations.md（偏离账本）
extra=""
for f in "$ROOT"/docs/*; do
    [ -e "$f" ] || continue
    case "$(basename "$f")" in
        manual|decisions|upstream|design|deviations.md) ;;
        *) extra="$extra $(basename "$f")" ;;
    esac
done
assert_eq "$extra" "" "docs/ 结构干净"

finish
