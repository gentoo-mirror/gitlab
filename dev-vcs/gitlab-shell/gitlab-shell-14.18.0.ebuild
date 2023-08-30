# Copyright 2021 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI="7"

EGIT_REPO_URI="https://gitlab.com/gitlab-org/gitlab-shell.git"
EGIT_COMMIT="v${PV}"
USE_RUBY="ruby30"

inherit git-r3 ruby-single

DESCRIPTION="SSH access for GitLab"
HOMEPAGE="https://gitlab.com/gitlab-org/gitlab-shell"
LICENSE="MIT"
SLOT="0"
KEYWORDS="~amd64 ~x86 ~arm"
IUSE="-relative_url"
RESTRICT="network-sandbox"
BDEPEND="
	${RUBY_DEPS}
	>=dev-ruby/bundler-2:2"
DEPEND="
	acct-user/git[gitlab]
	acct-group/git
	|| ( >=dev-vcs/git-2.38.0[pcre] www-apps/gitlab[gitaly_git] )
	>=dev-lang/go-1.18.9
	virtual/krb5
	virtual/ssh
	dev-db/redis"
RDEPEND="${DEPEND}"

GIT_USER="git"
GIT_GROUP="git"
GIT_HOME="/var/lib/gitlab"
BASE_DIR="/opt/gitlab"
GITLAB_SHELL="${BASE_DIR}/${PN}"
CONF_DIR="/etc/${PN}"

RAILS_ENV=${RAILS_ENV:-production}
REDIS_URL="unix:/run/redis/redis.sock"

REPO_DIR="${HOME}/repositories"
AUTH_FILE="${GIT_HOME}/.ssh/authorized_keys"
KEY_DIR="${GIT_HOME}/.ssh/"
GITLAB_URL="${BASE_DIR}/gitlab/tmp/sockets/gitlab-workhorse.socket"

src_prepare() {
	eapply_user
	local gitlab_url_encoded=$(echo "${GITLAB_URL}" | sed -s 's|/|%2F|g')
	sed -i \
		-e "s|\(user:\).*|\1 ${GIT_USER}|" \
		-e "s|\(gitlab_url:\).*|\1 \"http+unix://${gitlab_url_encoded}\"|" \
		-e "s|\(auth_file:\).*|\1 \"${AUTH_FILE}\"|" \
		-e "s|log_level: .*|log_level: WARN|" \
		-e "s|/home/git/|${GIT_HOME}/|g" \
		config.yml.example || die "failed to filter config.yml.example"
		if use relative_url; then
			sed -i \
				-e "s|^# gitlab_relative_url_root: \"/\"|gitlab_relative_url_root: \"/gitlab\"|" \
				config.yml.example || die "failet to filter config.yml.example"
		fi
}

src_compile() {
	emake compile || die "failed to run make compile"
}

src_install() {
	insinto "${CONF_DIR}"
	newins config.yml.example config.yml
	# the gitlab-shell binary searches config in its base dir
	dosym "${CONF_DIR}/config.yml" "${GITLAB_SHELL}/config.yml"

	insinto ${GITLAB_SHELL}
	doins CHANGELOG README.md CONTRIBUTING.md LICENSE VERSION config.yml.example
	doins -r support
	touch gitlab-shell.log
	doins gitlab-shell.log || die "failed to install gitlab-shell.log"

	emake DESTDIR="${D}" PREFIX="${GITLAB_SHELL}" install || die "failed to run make install"

	fowners ${GIT_USER} ${GITLAB_SHELL}/gitlab-shell.log
	fowners ${GIT_USER} ${GITLAB_SHELL} || die
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

	elog "Edit ${CONF_DIR}/config.yml to configure your GitLab-Shell settings."
}
