# Copyright 2021 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI="7"

EGIT_REPO_URI="https://gitlab.com/gitlab-org/gitaly.git"
EGIT_COMMIT="v${PV}"

USE_RUBY="ruby27"

inherit eutils git-r3 user ruby-single

DESCRIPTION="Gitaly is a Git RPC service for handling all the git calls made by GitLab."
HOMEPAGE="https://gitlab.com/gitlab-org/gitaly"
LICENSE="MIT"
SLOT=$PV
KEYWORDS="~amd64 ~x86 ~arm"
IUSE="gitaly_git"

RESTRICT="network-sandbox strip"
DEPEND="
	>=dev-lang/go-1.13.9
	dev-libs/icu
	>=dev-ruby/bundler-2:2
	dev-util/cmake
	!gitaly_git? ( >=dev-vcs/git-2.29.0[pcre,pcre-jit] )
	app-eselect/eselect-gitlab-gitaly
	${RUBY_DEPS}"
RDEPEND="${DEPEND}"

GIT_HOME="/var/lib/gitlab"
BASE_DIR="/opt/gitlab"
DEST_DIR="${BASE_DIR}/${PN}-${SLOT}"
CONF_DIR="/etc/${PN}-${SLOT}"

GIT_REPOS="${GIT_HOME}/repositories"
GITLAB_SHELL="${BASE_DIR}/gitlab-shell"
GITLAB_SOCKETS="${BASE_DIR}/gitlabhq-${SLOT}/tmp/sockets"

BUNDLE="ruby /usr/bin/bundle"

src_prepare() {
	eapply_user

	# Update paths for gitlab
	# Note: Order of -e expressions is important here
	local gitlabhq_urlenc=$(echo "${BASE_DIR}/gitlabhq/" | sed -e "s|/|%2F|g")
	sed -i \
		-e "s|^bin_dir = \"/home/git/gitaly\"|bin_dir = \"${DEST_DIR}/bin\"|" \
		-e "s|/home/git/gitaly|${DEST_DIR}|g" \
		-e "s|/home/git/gitlab-shell|${GITLAB_SHELL}|g" \
		-e "s|/home/git/gitlab/log|${BASE_DIR}/gitlabhq/log|g" \
		-e "s|http+unix://%2Fhome%2Fgit%2Fgitlab%2F|http+unix://${gitlabhq_urlenc}|" \
		-e "s|/home/git/gitlab/tmp/sockets/private|${GITLAB_SOCKETS}|g" \
		-e "s|/home/git/|${GIT_HOME}/|g" \
		-e "s|^# \[logging\]|\[logging\]|" \
		-e "s|^# level = .*|level = \"warn\"|" \
		config.toml.example || die "failed to filter config.toml.example"

	sed -s "s#\$GITALY_BIN_DIR#${DEST_DIR}/bin#" -i ruby/git-hooks/gitlab-shell-hook || die

	# See https://gitlab.com/gitlab-org/gitaly/issues/493
	sed -s 's|LDFLAGS|GO_LDFLAGS|g' -i Makefile || die
	sed -s 's|^BUNDLE_FLAGS|#BUNDLE_FLAGS|' -i Makefile || die

	cd ruby
	local without="development test"
	${BUNDLE} config set --local path 'vendor/bundle'
	${BUNDLE} config set --local deployment 'true'
	${BUNDLE} config set --local without "${without}"
	${BUNDLE} config set --local build.nokogiri --use-system-libraries

	if [ -d ${BASE_DIR}/${PN}/ ]; then
		einfo "Using parts of the installed gitlab-gitaly to save time:"
	fi
	# Hack: Don't start from scratch, use the installed bundle
	mkdir -p vendor/bundle
	cd vendor
	if [ -d ${BASE_DIR}/${PN}/ruby/vendor/bundle/ruby ]; then
		einfo "   Copying ${BASE_DIR}/${PN}/ruby/vendor/bundle/ruby/ ..."
		cp -a ${BASE_DIR}/${PN}/ruby/vendor/bundle/ruby/ bundle/
	fi
}

src_install() {
	# Cleanup unneeded temp/object/source files
	find ruby/vendor -name '*.[choa]' -delete
	find ruby/vendor -name '*.[ch]pp' -delete
	find ruby/vendor -iname 'Makefile' -delete
	# Other cleanup candidates: a.out *.bin

	# Clean up old gems (this is required due to our Hack above)
	sh -c "cd ruby; ${BUNDLE} clean"

	into "${DEST_DIR}" # Will install binaries to ${DEST_DIR}/bin. Don't specify the "bin"!
	dobin _build/bin/*

	insinto "${DEST_DIR}"
	doins -r "ruby"

	# Make binaries in ruby/ executable
	local rubyV=$(ls ruby/vendor/bundle/ruby)
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

pkg_postinst() {
	if use gitaly_git; then
		elog  ""
		einfo "Note: With gitaly_git USE flag enabled the included git was installed to"
		einfo "      ${DEST_DIR}/bin/. In order to use it one has to set the"
		einfo "      git \"bin_path\" variable in \"${CONF_DIR}/config.toml\" and in"
		einfo "      \"/etc/gitlabhq/gitlab.yml\" to \"${DEST_DIR}/bin/git\""
	fi
	einfo "Use \"eselect ${PN}\" to select the gitaly slot."
}