# Copyright 1999-2015 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header: $

EAPI="5"

EGIT_REPO_URI="https://gitlab.com/gitlab-org/gitaly.git"
EGIT_COMMIT="v${PV}"

USE_RUBY="ruby27"

inherit eutils git-r3 user ruby-single

DESCRIPTION="Gitaly is a Git RPC service for handling all the git calls made by GitLab."
HOMEPAGE="https://gitlab.com/gitlab-org/gitaly"
LICENSE="MIT"
SLOT="0"
KEYWORDS="~amd64 ~x86 ~arm"
IUSE="gitaly_git"

RESTRICT="network-sandbox"
DEPEND=">=dev-lang/go-1.13.9
		dev-libs/icu
		>=dev-ruby/bundler-2:2
		dev-util/cmake
		!gitaly_git? ( >=dev-vcs/git-2.29.0[pcre,pcre-jit] )
		${RUBY_DEPS}"
RDEPEND="${DEPEND}"

src_prepare()
{
	sed -s 's#^socket_path = .*#socket_path = "/opt/gitlabhq/tmp/sockets/gitaly.socket"#' -i "config.toml.example" || die
	sed -s 's#^path = .*#path = "/var/lib/git/repositories"#' -i "config.toml.example" || die
	sed -s 's#^dir = "/home/git/gitaly/ruby"#dir = "/var/lib/gitlab-gitaly/ruby"#' -i "config.toml.example" || die
	sed -s 's#^dir = "/home/git/gitlab-shell"#dir = "/var/lib/gitlab-shell"#' -i "config.toml.example" || die
	sed -s 's#^bin_dir = "/home/git/gitaly"#bin_dir = "/usr/bin"#' -i "config.toml.example" || die
	sed -s 's#$GITALY_BIN_DIR#/usr/bin#' -i "ruby/git-hooks/gitlab-shell-hook" || die
	sed -s 's#^secret_file = "/home/git/gitlab-shell/#secret_file = "/var/lib/gitlab-shell/#' -i "config.toml.example" || die

	# See https://gitlab.com/gitlab-org/gitaly/issues/493
	sed -s 's#LDFLAGS#GO_LDFLAGS#g' -i Makefile || die

	# Fix compiling of nokogumbo, see 
	# https://github.com/rubys/nokogumbo/issues/40#issuecomment-182667202
	pushd ruby
	bundle config build.nokogumbo --with-ldflags='-Wl,--undefined'
	popd
}

find_files()
{
	for f in $(find ${ED}${1} -type f) ; do
		echo $f | sed "s#${ED}##"
	done
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
	dobin "gitaly-ssh"
	dobin "gitaly-hooks"
	dobin "gitaly-debug"
	dobin "gitaly-wrapper"
	dobin "praefect"

	insinto "/var/lib/gitlab-gitaly"
	doins -r "ruby"

	fperms 0755 /var/lib/gitlab-gitaly/ruby/git-hooks/gitlab-shell-hook

	# If we are using wildcards, the shell fills them without prefixing ${ED}. Thus
	# we would target a file list from the real system instead from the sandbox which
	# results in errors if the system has other files than the sandbox.
	for bin in $(find_files /var/lib/gitlab-gitaly/ruby/bin) ; do
		fperms 0755 $bin
	done
	for hook in $(find_files /var/lib/gitlab-gitaly/ruby/gitlab-shell/hooks) ; do
		fperms 0755 $hook 
	done
	for bin in $(find_files "/var/lib/gitlab-gitaly/ruby/vendor/bundle/ruby/*/bin") ; do
		fperms 0755 $bin
	done

	if use gitaly_git ; then
		emake git DESTDIR="${D}" GIT_PREFIX="/var/lib/gitlab-gitaly"
	fi

	insinto "/etc/gitaly"
	newins "config.toml.example" "config.toml"
}

pkg_postinst()
{
	if use gitaly_git; then
		elog  ""
		einfo "Note: With gitaly_git USE flag enabled the included git was installed to"
		einfo "      /var/lib/gitlab-gitaly/bin/. In order to use it one has to set the"
		einfo "      git \"bin_path\" variable in \"/etc/gitaly/config.toml\" and in"
		einfo "      \"/etc/gitlabhq-13.6/gitlab.yml\" to \"/var/lib/gitlab-gitaly/bin/git\""
	fi
}