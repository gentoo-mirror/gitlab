# Copyright 2021 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI="7"

# Maintainer notes:
# - This ebuild uses Bundler to download and install all gems in deployment mode
#   (i.e. into isolated directory inside application). That's not Gentoo way how
#   it should be done, but GitLab has too many dependencies that it will be too
#   difficult to maintain them via ebuilds.

USE_RUBY="ruby27"

EGIT_REPO_URI="https://gitlab.com/gitlab-org/gitlab-foss.git"
EGIT_COMMIT="v${PV}"

inherit eutils git-r3 ruby-single systemd tmpfiles user

DESCRIPTION="The gitlab and gitaly parts of the GitLab DevOps platform"
HOMEPAGE="https://gitlab.com/gitlab-org/gitlab-foss"

LICENSE="MIT"
RESTRICT="network-sandbox splitdebug strip"
SLOT="0"
KEYWORDS="~amd64 ~x86"
IUSE="favicon +gitaly_git -gitlab-config kerberos -mail_room -pages -relative_url systemd"
# USE flags that affect the --without option below
# Current (2021-06-23) groups in Gemfile:
# puma metrics development test danger coverage omnibus ed25519 kerberos
WITHOUTflags="kerberos"

## Gems dependencies:
#   gpgme				app-crypt/gpgme
#   rugged				dev-libs/libgit2
#   nokogiri			dev-libs/libxml2, dev-libs/libxslt
#   charlock_holmes		dev-libs/icu
#   yajl-ruby			dev-libs/yajl
#   execjs				net-libs/nodejs, or any other JS runtime
#   pg					dev-db/postgresql-base
#
GEMS_DEPEND="
	app-crypt/gpgme
	dev-libs/icu
	dev-libs/libxml2
	dev-libs/libxslt
	dev-util/ragel
	dev-libs/yajl
	>=net-libs/nodejs-14
	dev-db/postgresql:12
	net-libs/http-parser"
GITALY_DEPEND="
	>=dev-lang/go-1.15
	dev-util/cmake"
WORKHORSE_DEPEND="
	dev-lang/go
	media-libs/exiftool"
DEPEND="
	${GEMS_DEPEND}
	${GITALY_DEPEND}
	${WORKHORSE_DEPEND}
	${RUBY_DEPS}
	acct-user/git[gitlab]
	acct-group/git
	>dev-lang/ruby-2.7.2:2.7[ssl]
	~dev-vcs/gitlab-shell-13.19.1[relative_url=]
	pages? ( ~www-apps/gitlab-pages-1.41.0 )
	!gitaly_git? ( >=dev-vcs/git-2.31.0[pcre] dev-libs/libpcre2[jit] )
	net-misc/curl
	virtual/ssh
	>=sys-apps/yarn-1.15.0
	dev-libs/re2"
RDEPEND="${DEPEND}
	!www-servers/gitlab-workhorse
	>=dev-db/redis-6.0
	virtual/mta
	kerberos? ( app-crypt/mit-krb5 )
	favicon? ( media-gfx/graphicsmagick )"
BDEPEND="
	virtual/rubygems
	>=dev-ruby/bundler-2:2"

GIT_USER="git"
GIT_GROUP="git"
GIT_HOME="/var/lib/gitlab"
BASE_DIR="/opt/gitlab"
GITLAB="${BASE_DIR}/${PN}"
CONF_DIR="/etc/${PN}"
GITLAB_CONFIG="${GITLAB}/config"
CONF_DIR_GITALY="/etc/gitlab-gitaly"
LOG_DIR="/var/log/${PN}"
TMP_DIR="/var/tmp/${PN}"
WORKHORSE="${BASE_DIR}/gitlab-workhorse"
WORKHORSE_BIN="${WORKHORSE}/bin"
vSYS=1 # version of SYStemd service files used by this ebuild
vORC=1 # version of OpenRC init files used by this ebuild

GIT_REPOS="${GIT_HOME}/repositories"
GITLAB_SHELL="${BASE_DIR}/gitlab-shell"
GITLAB_SOCKETS="${GITLAB}/tmp/sockets"
GITLAB_GITALY="${BASE_DIR}/gitlab-gitaly"
GITALY_CONF="/etc/gitlab-gitaly"

RAILS_ENV=${RAILS_ENV:-production}
NODE_ENV=${RAILS_ENV:-production}
BUNDLE="ruby /usr/bin/bundle"

MODUS='' # [new|rebuild|patch|minor|major]

pkg_setup() {
	# get the installed version
	vINST=$(best_version www-apps/gitlab)
	if [ -z "$vINST" ]; then
		vINST=$(best_version www-apps/gitlabhq)
		[ -n "$vINST" ] && die "The migration from a www-apps/gitlabhq installation to "\
							   ">=www-apps/gitlab-14.0.0 isn't supported. You have to "\
							   "upgrade to 13.12.15 first."
	fi
	vINST=${vINST##*-}
	if [ -n "$vINST" ] && ver_test "$PV" -lt "$vINST"; then
		# do downgrades on explicit user request only
		ewarn "You are going to downgrade from $vINST to $PV."
		ewarn "Note that the maintainer of the GitLab overlay never tested this."
		ewarn "Extra actions may be neccessary, like the ones described in"
		ewarn "https://docs.gitlab.com/ee/update/restore_after_failure.html"
		if [ "$GITLAB_DOWNGRADE" != "true" ]; then
			die "Set GITLAB_DOWNGRADE=\"true\" to really do the downgrade."
		fi
	else
		local eM eM1 em em1 em2 ep
		eM=$(ver_cut 1); eM1=$(($eM - 1))
		em=$(ver_cut 2); em1=$(($em - 1)); em2=$(($em - 2))
		ep=$(ver_cut 3)
		# check if upgrade path is supported and qualified for upgrading without downtime
		case "$vINST" in
			"")					MODUS="new"
								elog "This is a new installation.";;
			${PV})				MODUS="rebuild"
								elog "This is a rebuild of $PV.";;
			${eM}.${em}.*)		MODUS="patch"
								elog "This is a patch upgrade from $vINST to $PV.";;
			${eM}.${em1}.*)		MODUS="minor"
								elog "This is a minor upgrade from $vINST to $PV.";;
			${eM}.[0-${em2}].*) die "You should do minor upgrades step by step.";;
			13.12.15)			if [ "${PV}" = "14.0.0" ]; then
									MODUS="major"
									elog "This is a major upgrade from $vINST to $PV."
								else
									die "You should upgrade to 14.0.0 first."
								fi;;
			12.10.14)			die "You should upgrade to 13.1.0 first.";;
			12.*.*)				die "You should upgrade to 12.10.14 first.";;
			${eM1}.*.*)			die "You should upgrade to latest ${eM1}.x.x version"\
									"first and then to the ${eM}.0.0 version.";;
			*)					if ver_test $vINST -lt 12.0.0 ; then
									die "Upgrading from $vINST isn't supported. Do it manual."
								else
									die "Do step by step upgrades to latest minor version in"\
										" each major version until ${eM}.${em}.x is reached."
								fi;;
		esac
	fi

	if [ "$MODUS" = "patch" ] || [ "$MODUS" = "minor" ] || [ "$MODUS" = "major" ]; then
		# ensure that any background migrations have been fully completed
		# see /opt/gitlab/gitlab/doc/update/README.md
		elog "Checking for background migrations ..."
		local bm gitlab_dir rails_cmd="'puts Gitlab::BackgroundMigration.remaining'"
		gitlab_dir="${BASE_DIR}/${PN}"
		bm=$(su -l ${GIT_USER} -s /bin/sh -c "
			export RUBYOPT=--disable-did_you_mean LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
			cd ${gitlab_dir}
			${BUNDLE} exec rails runner -e ${RAILS_ENV} ${rails_cmd}" \
				|| die "failed to check for background migrations")
		if [ "${bm}" != "0" ]; then
			elog "The new version may require a set of background migrations to be finished."
			elog "For more information see:"
			elog "https://gitlab.com/gitlab-org/gitlab-foss/-/blob/master/doc/update/README.md#checking-for-background-migrations-before-upgrading"
			eerror "Number of remainig background migrations is ${bm}"
			eerror "Try again later."
			die "Background migrations from previous upgrade not finished yet."
		else
			elog "OK: No remainig background migrations found."
		fi
	fi

	if [ "$MODUS" = "rebuild" ] || \
		 [ "$MODUS" = "patch" ] || [ "$MODUS" = "minor" ] || [ "$MODUS" = "major" ]; then
		elog  "Saving current configuration"
		cp -a ${CONF_DIR} ${T}/etc-config
	fi
	if use gitlab-config; then
		if [ ! -f /etc/env.d/42${PN} ]; then
			cat > /etc/env.d/99${PN}_temp <<-EOF
				CONFIG_PROTECT="${GITLAB_CONFIG}"
			EOF
			env-update
			# will be removed again in pkg_postinst()
		fi
	fi
	if [ -f /etc/env.d/42${PN} ]; then
		if ! use gitlab-config; then
			rm -f /etc/env.d/42${PN}
			env-update
		fi
	fi
}

src_unpack_gitaly() {
	EGIT_REPO_URI="https://gitlab.com/gitlab-org/gitaly.git"
	EGIT_COMMIT="v${PV}"
	EGIT_CHECKOUT_DIR="${WORKDIR}/gitlab-gitaly-${PV}"
	git-r3_src_unpack
}

src_unpack() {
	git-r3_src_unpack # default src_unpack() for the gitlab part

	src_unpack_gitaly
}

src_prepare_gitaly() {
	cd ${WORKDIR}/gitlab-gitaly-${PV}
	# Update paths for gitlab
	# Note: Order of -e expressions is important here
	local gitlab_urlenc=$(echo "${GITLAB}/" | sed -e "s|/|%2F|g")
	sed -i \
		-e "s|^bin_dir = \".*\"|bin_dir = \"${GITLAB_GITALY}/bin\"|" \
		-e "s|/home/git/gitaly|${GITLAB_GITALY}|g" \
		-e "s|/home/git/gitlab-shell|${GITLAB_SHELL}|g" \
		-e "s|/home/git/gitlab/log|${GITLAB}/log|g" \
		-e "s|http+unix://%2Fhome%2Fgit%2Fgitlab%2F|http+unix://${gitlab_urlenc}|" \
		-e "s|/home/git/gitlab/tmp/sockets/private|${GITLAB_SOCKETS}|g" \
		-e "s|/home/git/|${GIT_HOME}/|g" \
		-e "s|^# \[logging\]|\[logging\]|" \
		-e "s|^# level = .*|level = \"warn\"|" \
		-e "s|^# internal_socket_dir = |internal_socket_dir = |" \
		config.toml.example || die "failed to filter config.toml.example"
	if use gitaly_git ; then
		sed -i \
			-e "s|bin_path = .*|bin_path = \"/opt/gitlab/gitlab-gitaly/bin/git\"|" \
			config.toml.example || die "failed to filter config.toml.example"
	fi
	if use relative_url ; then
		sed -i \
			-e "s|^# relative_url_root = '/'|relative_url_root = '/gitlab'|" \
			config.toml.example || die "failed to filter config.toml.example"
	fi

	sed -i \
		-e "s|\$GITALY_BIN_DIR|${GITLAB_GITALY}/bin|" \
		ruby/git-hooks/gitlab-shell-hook || die "failed to filter gitlab-shell-hook"

	# See https://gitlab.com/gitlab-org/gitaly/issues/493
	sed -s 's|LDFLAGS|GO_LDFLAGS|g' -i Makefile || die
	sed -s 's|^BUNDLE_FLAGS|#BUNDLE_FLAGS|' -i Makefile || die

	cd ruby
	local without="development test"
	${BUNDLE} config set --local path 'vendor/bundle'
	${BUNDLE} config set --local deployment 'true'
	${BUNDLE} config set --local without "${without}"
	${BUNDLE} config set --local build.nokogiri --use-system-libraries

	# Hack: Don't start from scratch, use the installed bundle
	local gitaly_dir="${GITLAB_GITALY}"
	if [ -d ${gitaly_dir}/ ]; then
		einfo "Using parts of the installed gitlab-gitaly to save time:"
		mkdir -p vendor/bundle
		cd vendor
		if [ -d ${gitaly_dir}/ruby/vendor/bundle/ruby ]; then
			portageq list_preserved_libs / >/dev/null # returns 1 when no preserved_libs found
			if [ "$?" = "1" ]; then
				einfo "   Copying ${gitaly_dir}/ruby/vendor/bundle/ruby/ ..."
				cp -a ${gitaly_dir}/ruby/vendor/bundle/ruby/ bundle/
			fi
		fi
	fi
}

src_prepare() {
	eapply -p0 "${FILESDIR}/${PN}-fix-checks-gentoo.patch"
	eapply -p0 "${FILESDIR}/${PN}-fix-sendmail-param.patch"

	eapply_user
	# Update paths for gitlab
	# Note: Order of -e expressions is important here.
	sed -i \
		-e "s|/sockets/private/|/sockets/|g" \
		-e "s|/home/git/gitlab-shell|${GITLAB_SHELL}|g" \
		-e "s|/home/git/gitlab/|${GITLAB}/|g" \
		-e "s|/home/git/gitaly|${GITLAB_GITALY}|g" \
		-e "s|/home/git|${GIT_HOME}|g" \
		config/gitlab.yml.example || die "failed to filter gitlab.yml.example"
	if use gitaly_git && \
		[ "$MODUS" != "new" ] && \
		has_version "www-apps/gitlab[gitaly_git]"
	then
		sed -i \
			-e "s|bin_path: /usr/bin/git|bin_path: /opt/gitlab/gitlab-gitaly/bin/git|" \
			config/gitlab.yml.example || die "failed to filter gitlab.yml.example"
	fi
	if use relative_url; then
		sed -i \
			-e "s|# relative_url_root|relative_url_root|g" \
			config/gitlab.yml.example || die "failed to filter gitlab.yml.example"
	fi
	cp config/resque.yml.example config/resque.yml

	# Already use the ruby-magic version that'll come with 13.11
	sed -i \
		-e "s/gem 'ruby-magic-static', '~> 0.3.4'/gem 'ruby-magic', '~> 0.3.2'/" \
		Gemfile
	${BUNDLE} lock

	# remove needless files
	rm .foreman .gitignore

	# Update paths for puma
	sed -i \
		-e "s|/home/git/gitlab|${GITLAB}|g" \
		config/puma.rb.example \
		|| die "failed to modify puma.rb.example"
	if use relative_url; then
		echo "ENV['RAILS_RELATIVE_URL_ROOT'] = \"/gitlab\"" >> config/puma.rb.example \
			|| die "failed to modify puma.rb.example"
	fi

	# "Compiling GetText PO files" wants to read these configs
	cp config/database.yml.postgresql config/database.yml
	cp config/gitlab.yml.example config/gitlab.yml

	# With version 13.7.1 we moved the "yarn install" call
	# from   pkg_config() - i.e. outside sandbox - to
	#       src_install() - i.e. inside  sandbox.
	# But yarn still wants to create/read /usr/local/share/.yarnrc
	addwrite /usr/local/share/

	if [ "$MODUS" = "new" ]; then
		# initialize our source for ${CONF_DIR}
		mkdir -p ${T}/etc-config
		cp config/database.yml.postgresql ${T}/etc-config/database.yml
		cp config/gitlab.yml.example ${T}/etc-config/gitlab.yml
		cp config/puma.rb.example ${T}/etc-config/puma.rb
		if use relative_url; then
			mkdir -p ${T}/etc-config/initializers
			cp config/initializers/relative_url.rb.sample \
				${T}/etc-config/initializers/relative_url.rb
		fi
	fi

	src_prepare_gitaly
}

find_files() {
	local f t="${1}"
	for f in $(find ${ED}${2} -type ${t}); do
		echo $f | sed "s|${ED}||"
	done
}

continue_or_skip() {
	local answer=""
	while true
	do
		read -r answer
		if   [[ $answer =~ ^(s|S)$ ]]; then answer="" && break
		elif [[ $answer =~ ^(c|C)$ ]]; then answer=1  && break
		else echo "Please type either \"c\" to continue or \"s\" to skip ... " >&2
		fi
	done
	echo $answer
}

src_compile() {
	# Nothing to do for gitlab
	einfo "Nothing to do for gitlab."

	# Compile workhorse
	cd workhorse
	einfo "Compiling source in $PWD ..."
	emake || die "Compiling workhorse failed"

	# Compile gitaly
	cd ${WORKDIR}/gitlab-gitaly-${PV}
	export RUBYOPT=--disable-did_you_mean
	einfo "Compiling source in $PWD ..."
	emake || die "Compiling gitaly failed"

	# Hack: Reusing gitaly's bundler cache for gitlab
	local rubyV=$(ls ruby/vendor/bundle/ruby)
	local ruby_vpath=vendor/bundle/ruby/${rubyV}
	if [ -d ruby/${ruby_vpath}/cache ]; then
		mkdir -p ${WORKDIR}/gitlab-${PV}/${ruby_vpath}
		mv ruby/${ruby_vpath}/cache ${WORKDIR}/gitlab-${PV}/${ruby_vpath}
	fi
}

src_install_gitaly() {
	cd ${WORKDIR}/gitlab-gitaly-${PV}
	# Cleanup unneeded temp/object/source files
	find ruby/vendor -name '*.[choa]' -delete
	find ruby/vendor -name '*.[ch]pp' -delete
	find ruby/vendor -iname 'Makefile' -delete
	# Other cleanup candidates: a.out *.bin

	# Clean up old gems (this is required due to our Hack above)
	sh -c "cd ruby; ${BUNDLE} clean"

	local rubyV=$(ls ruby/vendor/bundle/ruby)
	local ruby_vpath=vendor/bundle/ruby/${rubyV}

	# Hack: Copy did_you_mean Gem from system
	local vDYM=$(best_version dev-ruby/did_you_mean)
	vDYM=${vDYM#*/}; vDYM=${vDYM%-r*}; vDYM=${vDYM##*-}
	local pDYM="/usr/lib64/ruby/gems/${rubyV}/gems/did_you_mean-${vDYM}"
	local pSPECS="/usr/lib64/ruby/gems/${rubyV}/specifications"
	cp -a ${pDYM} ruby/${ruby_vpath}/gems
	cp ${pSPECS}/did_you_mean-${vDYM}.gemspec ruby/${ruby_vpath}/specifications

	# Will install binaries to ${GITLAB_GITALY}/bin. Don't specify the "bin"!
	into "${GITLAB_GITALY}"
	dobin _build/bin/*

	insinto "${GITLAB_GITALY}"
	doins -r "ruby"

	# Make binaries in ruby/ executable
	exeinto "${GITLAB_GITALY}/ruby/git-hooks/"
	doexe ruby/git-hooks/gitlab-shell-hook
	exeinto "${GITLAB_GITALY}/ruby/bin"
	doexe ruby/bin/*
	exeinto "${GITLAB_GITALY}/ruby/vendor/bundle/ruby/${rubyV}/bin"
	doexe ruby/vendor/bundle/ruby/${rubyV}/bin/*

	if use gitaly_git ; then
		emake git DESTDIR="${D}" GIT_PREFIX="${GITLAB_GITALY}"
	fi

	insinto "${CONF_DIR_GITALY}"
	newins "config.toml.example" "config.toml"
}

src_install() {
	## Prepare directories ##
	local uploads="${GITLAB}/public/uploads"
	diropts -m700
	dodir "${uploads}"

	diropts -m750
	keepdir "${LOG_DIR}"
	keepdir "${TMP_DIR}"

	diropts -m755
	keepdir "${GIT_REPOS}"
	dodir "${GITLAB}"

	## Install the config ##
	if use gitlab-config; then
		# env file to protect configs in $GITLAB/config
		cat > ${T}/42${PN} <<-EOF
			CONFIG_PROTECT="${GITLAB_CONFIG}"
		EOF
		doenvd ${T}/42${PN}
		insinto "${CONF_DIR}"
		cat > ${T}/README_GENTOO <<-EOF
			The gitlab-config USE flag is on.
			Configs are installed to ${GITLAB_CONFIG} only.
			See news 2021-02-22-etc-gitlab for details.
		EOF
		doins ${T}/README_GENTOO
	else
		insinto "${CONF_DIR}"
		local cfile cfiles
		# pkg_preinst() prepared config in ${T}/etc-config
		# we just want the folder structure; most files will be overwritten in for loop
		cp -a ${T}/etc-config ${T}/config
		for cfile in $(find ${T}/etc-config -type f); do
			cfile=${cfile/${T}\/etc-config\//}
			if [ -f config/${cfile} ]; then
				cp -f config/${cfile} ${T}/config/${cfile}
			fi
			cp -f ${T}/etc-config/${cfile} config/${cfile}
		done
		chown -R ${GIT_USER}:${GIT_GROUP} ${T}/config
		doins -r ${T}/config/.
		cat > ${T}/README_GENTOO <<-EOF
			The gitlab-config USE flag is off.
			Configs are installed to ${CONF_DIR} and automatically
			synced to ${GITLAB_CONFIG} on (re)start of GitLab.
			See news 2021-02-22-etc-gitlab for details.
		EOF
		doins ${T}/README_GENTOO
	fi

	## Install workhorse ##

	local exe all_exe=$(grep "EXE_ALL *:= *" workhorse/Makefile)
	into "${WORKHORSE}"
	for exe in ${all_exe#EXE_ALL *:= *}; do
		dobin workhorse/${exe}
	done
	# Remove workhorse/ dir because of the "doins -r ./" below!
	rm -rf workhorse

	## Install all others ##

	insinto "${GITLAB}"
	doins -r ./

	# make binaries executable
	exeinto "${GITLAB}/bin"
	doexe bin/*
	exeinto "${GITLAB}/qa/bin"
	doexe qa/bin/*

	## Install logrotate config ##

	dodir /etc/logrotate.d
	sed -e "s|@LOG_DIR@|${LOG_DIR}|g" \
		"${FILESDIR}"/gitlab.logrotate > "${D}"/etc/logrotate.d/${PN} \
		|| die "failed to filter gitlab.logrotate"

	## Install gems via bundler ##

	cd "${D}/${GITLAB}"

	local gitlab_dir="${BASE_DIR}/${PN}"

	if [ -d ${gitlab_dir}/ ]; then
		einfo "Using parts of the installed gitlab to save time:"
	fi
	# Hack: Don't start from scratch, use the installed bundle
	if [ -d ${gitlab_dir}/vendor/bundle ]; then
		portageq list_preserved_libs / >/dev/null # returns 1 when no preserved_libs found
		if [ "$?" = "1" ]; then
			einfo "   Copying ${gitlab_dir}/vendor/bundle/ ..."
			cp -a ${gitlab_dir}/vendor/bundle/ vendor/
		fi
	fi
	# Hack: Don't start from scratch, use the installed node_modules
	if [ -d ${gitlab_dir}/node_modules ]; then
		einfo "   Copying ${gitlab_dir}/node_modules/ ..."
		cp -a ${gitlab_dir}/node_modules/ ./
	fi
	# Hack: Don't start from scratch, use the installed public/assets
	if [ -d ${gitlab_dir}/public/assets ]; then
		einfo "   Copying ${gitlab_dir}/public/assets/ ..."
		cp -a ${gitlab_dir}/public/assets/ public/
	fi

	local without="development test coverage omnibus"
	local flag; for flag in ${WITHOUTflags}; do
		without+="$(use $flag || echo ' '$flag)"
	done
	${BUNDLE} config set --local deployment 'true'
	${BUNDLE} config set --local without "${without}"
	${BUNDLE} config set --local build.gpgm --use-system-libraries
	${BUNDLE} config set --local build.nokogiri --use-system-libraries
	${BUNDLE} config set --local build.yajl-ruby --use-system-libraries
	${BUNDLE} config set --local build.ruby-magic --use-system-libraries

	#einfo "Current ruby version is \"$(ruby --version)\""

	einfo "Running bundle install ..."
	# Cleanup args to extract only JOBS.
	# Because bundler does not know anything else.
	local jobs=1
	grep -Eo '(\-j|\-\-jobs)(=?|[[:space:]]*)[[:digit:]]+' <<< "${MAKEOPTS}" > /dev/null
	if [[ $? -eq 0 ]] ; then
		jobs=$(grep -Eo '(\-j|\-\-jobs)(=?|[[:space:]]*)[[:digit:]]+' <<< "${MAKEOPTS}" \
			| tail -n1 | grep -Eo '[[:digit:]]+')
	fi
	${BUNDLE} install --jobs=${jobs} || die "bundle install failed"

	## Install GetText PO files, yarn, assets via bundler ##

	dodir ${GITLAB_SHELL}
	local vGS=$(best_version dev-vcs/gitlab-shell)
	vGS=$(echo ${vGS#dev-vcs/gitlab-shell-})
	echo ${vGS%-*} > ${D}/${GITLAB_SHELL}/VERSION
	# Let lib/gitlab/shell.rb set the .gitlab_shell_secret symlink
	# inside the sandbox. The real symlink will be set in pkg_config().
	# Note: The gitlab-shell path "${D}/${GITLAB_SHELL}" is set
	#       here to prevent lib/gitlab/shell.rb creating the
	#       gitlab_shell.secret symlink outside the sandbox.
	sed -i \
		-e "s|${GITLAB_SHELL}|${D}${GITLAB_SHELL}|g" \
		config/gitlab.yml || die "failed to fake the gitlab-shell path"
	einfo "Updating node dependencies and (re)compiling assets ..."
	${BUNDLE} exec rake yarn:install gitlab:assets:clean gitlab:assets:compile \
		RAILS_ENV=${RAILS_ENV} NODE_ENV=${NODE_ENV} NODE_OPTIONS="--max_old_space_size=4096" \
		|| die "failed to update node dependencies and (re)compile assets"
	# Correct the gitlab-shell path we fooled lib/gitlab/shell.rb with.
	sed -i \
		-e "s|${D}${GITLAB_SHELL}|${GITLAB_SHELL}|g" \
		${D}/${GITLAB_CONFIG}/gitlab.yml || die "failed to change back gitlab-shell path"
	if [ "$MODUS" != "new" ]; then
		# Use the .gitlab_shell_secret file of the installed GitLab
		cp -f ${gitlab_dir}/.gitlab_shell_secret ${D}${GITLAB}/.gitlab_shell_secret
	fi
	# Correct the link
	ln -sf ${GITLAB}/.gitlab_shell_secret ${D}${GITLAB_SHELL}/.gitlab_shell_secret
	# Remove ${D}/${GITLAB_SHELL}/VERSION to avoid file collision with dev-vcs/gitlab-shell
	rm -f ${D}/${GITLAB_SHELL}/VERSION

	## Clean ##

	# Clean up old gems (this is required due to our Hack above)
	${BUNDLE} clean

	local rubyV=$(ls vendor/bundle/ruby)
	local ruby_vpath=vendor/bundle/ruby/${rubyV}

	# remove gems cache
	rm -Rf ${ruby_vpath}/cache

	# fix QA Security Notice: world writable file(s)
	elog "Fixing permissions of world writable files"
	local gemsdir="${ruby_vpath}/gems"
	local file gem wwfgems="gitlab-dangerfiles gitlab-experiment gitlab-labkit"
	# If we are using wildcards, the shell fills them without prefixing ${ED}. Thus
	# we would target a file list in the real system instead of in the sandbox.
	for gem in ${wwfgems}; do
		for file in $(find_files "d,f" "${GITLAB}/${gemsdir}/${gem}-*"); do
			fperms go-w $file
		done
	done
	fperms go-w ${GITLAB}/public/assets/webpack/cmaps/ETHK-B5-H.bcmap

	# remove tmp and log dir of the build process
	rm -Rf tmp log
	dosym "${TMP_DIR}" "${GITLAB}/tmp"
	dosym "${LOG_DIR}" "${GITLAB}/log"

	# systemd/openrc files
	local webserver="puma" webserver_name="Puma"

	use relative_url && relative_url="/gitlab" || relative_url=""

	if use systemd; then
		## Systemd files ##
		elog "Installing systemd unit files"
		local service services="gitaly sidekiq workhorse ${webserver}" unit unitfile
		use mail_room && services+=" mailroom"
		use gitlab-config || services+=" update-config"
		for service in ${services}; do
			unitfile="${FILESDIR}/${PN}-${service}.service.${vSYS}"
			unit="${PN}-${service}.service"
			sed -e "s|@BASE_DIR@|${BASE_DIR}|g" \
				-e "s|@GITLAB@|${GITLAB}|g" \
				-e "s|@GIT_USER@|${GIT_USER}|g" \
				-e "s|@CONF_DIR@|${CONF_DIR}|g" \
				-e "s|@GITLAB_CONFIG@|${GITLAB_CONFIG}|g" \
				-e "s|@TMP_DIR@|${TMP_DIR}|g" \
				-e "s|@WORKHORSE_BIN@|${WORKHORSE_BIN}|g" \
				-e "s|@WEBSERVER@|${webserver}|g" \
				-e "s|@RELATIVE_URL@|${relative_url}|g" \
				"${unitfile}" > "${T}/${unit}" || die "failed to configure: $unit"
			systemd_dounit "${T}/${unit}"
		done

		local optional_wants="" optional_requires="" optional_after=""
		use mail_room && optional_wants+="Wants=gitlab-mailroom.service"
		use gitlab-config || optional_requires+="Requires=gitlab-update-config.service"
		use gitlab-config || optional_after+="After=gitlab-update-config.service"
		sed -e "s|@WEBSERVER@|${webserver}|g" \
			-e "s|@OPTIONAL_REQUIRES@|${optional_requires}|" \
			-e "s|@OPTIONAL_AFTER@|${optional_after}|" \
			-e "s|@OPTIONAL_WANTS@|${optional_wants}|" \
			"${FILESDIR}/${PN}.target.${vSYS}" > "${T}/${PN}.target" \
			|| die "failed to configure: ${PN}.target"
		systemd_dounit "${T}/${PN}.target"
	else
		## OpenRC init scripts ##
		elog "Installing OpenRC init.d files"
		local service services="${PN} gitlab-gitaly" rc rcfile update_config webserver_start
		local mailroom_vars='' mailroom_start='' mailroom_stop='' mailroom_status=''

		rcfile="${FILESDIR}/${PN}.init.${vORC}"
		# The sed command will replace the newline(s) with the string "\n".
		# Note: We use this below to replace a matching line of the rcfile by
		# the contents of another file whose newlines would break the outer sed.
		# Note: Continuation characters '\' in inserted files have to be escaped!
		webserver_start="$(sed -z 's/\n/\\n/g' ${rcfile}.${webserver}_start | head -c -2)"
		if use mail_room; then
			mailroom_vars="\n$(sed -z 's/\n/\\n/g' ${rcfile}.mailroom_vars)"
			mailroom_start="\n$(sed -z 's/\n/\\n/g' ${rcfile}.mailroom_start)"
			mailroom_stop="\n$(sed -z 's/\n/\\n/g' ${rcfile}.mailroom_stop)"
			mailroom_status="\n$(sed -z 's/\n/\\n/g' ${rcfile}.mailroom_status | head -c -2)"
		fi 
		if use gitlab-config; then
			update_config=""
		else
			update_config="su -l ${GIT_USER} -c \"rsync -aHAX ${CONF_DIR}/ ${GITLAB_CONFIG}/\""
		fi
		use relative_url && relative_url="/gitlab" || relative_url=""
		sed -e "s|@WEBSERVER_START@|${webserver_start}|" \
			-e "s|@MAILROOM_VARS@|${mailroom_vars}|" \
			-e "s|@UPDATE_CONFIG@|${update_config}|" \
			-e "s|@MAILROOM_START@|${mailroom_start}|" \
			-e "s|@MAILROOM_STOP@|${mailroom_stop}|" \
			-e "s|@MAILROOM_STATUS@|${mailroom_status}|" \
			-e "s|@RELATIVE_URL@|${relative_url}|" \
			${rcfile} > ${T}/${PN}.init.${vORC} || die "failed to prepare ${rcfile}"
		cp "${FILESDIR}/gitlab-gitaly.init.${vORC}" ${T}/

		for service in ${services}; do
			rcfile="${T}/${service}.init.${vORC}"
			rc="${service}.init"
			sed -e "s|@RAILS_ENV@|${RAILS_ENV}|g" \
				-e "s|@GIT_USER@|${GIT_USER}|g" \
				-e "s|@GIT_GROUP@|${GIT_GROUP}|g" \
				-e "s|@GITLAB@|${GITLAB}|g" \
				-e "s|@LOG_DIR@|${GITLAB}/log|g" \
				-e "s|@WORKHORSE_BIN@|${WORKHORSE_BIN}|g" \
				-e "s|@GITLAB_GITALY@|${GITLAB_GITALY}|g" \
				-e "s|@GITALY_CONF@|${GITALY_CONF}|g" \
				-e "s|@WEBSERVER@|${webserver}|g" \
				-e "s|@WEBSERVER_NAME@|${webserver_name}|g" \
				"${rcfile}" > "${T}/${rc}" || die "failed to configure: ${rc}"
			newinitd "${T}/${rc}" "${service}"
		done
	fi

	newtmpfiles "${FILESDIR}/${PN}-tmpfiles.conf" ${PN}.conf

	# fix permissions

	fowners -R ${GIT_USER}:${GIT_GROUP} $GITLAB $CONF_DIR $TMP_DIR $LOG_DIR $GIT_REPOS
	fperms o+Xr "${TMP_DIR}" # Let nginx access the puma socket
	[ -f "${D}/${CONF_DIR}/secrets.yml" ]      && fperms 600 "${CONF_DIR}/secrets.yml"
	[ -f "${D}/${GITLAB_CONFIG}/secrets.yml" ] && fperms 600 "${GITLAB_CONFIG}/secrets.yml"

	src_install_gitaly
}

pkg_postinst_gitaly() {
	if use gitaly_git; then
		local conf_dir="${CONF_DIR}"
		use gitlab-config && conf_dir="${GITLAB_CONFIG}"
		elog  ""
		einfo "Note: With gitaly_git USE flag enabled the included git was installed to"
		einfo "      ${GITLAB_GITALY}/bin/. In order to use it one has to set the"
		einfo "      [git] \"bin_path\" variable in \"${CONF_DIR_GITALY}/config.toml\" and in"
		einfo "      \"${conf_dir}/gitlab.yml\" to \"${GITLAB_GITALY}/bin/git\""
	fi
}

pkg_postinst() {
	if [ -f /etc/env.d/99${PN}_temp ]; then
		rm -f /etc/env.d/99${PN}_temp
		env-update
	fi
	tmpfiles_process "${PN}.conf"
	if [ ! -e "${GIT_HOME}/.gitconfig" ]; then
		einfo "Setting git user/email in ${GIT_HOME}/.gitconfig,"
		einfo "feel free to modify this file according to your needs!"
		su -l ${GIT_USER} -s /bin/sh -c "
			git config --global user.email 'gitlab@localhost';
			git config --global user.name 'GitLab'" \
			|| die "failed to setup git user/email"
	fi
	einfo "Configuring Git global settings for git user"
	su -l ${GIT_USER} -s /bin/sh -c "
		git config --global core.autocrlf 'input';
		git config --global gc.auto 0;
		git config --global repack.writeBitmaps true;
		git config --global receive.advertisePushOptions true;
		git config --global core.fsyncObjectFiles true" \
		|| die "failed to Configure Git global settings for git user"

	if [ "$MODUS" = "new" ]; then
		local conf_dir="${CONF_DIR}"
		use gitlab-config && conf_dir="${GITLAB_CONFIG}"
		elog
		elog "For this new installation, proceed with the following steps:"
		elog
		elog "  1. Create a database user for GitLab."
		elog "     On your database server (local ore remote) become user postgres:"
		elog "       su -l postgres"
		elog "     GitLab needs two PostgreSQL extensions: pg_trgm and btree_gist."
		elog "     To create the extensions if they are missing do:"
		elog "       psql -d template1 -c \"CREATE EXTENSION IF NOT EXISTS pg_trgm;\""
		elog "       psql -d template1 -c \"CREATE EXTENSION IF NOT EXISTS btree_gist;\""
		elog "     Create the database user:"
		elog "       psql -c \"CREATE USER gitlab CREATEDB PASSWORD 'gitlab'\""
		elog "     Note: You should change your password to something more random ..."
		elog "     You may need to add configs for the new 'gitlab' user to the"
		elog "     pg_hba.conf and pg_ident.conf files of your database server."
		elog
		elog "  2. Edit ${conf_dir}/database.yml in order to configure"
		elog "     database settings for \"${RAILS_ENV}\" environment."
		elog
		elog "  3. Edit ${conf_dir}/gitlab.yml"
		elog "     in order to configure your GitLab settings."
		elog
		if use gitaly_git; then
			elog "     With gitaly_git USE flag enabled the included git was installed to"
			elog "     ${GITLAB_GITALY}/bin/. In order to use it one has to set the"
			elog "     [git] \"bin_path\" variable in \"${CONF_DIR_GITALY}/config.toml\" and in"
			elog "     \"${conf_dir}/gitlab.yml\" to \"${GITLAB_GITALY}/bin/git\""
			elog
		fi
		if use gitlab-config; then
			elog "     With the \"gitlab-config\" USE flag on you have to edit the"
			elog "     config files in the /opt/gitlab/gitlab/config/ folder!"
			elog
		else
			elog "     GitLab expects the parent directory of the config files to"
			elog "     be its base directory, so we have to sync changes made in"
			elog "     /etc/gitlab/ back to /opt/gitlab/gitlab/config/."
			elog "     This is done automatically on start/restart of gitlab"
			elog "     but sometimes it is neccessary to do it manually by"
			elog "       rsync -aHAX /etc/gitlab/ /opt/gitlab/gitlab/config/"
			elog
		fi
		elog "  4. You need to configure redis to have a UNIX socket and you may"
		elog "     adjust the maxmemory settings. Change /etc/redis/redis.conf to"
		elog "       unixsocket /var/run/redis/redis.sock"
		elog "       unixsocketperm 770"
		elog "       maxmemory 1024MB"
		elog "       maxmemory-policy volatile-lru"
		elog
		elog "  5. Gitaly must be running for the \"emerge --config\". Execute"
		if use systemd; then
			elog "     systemctl start gitlab-update-config.service"
			elog "     systemctl --job-mode=ignore-dependencies start ${PN}-gitaly.service"
		else
			elog "     rsync -aHAX /etc/gitlab/ /opt/gitlab/gitlab/config/"
			elog "     rc-service ${PN}-gitaly start"
		fi
		elog "     Make sure the Redis server is running and execute:"
		elog "         emerge --config \"=${CATEGORY}/${PF}\""
	elif [ "$MODUS" = "rebuild" ]; then
		elog "Update the config in /etc/gitlab and then run"
		if use systemd; then
			elog "     systemctl restart gitlab.target"
		else
			elog "     rc-service gitlab restart"
		fi
	elif [ "$MODUS" = "patch" ] || [ "$MODUS" = "minor" ] || [ "$MODUS" = "major" ]; then
		elog
		elog "Migrating database without post deployment migrations ..."
		su -l ${GIT_USER} -s /bin/sh -c "
			export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
			cd ${GITLAB}
			SKIP_POST_DEPLOYMENT_MIGRATIONS=true \
			${BUNDLE} exec rake db:migrate RAILS_ENV=${RAILS_ENV}" \
				|| die "failed to migrate database."
		elog
		elog "Update the config in /etc/gitlab and then run"
		if use systemd; then
			elog "     systemctl restart gitlab.target"
		else
			elog "     rc-service gitlab restart"
		fi
		elog
		elog "To complete the upgrade of your GitLab instance, run:"
		elog "    emerge --config \"=${CATEGORY}/${PF}\""
		elog
	fi
	pkg_postinst_gitaly
}

pkg_config_do_upgrade_migrate_data() {
	einfo  "-- Migrating data --"
	einfo "Found your latest gitlabhq instance at \"${BASE_DIR}/gitlabhq-${vINST}\"."

	einfo  "1. This will move your public/uploads/ folder from"
	einfo  "   \"${BASE_DIR}/gitlabhq-${vINST}\" to \"${GITLAB}\"."
	einfon "   (C)ontinue or (s)kip? "
	local migrate_uploads=$(continue_or_skip)
	if [[ $migrate_uploads ]]; then
		einfo "   Moving the public/uploads/ folder ..."
		su -l ${GIT_USER} -s /bin/sh -c "
			rm -rf ${GITLAB}/public/uploads && \
			mv ${BASE_DIR}/gitlabhq-${vINST}/public/uploads ${GITLAB}/public/uploads" \
			|| die "failed to move the public/uploads/ folder."

		# Fix permissions
		find "${GITLAB}/public/uploads/" -type d -exec chmod 0700 {} \;
		einfo "   ... finished."
	fi

	einfo  "2. This will move your shared/ data folder from"
	einfo  "   \"${BASE_DIR}/gitlabhq-${vINST}\" to \"${GITLAB}\"."
	einfon "   (C)ontinue or (s)kip? "
	local migrate_shared=$(continue_or_skip)
	if [[ $migrate_shared ]]; then
		einfo "   Moving the shared/ data folder ..."
		su -l ${GIT_USER} -s /bin/sh -c "
			rm -rf ${GITLAB}/shared && \
			mv ${BASE_DIR}/gitlabhq-${vINST}/shared ${GITLAB}/shared" \
			|| die "failed to move the shared/ data folder."

		# Fix permissions
		find "${GITLAB}/shared/" -type d -exec chmod 0700 {} \;
		einfo "   ... finished."
	fi
}

pkg_config_do_upgrade_migrate_database() {
	einfo "Migrating database ..."
	su -l ${GIT_USER} -s /bin/sh -c "
		export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
		cd ${GITLAB}
		${BUNDLE} exec rake db:migrate RAILS_ENV=${RAILS_ENV}" \
			|| die "failed to migrate database."
}

pkg_config_do_upgrade_clear_redis_cache() {
	einfo "Clean up cache ..."
	su -l ${GIT_USER} -s /bin/sh -c "
		export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
		cd ${GITLAB}
		${BUNDLE} exec rake cache:clear RAILS_ENV=${RAILS_ENV}" \
			|| die "failed to run cache:clear"
}

pkg_config_do_upgrade_configure_git() {
	einfo "Configure Git to enable packfile bitmaps ..."
	su -l ${GIT_USER} -s /bin/sh -c "
		git config --global repack.writeBitmaps true" \
			|| die "failed to configure Git"
}

pkg_config_do_upgrade() {
	# do the upgrade
	pkg_config_do_upgrade_migrate_database

	pkg_config_do_upgrade_clear_redis_cache

	pkg_config_do_upgrade_configure_git
}

pkg_config_initialize() {
	# check config and initialize database
	local conf_dir="${CONF_DIR}"
	use gitlab-config && conf_dir="${GITLAB_CONFIG}"

	## Check config files existence ##
	einfo "Checking configuration files ..."
	if [ ! -r "${conf_dir}/database.yml" ]; then
		eerror "Copy \"${GITLAB_CONFIG}/database.yml.postgresql\" to \"${conf_dir}/database.yml\""
		eerror "and edit this file in order to configure your database settings for"
		eerror "\"${RAILS_ENV}\" environment."
		die
	fi
	if [ ! -r "${conf_dir}/gitlab.yml" ]; then
		eerror "Copy \"${GITLAB_CONFIG}/gitlab.yml.example\" to \"${conf_dir}/gitlab.yml\""
		eerror "and edit this file in order to configure your GitLab settings"
		eerror "for \"${RAILS_ENV}\" environment."
		die
	fi

	local pw email
	einfon "Set the Administrator/root password: "
	read -sr pw
	einfo
	einfon "Set the Administrator/root email: "
	read -r email
	einfo "Initializing database ..."
	su -l ${GIT_USER} -s /bin/sh -c "
		export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
		cd ${GITLAB}
		${BUNDLE} exec rake gitlab:setup RAILS_ENV=${RAILS_ENV} \
			GITLAB_ROOT_PASSWORD=\"${pw}\" GITLAB_ROOT_EMAIL=\"${email}\"" \
			|| die "failed to run rake gitlab:setup"
}

pkg_config() {
#	## (Re-)Link gitlab_shell_secret into gitlab-shell
#	if [ -L "${GITLAB_SHELL}/.gitlab_shell_secret" ]; then
#		rm "${GITLAB_SHELL}/.gitlab_shell_secret"
#	fi
#	ln -s "${GITLAB}/.gitlab_shell_secret" "${GITLAB_SHELL}/.gitlab_shell_secret"

	if [ "$MODUS" = "new" ]; then
		pkg_config_initialize
	elif [ "$MODUS" = "rebuild" ]; then
		einfo "No need to run \"emerge --config\" after a rebuild."
	elif [ "$MODUS" = "patch" ] || [ "$MODUS" = "minor" ] || [ "$MODUS" = "major" ]; then
		pkg_config_do_upgrade
		local ret=$?
		if [ $ret -ne 0 ]; then return $ret; fi
	fi

	if [ "$MODUS" = "new" ]; then
		einfo
		einfo "Now start ${PN} with"
		if use systemd; then
			einfo "\$ systemctl start ${PN}.target"
		else
			einfo "\$ rc-service ${PN} start"
		fi
	fi

	einfo
	einfo "You might want to check your application status. Run this:"
	einfo "\$ cd ${GITLAB}"
	einfo "\$ sudo -u ${GIT_USER} ${BUNDLE} exec rake gitlab:check RAILS_ENV=${RAILS_ENV}"
	einfo
	einfo "GitLab is prepared now."
	if [ "$MODUS" = "patch" ] || [ "$MODUS" = "minor" ] || [ "$MODUS" = "major" ]; then
		einfo "Ensure you're still up-to-date with the latest NGINX configuration changes:"
		einfo "\$ cd /opt/gitlab/gitlab"
		einfo "\$ git -P diff v${vINST}:lib/support/nginx/ v${PV}:lib/support/nginx/"
	elif [ "$MODUS" = "new" ]; then
		einfo "To configure your nginx site have a look at the examples configurations"
		einfo "in the ${GITLAB}/lib/support/nginx/ folder."
		if use relative_url; then
			einfo "For a relative URL installation several modifications must be made to nginx"
			einfo "\t Move everything in the top-level 'server' block to top-level nginx.conf"
			einfo "\t Remove the top-level 'server' block"
			einfo "\t Add a 'location /gitlab at the top where the server block was"
			einfo "\t Change 'location /' to 'location /gitlab/'"
			einfo "\t Symlink <htdocs>/gitlab to ${GITLAB}/public"
			einfo "In order for the Backround Jobs page to work, add"
			einfo "\t 'location ~ ^/gitlab/admin/sidekiq/* {"
			einfo "\t proxy_pass http://gitlab-workhorse;"
			einfo "\t }"
			einfo "under the main gitlab location block"
		fi
	fi
}
