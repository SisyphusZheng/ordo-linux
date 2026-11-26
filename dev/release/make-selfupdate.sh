#!/bin/sh
# 生成 ordo-selfupdate 用的发布包：ordo-<version>.tar.gz + .sha256
#
# 内容 = /opt/ordo 的完整声明面（scripts/ config/ overlay/ version），
# 与安装器部署到 /opt/ordo 的目录结构一致，解包后可直接作为安装根。
#
# 用法：dev/release/make-selfupdate.sh [输出目录，默认 dev/build]
set -eu
here=$(dirname "$(readlink -f "$0")")
repo=$(cd "$here/../.." && pwd)
version=$(cat "$repo/version")
out=${1:-$repo/dev/build}
mkdir -p "$out"
stage=$(mktemp -d "${TMPDIR:-/tmp}/ordo-selfupdate.XXXXXX")
trap 'rm -rf "$stage"' EXIT
cp -R "$repo/scripts" "$repo/config" "$repo/overlay" "$repo/version" "$stage"/
tar czf "$out/ordo-$version.tar.gz" -C "$stage" .
if command -v sha256sum >/dev/null 2>&1; then
    (cd "$out" && sha256sum "ordo-$version.tar.gz") > "$out/ordo-$version.tar.gz.sha256"
else
    (cd "$out" && shasum -a 256 "ordo-$version.tar.gz") > "$out/ordo-$version.tar.gz.sha256"
fi
printf '已生成：%s\n' "$out/ordo-$version.tar.gz"
printf '摘要：%s\n' "$out/ordo-$version.tar.gz.sha256"
