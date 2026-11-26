#!/bin/sh
# 回归：C6 查看器/默认关联/打印登记、C7 文档收口
#
# C6：可选应用清单、skel 的 mimeapps.list、打印/扫描的边界必须与实现一致；
# C7：02/05/08 与 README/CHANGELOG 记录本轮能力，08 指向 10 号手册的
#     掉盘/救援章节（不重复正文）。
set -eu
repo=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)
. "$repo/tests/lib/assert.sh"

case_name "C6 可选应用清单包含查看器"

opt="$(cat "$repo/config/apps.d/01-optional.list")"
for app in org.gnome.Papers org.gnome.Loupe io.mpv.Mpv; do
    assert_contains "$opt" "$app" "01-optional.list 含 ${app}"
done
# 必装清单不塞查看器：仍只有浏览器与商店。
core="$(cat "$repo/config/apps.d/00-core.list")"
assert_not_contains "$core" "org.gnome.Papers" "查看器不塞进 00-core"
assert_not_contains "$core" "io.mpv.Mpv" "播放器不塞进 00-core"

case_name "C6 skel 默认关联覆盖 PDF / 图片 / 视频"

mime="$(cat "$repo/config/desktop/skel/.config/mimeapps.list")"
assert_contains "$mime" "[Default Applications]" "有默认关联段"
assert_contains "$mime" "application/pdf=org.gnome.Papers.desktop" "PDF → Papers"
assert_contains "$mime" "image/png=org.gnome.Loupe.desktop" "PNG → Loupe"
assert_contains "$mime" "video/mp4=io.mpv.Mpv.desktop" "MP4 → mpv"
# 默认关联指向的 app 必须真的在可选清单里（否则打开文件会找不到应用）。
for pair in "application/pdf=org.gnome.Papers" "image/png=org.gnome.Loupe" "video/mp4=io.mpv.Mpv"; do
    _app="${pair#*=}"
    assert_contains "$opt" "$_app" "mimeapps 的 ${_app} 在可选清单里"
done

case_name "C6 打印/扫描边界写进 05 手册"

apps="$(cat "$repo/docs/manual/05-apps.md")"
assert_contains "$apps" "## 查看器与默认关联" "05 有查看器章节"
assert_contains "$apps" "org.gnome.Papers" "05 列出 Papers"
assert_contains "$apps" "io.mpv.Mpv" "05 列出 mpv"
assert_contains "$apps" "当前**不支持**打印与扫描" "05 登记打印/扫描边界"

case_name "C7 02/08 手册记录旧机迁移与跨手册引用"

first="$(cat "$repo/docs/manual/02-first-login.md")"
assert_contains "$first" "旧镜像升级后的一次性检查" "02 有一次性迁移章节"
assert_contains "$first" "mimeapps.list" "02 讲默认关联迁移"
trouble="$(cat "$repo/docs/manual/08-troubleshooting.md")"
assert_contains "$trouble" "10-m2-external.md" "08 指向 10 号手册"
assert_contains "$trouble" "外接盘掉线" "08 有掉盘排查入口（不重复正文）"
assert_contains "$trouble" "ordo-maintenance status" "08 有维护 cron 排查入口"
assert_contains "$trouble" "syslog 没跑" "08 有 syslog 排查入口"

case_name "C7 README 能力表与 CHANGELOG 记录本轮能力"

readme="$(cat "$repo/README.md")"
for cap in "ordo selfupdate" "ordo-maintenance" "ordo ssh" "ordo backup" \
           "cleanup-build" "桌面与运维能力"; do
    assert_contains "$readme" "$cap" "README 记录 ${cap}"
done
# README 的运维表不能把备份说成只发根数据集的单流。
assert_contains "$readme" "运行根 + \`/home\` 双流" "README 记录备份双流"

log="$(cat "$repo/CHANGELOG.md")"
_unreleased="$(printf '%s\n' "$log" | sed -n '/^## \[Unreleased\]/,/^## \[0.1.0\]/p')"
assert_contains "$_unreleased" "portals.conf" "CHANGELOG 记录门户配置"
assert_contains "$_unreleased" "mimeapps.list" "CHANGELOG 记录默认关联"
assert_contains "$_unreleased" "QT_IM_MODULE" "CHANGELOG 记录输入法收敛"
assert_contains "$_unreleased" "storage-key" "CHANGELOG 记录 storage-key 处置"

finish
