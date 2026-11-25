# Copyright 2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

inherit meson

DESCRIPTION="A smooth, native Wayland file manager (Noctalia family)"
HOMEPAGE="https://noctalia.dev/files"
# 固定到 0.1.0 二进制包构建时采用的源码提交。
LUCIOLE_COMMIT="bae75c541ce1d863438d013f1f157b0db85e87df"
SRC_URI="https://github.com/noctalia-dev/luciole/archive/${LUCIOLE_COMMIT}.tar.gz -> ${P}-${LUCIOLE_COMMIT}.tar.gz"
S="${WORKDIR}/${PN}-${LUCIOLE_COMMIT}"

LICENSE="MIT"
SLOT="0"
KEYWORDS="~amd64 ~arm64"

RDEPEND="
	>=dev-cpp/nlohmann_json-3.11
	>=dev-cpp/tomlplusplus-3.4
	>=dev-libs/glib-2.76:2
	dev-libs/libxml2:2
	>=dev-libs/libsodium-1.0
	>=dev-libs/wayland-protocols-1.49
	>=gnome-base/librsvg-2.42:2
	media-libs/libpng
	>=net-misc/curl-7.85
	app-arch/libarchive
	app-arch/xz-utils
	virtual/acl
	x11-libs/cairo
	x11-libs/gdk-pixbuf:2
"
DEPEND="${RDEPEND}
	dev-libs/wayland
	media-libs/fontconfig
	media-libs/freetype
	media-libs/harfbuzz
"
BDEPEND="
	dev-build/meson
	dev-util/wayland-scanner
	virtual/pkgconfig
"

src_prepare() {
	default
	[ -f "${S}/VERSION" ] || echo "0.1.0" > "${S}/VERSION"
}

src_configure() {
	local emesonargs=(
		-Dtests=disabled
		-Dbenchmarks=false
	)
	meson_src_configure
}
