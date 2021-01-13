# Copyright 1999-2019 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header: $

EAPI="7"

EGIT_REPO_URI="https://gitlab.com/gitlab-org/gitlab-shell.git"
EGIT_COMMIT="v${PV}"
USE_RUBY="ruby26 ruby27"

inherit eutils git-r3 ruby-single user

DESCRIPTION="SSH access for GitLab"
HOMEPAGE="https://github.com/gitlabhq/gitlab-shell"
LICENSE="MIT"
SLOT="0"
KEYWORDS="~amd64 ~x86 ~arm"
RESTRICT="network-sandbox"
BDEPEND="
	${RUBY_DEPS}
	>=dev-ruby/bundler-2:2"
DEPEND="
	acct-user/git[gitlab]
	acct-group/git
	|| ( >=dev-vcs/git-2.29.0[pcre,pcre-jit] dev-vcs/gitlab-gitaly[gitaly_git] )
	>=dev-lang/go-1.13.9
	virtual/ssh
	dev-db/redis"
RDEPEND="${DEPEND}"

GIT_USER="git"
GIT_GROUP="git"
GIT_HOME="/var/lib/gitlab"
BASE_DIR="/opt/gitlab"
DEST_DIR="${BASE_DIR}/${PN}"

RAILS_ENV=${RAILS_ENV:-production}
REDIS_URL="unix:/run/redis/redis.sock"

REPO_DIR="${HOME}/repositories"
AUTH_FILE="${GIT_HOME}/.ssh/authorized_keys"
KEY_DIR="${GIT_HOME}/.ssh/"
GITLAB_URL="${BASE_DIR}/gitlabhq/tmp/sockets/gitlab-workhorse.socket"

src_prepare() {
	eapply_user
	cp config.yml.example config.yml
	local gitlab_url_encoded=$(echo "${GITLAB_URL}" | sed -s 's|/|%2F|g')
	sed -i \
		-e "s|\(user:\).*|\1 ${GIT_USER}|" \
		-e "s|\(gitlab_url:\).*|\1 \"http+unix://${gitlab_url_encoded}\"|" \
		-e "s|\(auth_file:\).*|\1 \"${AUTH_FILE}\"|" \
		-e "s|log_level: .*|log_level: WARN|" \
		config.yml || die "failed to filter config.yml"
}

src_compile() {
	einfo "Running \"bundle install\" ..."
	export LANG=en_US.UTF-8
	export LC_ALL=en_US.UTF-8
	local RUBY=${RUBY:-ruby}
	${RUBY} /usr/bin/bundle config set path 'vendor/bundle'
	${RUBY} /usr/bin/bundle install || die "failed to run bundle install"
	ruby_version=$(ls $PWD/vendor/bundle/ruby)
	export PATH=$PWD/vendor/bundle/ruby/$ruby_version/bin:$PATH
	make compile || die "failed to run make compile"
}

src_install() {
	rm -Rf .git .gitignore go_build

	insinto ${DEST_DIR}
	touch gitlab-shell.log
	doins -r . || die

	for bin in $(ls bin) ; do
		fperms 0755 ${DEST_DIR}/bin/${bin} || die
	done

	fowners ${GIT_USER} ${DEST_DIR}/gitlab-shell.log
	fowners ${GIT_USER} ${DEST_DIR} || die

	# env file
	cat > 42"${PN}" <<-EOF
		CONFIG_PROTECT="${DEST_DIR}/config.yml"
	EOF
	doenvd 42"${PN}"
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
