# Copyright 1999-2020 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=7

inherit user readme.gentoo-r1 systemd tmpfiles user

DESCRIPTION="GitLab Runner"
HOMEPAGE="https://gitlab.com/gitlab-org/gitlab-runner"

# The following list of binaries is provided at the following URL
# https://gitlab-runner-downloads.s3.amazonaws.com/v13.6.0/index.html
SRC_HOST="gitlab-runner-downloads.s3.amazonaws.com"
SRC_BASE="https://${SRC_HOST}/v${PV}/binaries/gitlab-runner-linux"
SRC_URI="
	x86?	( ${SRC_BASE}-386   -> gitlab-runner-${PV} )
	amd64?	( ${SRC_BASE}-amd64 -> gitlab-runner-${PV} )
	arm?	( ${SRC_BASE}-amd64 -> gitlab-runner-${PV} )
"

LICENSE="MIT"
SLOT="0"
KEYWORDS="~amd64 ~x86 ~arm ~arm64"
IUSE="systemd"

RDEPEND="acct-user/gitlab-runner"
DEPEND="
	${RDEPEND}
	systemd? ( sys-apps/systemd )
"

RESTRICT="mirror strip"

DOC_CONTENTS="Register the runner as root using\\n
\\t# gitlab-runner register\\n
This will save the config in /etc/gitlab-runner/config.toml"

src_unpack() {
	mkdir ${S}
}

src_prepare() {
	default
	cp ${DISTDIR}/${A} ${S}/gitlab-runner || die
}

src_install() {
	einstalldocs

	dosbin gitlab-runner

	newconfd "${FILESDIR}"/gitlab-runner.confd gitlab-runner
	newinitd "${FILESDIR}"/gitlab-runner.initd gitlab-runner
	systemd_dounit "${FILESDIR}"/gitlab-runner.service
	newtmpfiles "${FILESDIR}"/gitlab-runner.tmpfile gitlab-runner.conf

	readme.gentoo_create_doc

	insopts -o gitlab-runner -g gitlab-runner -m0600
	diropts -o gitlab-runner -g gitlab-runner -m0750
	insinto /etc/gitlab-runner
	keepdir /etc/gitlab-runner /var/lib/gitlab-runner
}

pkg_postinst() {
	tmpfiles_process gitlab-runner.conf
	readme.gentoo_print_elog
}
