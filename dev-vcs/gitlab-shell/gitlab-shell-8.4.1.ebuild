# Copyright 1999-2013 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header: $

EAPI="5"

EGIT_REPO_URI="https://gitlab.com/gitlab-org/gitlab-shell.git"
EGIT_COMMIT="v${PV}"
USE_RUBY="ruby24"

inherit eutils git-2 ruby-ng user

DESCRIPTION="GitLab Shell is a free SSH access and repository management application"
HOMEPAGE="https://github.com/gitlabhq/gitlab-shell"
LICENSE="MIT"
SLOT="0"
KEYWORDS="~amd64 ~x86 ~arm"

DEPEND="$(ruby_implementations_depend)
	dev-vcs/git
	virtual/ssh
	dev-db/redis"
RDEPEND="${DEPEND}"

GIT_USER="git"
GIT_GROUP="git"
DEST_DIR="/var/lib/${PN}"

pkg_setup() {
	HOME=$(if [ -n "$(getent passwd git | cut -d: -f6)" ]; then (getent passwd git | cut -d: -f6); else (echo /var/lib/git); fi)
	REPO_DIR="${HOME}/repositories"
	AUTH_FILE="${HOME}/.ssh/authorized_keys"
	KEY_DIR=$(dirname "${AUTH_FILE}")

	enewgroup ${GIT_GROUP}
	enewuser ${GIT_USER} -1 -1 "${HOME}" ${GIT_GROUP}
}

all_ruby_unpack() {
	git-2_src_unpack
	cd ${P}
	sed -i \
		-e "s|\(user:\).*|\1 ${GIT_USER}|" \
		-e "s|\(repos_path:\).*|\1 \"${REPO_DIR}\"|" \
		-e "s|\(auth_file:\).*|\1 \"${AUTH_FILE}\"|" \
		config.yml.example || die "failed to filter config.yml.example"
}

all_ruby_compile() {
	./bin/compile
	default
}

all_ruby_install() {

	rm -Rf .git .gitignore go_build

	insinto ${DEST_DIR}
	touch gitlab-shell.log
	doins -r . || die

	dosym ${DEST_DIR}/bin/gitlab-keys /usr/bin/gitlab-keys || die
	dosym ${DEST_DIR}/bin/gitlab-shell /usr/bin/gitlab-shell || die
	dosym ${DEST_DIR}/bin/check /usr/bin/gitlab-check || die

	for bin in $(ls bin) ; do
		fperms 0755 ${DEST_DIR}/bin/${bin} || die
	done

	fperms 0755 ${DEST_DIR}/hooks/post-receive || die
	fperms 0755 ${DEST_DIR}/hooks/pre-receive || die
	fperms 0755 ${DEST_DIR}/hooks/update || die
	
	fowners ${GIT_USER} ${DEST_DIR}/gitlab-shell.log
	fowners ${GIT_USER} ${DEST_DIR} || die
}

pkg_postinst() {

	dodir "${REPO_DIR}" || die

	if [[ ! -d "${KEY_DIR}" ]] ; then
		mkdir "${KEY_DIR}" || die
		chmod 0700 "${KEY_DIR}" || die
		chown ${GIT_USER}:${GIT_GROUP} "${KEY_DIR}" -R || die
	fi

	if [[ ! -e "${AUTH_FILE}" ]] ; then
		touch "${AUTH_FILE}" || die
		chmod 0600 "${AUTH_FILE}" || die
		chown ${GIT_USER}:${GIT_GROUP} "${AUTH_FILE}" || die
	fi

	if [[ ! -d "${REPO_DIR}" ]] ; then
		mkdir "${REPO_DIR}"
		chmod ug+rwX,o-rwx "${REPO_DIR}" -R || die
		chmod ug-s,o-rwx "${REPO_DIR}" -R || die
		chown ${GIT_USER}:${GIT_GROUP} "${REPO_DIR}" -R || die
	fi

	elog "Copy ${DEST_DIR}/config.yml.example to ${DEST_DIR}/config.yml"
	elog "and edit this file in order to configure your GitLab-Shell settings."
}