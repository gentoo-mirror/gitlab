# Copyright 1999-2017 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2

EAPI=6

DESCRIPTION="Manages multiple gitlab-gitaly versions"
HOMEPAGE=""
#SRC_URI=""

LICENSE="GPL-2"
SLOT="0"
KEYWORDS="~amd64 ~x86"
IUSE=""

RDEPEND=">=app-admin/eselect-1.0.2"

src_unpack() {
	# need ${S} anyhow for src_install
	mkdir ${S}
	sed -e "s/@VERSION@/${PV}/" \
		"${FILESDIR}/gitlab-gitaly.eselect-${PVR}" \
		> "${S}/gitlab-gitaly.eselect" || die
}

src_install() {
	insinto /usr/share/eselect/modules
	doins "${S}/gitlab-gitaly.eselect" || die
}
