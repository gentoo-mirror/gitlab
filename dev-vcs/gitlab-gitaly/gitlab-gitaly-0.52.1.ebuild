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

DEPEND=">=dev-lang/go-1.8.3
		dev-libs/icu
		dev-ruby/bundler"
RDEPEND="${DEPEND}"

src_prepare()
{
	sed -s 's#^socket_path = .*#socket_path = "/opt/gitlabhq/tmp/sockets/gitaly.socket"#' -i "config.toml.example" || die
	sed -s 's#^path = .*#path = "/var/lib/git/repositories"#' -i "config.toml.example" || die
	sed -s 's#^dir = "/home/git/gitaly/ruby"#dir = "/var/lib/gitlab-gitaly/ruby"#' -i "config.toml.example" || die
	sed -s 's#^dir = "/home/git/gitlab-shell"#dir = "/var/lib/gitlab-shell"#' -i "config.toml.example" || die

	# See https://gitlab.com/gitlab-org/gitaly/issues/493
	sed -s 's#LDFLAGS#GO_LDFLAGS#g' -i Makefile || die
}

src_install()
{
	# Cleanup unneeded temp/object/source files
	find ruby/vendor -name '*.[choa]' -delete
	find ruby/vendor -name '*.[ch]pp' -delete
	find ruby/vendor -iname 'Makefile' -delete
	# Other cleanup candidates: a.out *.bin

	into "/usr" # This will install the binary to /usr/bin. Don't specify the "bin" folder!
	newbin "gitaly" "gitlab-gitaly"

	insinto "/var/lib/gitlab-gitaly"
	doins -r "ruby"

	# make binaries executable
	exeinto "/var/lib/gitlab-gitaly/ruby/bin"
	doexe "ruby/bin/"*

	insinto "/etc/gitaly"
	newins "config.toml.example" "config.toml"
}
