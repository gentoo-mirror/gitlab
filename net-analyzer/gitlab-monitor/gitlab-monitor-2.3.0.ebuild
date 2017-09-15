# Copyright 1999-2013 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header: $

EAPI="5"

EGIT_REPO_URI="https://gitlab.com/gitlab-org/gitlab-monitor.git"
EGIT_COMMIT="v${PV}"
USE_RUBY="ruby23"

inherit eutils git-2 ruby-ng user

DESCRIPTION="Tooling used to monitor some aspects of GitLab.com"
HOMEPAGE="https://gitlab.com/gitlab-org/gitlab-monitor.git"
LICENSE="MIT"
SLOT="0"
KEYWORDS="~amd64 ~x86 ~arm"

DEPEND="$(ruby_implementations_depend)"
RDEPEND="${DEPEND}"

GIT_GROUP="git"
HOME="/var/lib/git"
REPO_DIR="${HOME}/repositories"
DEST_DIR="/var/lib/${PN}"

RAILS_ENV=${RAILS_ENV:-production}
RUBY=${RUBY:-ruby23}
BUNDLE="${RUBY} /usr/bin/bundle"

all_ruby_unpack() {
	git-2_src_unpack
	cd ${P}
	sed -i \
		-e "s|\(source:\).*|\1 ${REPO_DIR}|" \
		config/gitlab-monitor.yml.example || die "failed to filter gitlab-monitor.yml.example"
}

all_ruby_compile() {
	einfo "Running bundle install ..."
	${BUNDLE} install || die "bundler failed"
}

all_ruby_install() {

	einfo "Running bundle install ..."
    ${BUNDLE} install --path vendor/bundle || die "bundler failed"

	rm -Rf .git .gitignore .gitlab-ci.yml .rubocop.yml
	insinto ${DEST_DIR}
	doins -r . || die
	
	newinitd $FILESDIR/gitlab-monitor.init gitlab-monitor
	fperms 0755 ${DEST_DIR}/bin/gitlab-mon
}

pkg_postinst() {
	elog "Copy ${DEST_DIR}/config/gitlab-monitor.yml.example to ${DEST_DIR}/config/gitlab-monitor.yml"
	elog "and edit this file in order to configure your GitLab-Monitor settings."
}
