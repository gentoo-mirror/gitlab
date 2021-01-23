# Copyright 2021 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=7

inherit acct-user

DESCRIPTION="Git repository hosting user"

IUSE="gitea gitlab gitolite"
REQUIRED_USE="^^ ( gitea gitlab gitolite )"

ACCT_USER_ID=196
ACCT_USER_HOME_OWNER=git:git
ACCT_USER_HOME_PERMS=750
ACCT_USER_SHELL=/bin/sh
ACCT_USER_GROUPS=( git )

RDEPEND="acct-group/redis"

acct-user_add_deps

pkg_setup() {
	if use gitea; then
		ACCT_USER_HOME=/var/lib/gitea
	elif use gitlab; then
		ACCT_USER_HOME=/var/lib/gitlab
		ACCT_USER_GROUPS+=( redis )
	elif use gitolite; then
		ACCT_USER_HOME=/var/lib/gitolite
	else
		die "Incorrect USE flag combination"
	fi
}

pkg_postinst() {
	acct-user_pkg_postinst
	elog "For GitLab the git user has to be unlocked but doesn't"
	elog "need a password as only ssh public key login is used."
	elog "Changing the password field of git in /etc/shadow:"
	if [ $(passwd -S git | cut -d" " -f2) == "P" ]; then
		eerror "Change canceled, because the git user has a real password."
		eerror "Run \"usermod -p '*' git\" to do the change manually."
	else
		usermod -p '*' git
		elog "Changed the password field from \"!\" to \"*\"."
	fi
}
