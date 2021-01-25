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

RESTRICT="network-sandbox"
DEPEND="dev-lang/go"
RDEPEND="${DEPEND}"
BDEPEND=""

GIT_USER="git"
GIT_GROUP="git"
GIT_HOME="/var/lib/gitlab"

src_install() {
	exeinto $GIT_HOME
	doexe gitlab-pages
	fowners ${GIT_USER}:$GIT_GROUP ${GIT_HOME}/gitlab-pages
}

pkg_postinst() {
	einfo "This package was added to the gitlab overlay in January 2021."
	einfo "It installs the ${PN} binary to ${GIT_HOME} and"
	einfo "was never tested/used by the overlay maintainer. -- Good Luck!"
	einfo
	einfo "Read <gitlabhq-base-dir>/doc/administration/pages/source.md"
	einfo "on how to set up GitLab Pages."
}
