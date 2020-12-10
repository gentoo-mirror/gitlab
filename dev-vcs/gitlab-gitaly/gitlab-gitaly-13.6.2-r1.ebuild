# Copyright 1999-2015 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header: $

EAPI="5"

EGIT_REPO_URI="https://gitlab.com/gitlab-org/gitaly.git"
EGIT_COMMIT="v${PV}"

USE_RUBY="ruby27"

inherit eutils git-r3 user ruby-single versionator

DESCRIPTION="Gitaly is a Git RPC service for handling all the git calls made by GitLab."
HOMEPAGE="https://gitlab.com/gitlab-org/gitaly"
LICENSE="MIT"
SLOT="$(get_version_component_range 1-2)"
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

DEST_DIR="/var/lib/${PN}-${SLOT}"
CONF_DIR="/etc/${PN}-${SLOT}"

GIT_HOME="/var/lib/git"
GIT_REPOS="${GIT_HOME}/repositories"
GITLAB_SHELL="/var/lib/gitlab-shell"
GITLAB_SOCKETS="/opt/gitlabhq/tmp/sockets"

src_prepare()
{
	sed -i \
		-e "s|^socket_path = .*|socket_path = \"${GITLAB_SOCKETS}/gitaly.socket\"|" \
		-e "s|^path = .*|path = \"${GIT_REPOS}\"|" \
		-e "s|^# \[logging\]|\[logging\]|" \
		-e "s|^# level = .*|level = \"warn\"|" \
		-e "s|^dir = \"/home/git/gitaly/ruby\"|dir = \"${DEST_DIR}/ruby\"|" \
		-e "s|^dir = \"/home/git/gitlab-shell\"|dir = \"${GITLAB_SHELL}\"|" \
		-e "s|^bin_dir = \"/home/git/gitaly\"|bin_dir = \"${DEST_DIR}/bin\"|" \
		-e "s|^secret_file = \"/home/git/gitlab-shell/|secret_file = \"${GITLAB_SHELL}/|" \
		config.toml.example || die "failed to filter config.toml.example"

	sed -s "s#\$GITALY_BIN_DIR#${DEST_DIR}/bin#" -i ruby/git-hooks/gitlab-shell-hook || die

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

	into "${DEST_DIR}" # Will install binaries to ${DEST_DIR}/bin. Don't specify the "bin"!
	newbin "gitaly" "gitlab-gitaly"
	dobin "gitaly-ssh"
	dobin "gitaly-hooks"
	dobin "gitaly-debug"
	dobin "gitaly-wrapper"
	dobin "praefect"

	insinto "${DEST_DIR}"
	doins -r "ruby"

	# Make binaries executable
	local rubyV=$(sed -e "s/\(.\)\(.\)/\1\.\2\.0/" <<< "${USE_RUBY##*ruby}")
	# Note: For USE_RUBY="ruby26 ruby27" we will get "2.7.0" here. That shoul be ok.
	exeinto "${DEST_DIR}/ruby/git-hooks/"
	doexe ruby/git-hooks/gitlab-shell-hook
	exeinto "${DEST_DIR}/ruby/bin"
	doexe ruby/bin/*
	exeinto "${DEST_DIR}/ruby/vendor/bundle/ruby/${rubyV}/bin"
	doexe ruby/vendor/bundle/ruby/${rubyV}/bin/*

	if use gitaly_git ; then
		emake git DESTDIR="${D}" GIT_PREFIX="${DEST_DIR}"
	fi

	insinto "${CONF_DIR}"
	newins "config.toml.example" "config.toml"
}

pkg_postinst()
{
	if use gitaly_git; then
		elog  ""
		einfo "Note: With gitaly_git USE flag enabled the included git was installed to"
		einfo "      ${DEST_DIR}/bin/. In order to use it one has to set the"
		einfo "      git \"bin_path\" variable in \"${CONF_DIR}/config.toml\" and in"
		einfo "      \"/etc/gitlabhq/gitlab.yml\" to \"${DEST_DIR}/bin/git\""
	fi
}
