# Copyright 1999-2015 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header: $

EAPI="5"

EGIT_REPO_URI="https://gitlab.com/gitlab-org/gitaly.git"
EGIT_COMMIT="v${PV}"

inherit eutils git-2 user

DESCRIPTION="Gitaly is a Git RPC service for handling all the git calls made by GitLab."
HOMEPAGE="https://gitlab.com/gitlab-org/gitaly"
LICENSE="MIT"
SLOT="0"
KEYWORDS="~amd64 ~x86 ~arm"

DEPEND=">=dev-lang/go-1.8.3"
RDEPEND="${DEPEND}"

src_prepare()
{
	sed -s 's#^socket_path = .*#socket_path = "/opt/gitlabhq/tmp/sockets/gitaly.socket"#' -i "config.toml.example" || die
	sed -s 's#^path = .*#path = "/var/lib/git/repositories"#' -i "config.toml.example" || die
}

src_install()
{
	into "/usr" # This will install the binary to /usr/bin. Don't specify the "bin" folder!
	newbin "gitaly" "gitlab-gitaly"

	insinto "/etc/gitaly"
	newins "config.toml.example" "config.toml"
}
