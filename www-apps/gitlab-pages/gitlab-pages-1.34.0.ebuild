# Copyright 2021 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=7

inherit eutils git-r3

DESCRIPTION="GitLab Pages daemon used to serve static websites for GitLab users"
HOMEPAGE="https://gitlab.com/gitlab-org/gitlab-pages"
EGIT_REPO_URI="https://gitlab.com/gitlab-org/${PN}.git"
EGIT_COMMIT="v${PV}"

LICENSE="MIT"
RESTRICT="mirror"
SLOT="0"
KEYWORDS="~amd64 ~x86"
IUSE="systemd"

RESTRICT="network-sandbox"
DEPEND="
	dev-lang/go
	acct-user/gitlab-pages"
RDEPEND="${DEPEND}"
BDEPEND=""

src_install() {
	exeinto /opt/gitlab/${PN}
	doexe gitlab-pages
	insinto /opt/gitlab/${PN}
	doins README.md
	if use systemd; then
		insinto /etc/systemd/system/${PN}.d
		doins "${FILESDIR}/${PN}.conf"
		systemd_dounit "${FILESDIR}/${PN}.service"
	else
		doconfd "${FILESDIR}"/${PN}.confd
		doinitd "${FILESDIR}"/${PN}.initd
	fi
}

pkg_postinst() {
	einfo "This package was added to the gitlab overlay in January 2021. It installs"
	einfo "the binary /opt/gitlab/${PN}/gitlab-pages and was never tested/used"
	einfo "by the overlay maintainer. -- Good Luck!"
	einfo
	einfo "Read <gitlabhq-base-dir>/doc/administration/pages/source.md and "
	einfo "/opt/gitlab/${PN}/README.md on how to set up GitLab Pages."
	einfo
	if use systemd; then
		einfo "Edit /etc/systemd/system/${PN}.d/${PN}.conf and adjust"
		einfo "the settings for the ${PN}.service unit."
	else
		einfo "Edit /etc/conf.d/${PN} and adjust" 
        einfo "the settings for the /etc/init.d/${PN} service."
	fi
}
