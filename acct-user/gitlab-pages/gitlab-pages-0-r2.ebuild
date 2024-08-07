# Copyright 2021 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

inherit acct-user

DESCRIPTION="Dedicated user for gitlab-pages"

ACCT_USER_ID=126
ACCT_USER_GROUPS=( git )

ACCT_USER_HOME=/var/lib/gitlab-pages
ACCT_USER_HOME_OWNER=gitlab-pages:git
ACCT_USER_HOME_PERMS=0770

acct-user_add_deps
