# Copyright 2021 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI="7"

# Maintainer notes:
# - This ebuild uses Bundler to download and install all gems in deployment mode
#   (i.e. into isolated directory inside application). That's not Gentoo way how
#   it should be done, but GitLab has too many dependencies that it will be too
#   difficult to maintain them via ebuilds.

USE_RUBY="ruby31"

EGIT_REPO_URI="https://gitlab.com/gitlab-org/gitlab-foss.git"
EGIT_COMMIT="v${PV}"

inherit git-r3 ruby-single systemd tmpfiles

DESCRIPTION="The gitlab and gitaly parts of the GitLab DevOps platform"
HOMEPAGE="https://gitlab.com/gitlab-org/gitlab-foss"

LICENSE="MIT"
RESTRICT="network-sandbox splitdebug strip"
SLOT="0"
KEYWORDS="~amd64 ~x86"
IUSE="favicon +gitaly_git -gitlab-config kerberos -mail_room -pages -prometheus -relative_url systemd"
# Current (2021-11-24) groups in gitlab Gemfile:
# puma development test danger coverage omnibus ed25519 kerberos
# Current (2021-11-24) groups in gitlab-gitaly Gemfile:
# development test omnibus
# USE flags that affect the "--local without" option below
WITHOUTflags="kerberos"

## Gems dependencies:
#   gpgme				app-crypt/gpgme
#   rugged				dev-libs/libgit2
#   nokogiri			dev-libs/libxml2, dev-libs/libxslt
#   charlock_holmes		dev-libs/icu
#   yajl-ruby			dev-libs/yajl
#   pg					dev-db/postgresql-base
#   gitlab-markup		dev-python/docutils
#
GEMS_DEPEND="
	app-crypt/gpgme
	dev-libs/icu
	dev-libs/libxml2
	dev-libs/libxslt
	dev-util/ragel
	dev-libs/yajl
	dev-db/postgresql:13
	net-libs/http-parser
	dev-python/docutils"
GITALY_DEPEND="
	>=dev-lang/go-1.19
	dev-build/cmake"
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
	>=net-libs/nodejs-18.17.0
	>=dev-lang/ruby-3.1.4:3.1[ssl]
	>=dev-vcs/gitlab-shell-14.28.0[relative_url=]
	pages? ( ~www-apps/gitlab-pages-${PV} )
	!gitaly_git? ( >=dev-vcs/git-2.41.0[pcre] dev-libs/libpcre2[jit] )
	net-misc/curl
	virtual/ssh
	=sys-apps/yarn-1.22*
	dev-libs/re2"
RDEPEND="${DEPEND}
	!www-servers/gitlab-workhorse
	>=dev-db/redis-6.0
	virtual/mta
	kerberos? ( app-crypt/mit-krb5 )
	favicon? ( media-gfx/graphicsmagick )"
BDEPEND="
	=dev-ruby/rubygems-3.4*
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
vSYS=2 # version of SYStemd service files used by this ebuild
vORC=2 # version of OpenRC init files used by this ebuild

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
	vINST=${vINST%-r*}
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
			15.11.13)			if [ "${PV}" = "16.0.0" ]; then
									MODUS="major"
									elog "This is a major upgrade from $vINST to $PV."
								else
									die "You should upgrade to 16.0.0 first."
								fi;;
			14.10.5)			if [ "${PV}" = "15.0.0" ]; then
									MODUS="major"
									elog "This is a major upgrade from $vINST to $PV."
								else
									die "You should upgrade to 15.0.0 first."
								fi;;
			13.12.15)			die "You should upgrade to 14.0.0 first.";;
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
		local rubyVinst=$(ruby --version)
		rubyVinst=${rubyVinst%%.?p*}
		rubyVinst=${rubyVinst##ruby }
		rubyVinst=${rubyVinst/./}
		local rubyV=$(ls ${gitlab_dir}/vendor/bundle/ruby 2>/dev/null)
		rubyV=${rubyV%.?}
		rubyV=${rubyV/./}
		if [ "$rubyVinst" != "$rubyV" ]; then
			elog "Temporary switch to ruby${rubyV}"
			eselect ruby set ruby${rubyV}
		fi
		bm=$(su -l ${GIT_USER} -s /bin/sh -c "
			export RUBYOPT=--disable-did_you_mean LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
			cd ${gitlab_dir}
			${BUNDLE} exec rails runner -e ${RAILS_ENV} ${rails_cmd}" \
				|| die "failed to check for background migrations")
		if [ "${bm}" != "0" ]; then
			elog "The new version may require a set of background migrations to be finished."
			elog "For more information see:"
			elog "https://gitlab.com/gitlab-org/gitlab-foss/-/blob/master/doc/update/README.md#checking-for-background-migrations-before-upgrading"
			eerror "Number of remaining background migrations is ${bm}"
			eerror "Try again later."
			die "Background migrations from previous upgrade not finished yet."
		else
			elog "OK: No remaining background migrations found."
		fi
		if [ "$rubyVinst" != "$rubyV" ]; then
			elog "Switching back to ruby${rubyVinst}"
			eselect ruby set ruby${rubyVinst}
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
}

src_prepare() {
	eapply -p0 "${FILESDIR}/${PN}-fix-checks-gentoo-r1.patch"
	eapply -p0 "${FILESDIR}/${PN}-fix-sendmail-param.patch"
	eapply -p0 "${FILESDIR}/${PN}-pod-markup.patch"

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
	if ! use prometheus; then
		sed -i \
			-e '/ *sidekiq_exporter:/{n;s| *# *enabled: true|      enabled: false|}' \
			-e '/ *web_exporter:/{n;s| *# *enabled: true|      enabled: false|}' \
			-e '/ *prometheus:/{n;s| *# *enabled: true|    enabled: false|}' \
		config/gitlab.yml.example || die "failed to filter gitlab.yml.example"
	fi
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
	# Update paths for puma
	sed -i \
		-e "s|/home/git/gitlab|${GITLAB}|g" \
		config/puma.rb.example \
		|| die "failed to modify puma.rb.example"
	if use relative_url; then
		echo "ENV['RAILS_RELATIVE_URL_ROOT'] = \"/gitlab\"" >> config/puma.rb.example \
			|| die "failed to modify puma.rb.example"
	fi

	cp config/resque.yml.example config/resque.yml
	cp config/cable.yml.example config/cable.yml
	cp config/puma.rb.example config/puma.rb

	# remove needless files
	rm .foreman .gitignore

	# Remove Geo database setting as in gitlab-foss Geo is not available and
	# GitLab will do a "Only main: and ci: database names are supported." check. 
	sed -i '/geo:/,/^$/d' config/database.yml.postgresql

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
	MAKEOPTS="${MAKEOPTS} -j1" emake WITH_BUNDLED_GIT=$(usex gitaly_git) \
		|| die "Compiling gitaly failed"
}

src_install_gitaly() {
	cd ${WORKDIR}/gitlab-gitaly-${PV}
	# cleanup candidates: a.out *.bin

	# Will install binaries to ${GITLAB_GITALY}/bin. Don't specify the "bin"!
	into "${GITLAB_GITALY}"
	dobin _build/bin/*

	if use gitaly_git ; then
		sed -i \
			-e "s|\${GIT_PREFIX}/bin/git|\${GIT_DEFAULT_PREFIX}/bin/git|" \
			-e '/${Q}env.*${GIT_BUILD_OPTIONS} install/{n;s|\${Q}touch \$@||}' \
			Makefile || die "failed to fix gitaly Makefile"
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
	# is created at runtime by /usr/lib/tmpfiles.d/gitlab.conf
	#keepdir "${TMP_DIR}"

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

	# keep upstream permissions in scripts/ folder
	cp -dR --preserve=mode scripts "${ED}/${GITLAB}"
	rm -rf scripts
	# now copy all the rest
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
		"${FILESDIR}"/gitlab.logrotate > "${ED}"/etc/logrotate.d/${PN} \
		|| die "failed to filter gitlab.logrotate"

	## Install gems via bundler ##

	cd "${ED}/${GITLAB}"

	local gitlab_dir="${BASE_DIR}/${PN}"

	# Hack: Don't start from scratch, use the installed node_modules
	if [ -d ${gitlab_dir}/node_modules ]; then
		einfo "   Copying ${gitlab_dir}/node_modules/ ..."
		rsync -a --exclude=".cache" ${gitlab_dir}/node_modules ./
	fi
	# Hack: Don't start from scratch, use the installed public/assets
	if [ -d ${gitlab_dir}/public/assets ]; then
		einfo "   Copying ${gitlab_dir}/public/assets/ ..."
		cp -a ${gitlab_dir}/public/assets/ public/
	fi

	local without="development test omnibus"
	local flag; for flag in ${WITHOUTflags}; do
		without+="$(use $flag || echo ' '$flag)"
	done
	${BUNDLE} config set --local deployment 'true'
	${BUNDLE} config set --local without "${without}"
	${BUNDLE} config set --local build.gpgme --use-system-libraries
	${BUNDLE} config set --local build.nokogiri --use-system-libraries
	${BUNDLE} config set --local build.ruby-magic --use-system-libraries

	#einfo "Current ruby version is \"$(ruby --version)\""

	einfo "Running bundle install ..."
	# Cleanup args to extract only JOBS.
	# Because bundler does not know anything else.
	local jobs=1
	grep -Eo '(-j|--jobs)(=?|[[:space:]]*)[[:digit:]]+' <<< "${MAKEOPTS}" > /dev/null
	if [[ $? -eq 0 ]] ; then
		jobs=$(grep -Eo '(-j|--jobs)(=?|[[:space:]]*)[[:digit:]]+' <<< "${MAKEOPTS}" \
			| tail -n1 | grep -Eo '[[:digit:]]+')
	fi
	${BUNDLE} install --jobs=${jobs} || die "bundle install failed"

	## Install GetText PO files, yarn, assets via bundler ##

	dodir ${GITLAB_SHELL}
	local vGS=$(best_version dev-vcs/gitlab-shell)
	vGS=$(echo ${vGS#dev-vcs/gitlab-shell-})
	echo ${vGS%-*} > ${ED}/${GITLAB_SHELL}/VERSION
	# Let lib/gitlab/shell.rb set the .gitlab_shell_secret symlink
	# inside the sandbox. The real symlink will be set in pkg_config().
	# Note: The gitlab-shell path "${ED}/${GITLAB_SHELL}" is set
	#       here to prevent lib/gitlab/shell.rb creating the
	#       gitlab_shell.secret symlink outside the sandbox.
	sed -i \
		-e "s|${GITLAB_SHELL}|${ED}${GITLAB_SHELL}|g" \
		config/gitlab.yml || die "failed to fake the gitlab-shell path"
	einfo "Updating node dependencies and (re)compiling assets ..."
	/bin/sh -c "
		${BUNDLE} exec rake yarn:install gitlab:assets:clean gitlab:assets:compile \
		RAILS_ENV=${RAILS_ENV} NODE_ENV=${NODE_ENV}" \
		|| die "failed to update node dependencies and (re)compile assets"
	# Correct the gitlab-shell path we fooled lib/gitlab/shell.rb with.
	sed -i \
		-e "s|${ED}${GITLAB_SHELL}|${GITLAB_SHELL}|g" \
		${ED}/${GITLAB_CONFIG}/gitlab.yml || die "failed to change back gitlab-shell path"
	if [ "$MODUS" != "new" ]; then
		# Use the .gitlab_shell_secret file of the installed GitLab
		cp -f ${gitlab_dir}/.gitlab_shell_secret ${ED}${GITLAB}/.gitlab_shell_secret
	fi
	# Correct the link
	ln -sf ${GITLAB}/.gitlab_shell_secret ${ED}${GITLAB_SHELL}/.gitlab_shell_secret
	# Remove ${ED}/${GITLAB_SHELL}/VERSION to avoid file collision with dev-vcs/gitlab-shell
	rm -f ${ED}/${GITLAB_SHELL}/VERSION

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
	local file gem wwfgems="gitlab-dangerfiles gitlab-labkit os rack-cors tanuki_emoji toml-rb unleash"
	# If we are using wildcards, the shell fills them without prefixing ${ED}. Thus
	# we would target a file list in the real system instead of in the sandbox.
	for gem in ${wwfgems}; do
		for file in $(find_files "d,f" "${GITLAB}/${gemsdir}/${gem}-*"); do
			fperms go-w $file
		done
	done

	# remove tmp and log dir of the build process
	rm -Rf tmp log
	dosym "${TMP_DIR}" "${GITLAB}/tmp"
	dosym "${LOG_DIR}" "${GITLAB}/log"

	# systemd/openrc files
	use relative_url && relative_url="/gitlab" || relative_url=""

	if use systemd; then
		## Systemd files ##
		elog "Installing systemd unit files"
		local service services="gitaly sidekiq workhorse puma" unit unitfile
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
				-e "s|@RELATIVE_URL@|${relative_url}|g" \
				"${unitfile}" > "${T}/${unit}" || die "failed to configure: $unit"
			systemd_dounit "${T}/${unit}"
		done

		local optional_wants="" optional_requires="" optional_after=""
		use mail_room && optional_wants+="Wants=gitlab-mailroom.service"
		use gitlab-config || optional_requires+="Requires=gitlab-update-config.service"
		use gitlab-config || optional_after+="After=gitlab-update-config.service"
		sed -e "s|@OPTIONAL_REQUIRES@|${optional_requires}|" \
			-e "s|@OPTIONAL_AFTER@|${optional_after}|" \
			-e "s|@OPTIONAL_WANTS@|${optional_wants}|" \
			"${FILESDIR}/${PN}.target.${vSYS}" > "${T}/${PN}.target" \
			|| die "failed to configure: ${PN}.target"
		systemd_dounit "${T}/${PN}.target"
		cp "${FILESDIR}/${PN}.slice.${vSYS}" "${T}/${PN}.slice"
		systemd_dounit "${T}/${PN}.slice"
	else
		## OpenRC init scripts ##
		elog "Installing OpenRC init.d files"
		local service services="${PN} gitlab-gitaly" rc rcfile update_config puma_start
		local mailroom_vars='' mailroom_start='' mailroom_stop='' mailroom_status=''

		rcfile="${FILESDIR}/${PN}.init.${vORC}"
		# The sed command will replace the newline(s) with the string "\n".
		# Note: We use this below to replace a matching line of the rcfile by
		# the contents of another file whose newlines would break the outer sed.
		# Note: Continuation characters '\' in inserted files have to be escaped!
		puma_start="$(sed -z 's/\n/\\n/g' ${rcfile}.puma_start | head -c -2)"
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
		sed -e "s|@WEBSERVER_START@|${puma_start}|" \
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
				"${rcfile}" > "${T}/${rc}" || die "failed to configure: ${rc}"
			newinitd "${T}/${rc}" "${service}"
		done
	fi

	newtmpfiles "${FILESDIR}/${PN}-tmpfiles.conf" ${PN}.conf

	# fix permissions

	fowners -R ${GIT_USER}:${GIT_GROUP} $GITLAB $CONF_DIR $LOG_DIR $GIT_REPOS
	[ -f "${ED}/${CONF_DIR}/secrets.yml" ]      && fperms 600 "${CONF_DIR}/secrets.yml"
	[ -f "${ED}/${GITLAB_CONFIG}/secrets.yml" ] && fperms 600 "${GITLAB_CONFIG}/secrets.yml"

	src_install_gitaly
}

pkg_postinst_gitaly() {
	if use gitaly_git; then
		local conf_dir="${CONF_DIR}"
		use gitlab-config && conf_dir="${GITLAB_CONFIG}"
		elog  ""
		ewarn "Note: With gitaly_git USE flag enabled the included git was installed to"
		ewarn "      ${GITLAB_GITALY}/bin/. In order to use it one has to set the"
		ewarn "      [git] \"bin_path\" variable in \"${CONF_DIR_GITALY}/config.toml\" and in"
		ewarn "      \"${conf_dir}/gitlab.yml\" to \"${GITLAB_GITALY}/bin/git\""
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
	einfo "Cleaning Git global settings for git user"
	su -l ${GIT_USER} -s /bin/sh -c "
		git config --global --remove-section core 2>/dev/null;
		git config --global --remove-section gc 2>/dev/null;
		git config --global --remove-section repack 2>/dev/null;
		git config --global --remove-section receive 2>/dev/null;"

	if [ "$MODUS" = "new" ]; then
		local conf_dir="${CONF_DIR}"
		use gitlab-config && conf_dir="${GITLAB_CONFIG}"
		elog
		elog "For this new installation, proceed with the following steps:"
		elog
		elog "  1. Create a database user for GitLab."
		elog "     On your database server (local ore remote) become user postgres:"
		elog "       su -l postgres"
		elog "     GitLab needs three PostgreSQL extensions: pg_trgm, btree_gist, plpgsql."
		elog "     To create the extensions if they are missing do:"
		elog "       psql -d template1 -c \"CREATE EXTENSION IF NOT EXISTS pg_trgm;\""
		elog "       psql -d template1 -c \"CREATE EXTENSION IF NOT EXISTS btree_gist;\""
		elog "       psql -d template1 -c \"CREATE EXTENSION IF NOT EXISTS plpgsql;\""
		elog "     Create the database user:"
		elog "       psql -c \"CREATE USER gitlab CREATEDB PASSWORD 'gitlab'\""
		elog "     Note: You should change your password to something more random ..."
		elog "     You may need to add configs for the new 'gitlab' user to the"
		elog "     pg_hba.conf and pg_ident.conf files of your database server."
		elog
		elog "     This ebuild assumes that you run the Postgres server on a"
		elog "     different machine. If you run it here add the dependency"
		if use systemd; then
			elog "       systemctl edit gitlab-puma.service"
			elog "     In the editor that opens, add the following and save the file:"
			elog "       [Unit]"
			elog "       Wants=postgresql.service"
			elog "       After=postgresql.service"
			elog
			elog "       systemctl edit gitlab-sidekiq.service"
			elog "     In the editor that opens, add the following and save the file:"
			elog "       [Unit]"
			elog "       Wants=postgresql.service"
			elog "       After=postgresql.service"
		else
			elog "       in /etc/init.d/gitlab (see the comment there)."
		fi
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
		if use systemd; then
			elog "     Supervise Redis with systemd: Change /etc/redis/redis.conf to"
			elog "       daemonize no"
			elog "       supervised systemd"
			elog "       #pidfile /run/redis/redis.pid"
			elog "     Make matching changes to the systemd unit file:"
			elog "     Create /etc/systemd/system/redis.service.d/10fix_type.conf"
			elog "     and insert the following lines"
			elog "       [Service]"
			elog "       Type=notify"
			elog "       PIDFile="
			elog "     Then run"
			elog "       systemctl daemon-reload"
			elog "       systemctl restart redis.service"
		fi
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
	elog  "-- Migrating data --"
	elog "Found your latest gitlabhq instance at \"${BASE_DIR}/gitlabhq-${vINST}\"."

	elog  "1. This will move your public/uploads/ folder from"
	elog  "   \"${BASE_DIR}/gitlabhq-${vINST}\" to \"${GITLAB}\"."
	einfon "   (C)ontinue or (s)kip? "
	local migrate_uploads=$(continue_or_skip)
	if [[ $migrate_uploads ]]; then
		elog "   Moving the public/uploads/ folder ..."
		su -l ${GIT_USER} -s /bin/sh -c "
			rm -rf ${GITLAB}/public/uploads && \
			mv ${BASE_DIR}/gitlabhq-${vINST}/public/uploads ${GITLAB}/public/uploads" \
			|| die "failed to move the public/uploads/ folder."

		# Fix permissions
		find "${GITLAB}/public/uploads/" -type d -exec chmod 0700 {} \;
		elog "   ... finished."
	fi

	elog  "2. This will move your shared/ data folder from"
	elog  "   \"${BASE_DIR}/gitlabhq-${vINST}\" to \"${GITLAB}\"."
	einfon "   (C)ontinue or (s)kip? "
	local migrate_shared=$(continue_or_skip)
	if [[ $migrate_shared ]]; then
		elog "   Moving the shared/ data folder ..."
		su -l ${GIT_USER} -s /bin/sh -c "
			rm -rf ${GITLAB}/shared && \
			mv ${BASE_DIR}/gitlabhq-${vINST}/shared ${GITLAB}/shared" \
			|| die "failed to move the shared/ data folder."

		# Fix permissions
		find "${GITLAB}/shared/" -type d -exec chmod 0700 {} \;
		elog "   ... finished."
	fi
}

pkg_config_do_upgrade_migrate_database() {
	elog "Migrating database ..."
	su -l ${GIT_USER} -s /bin/sh -c "
		export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
		cd ${GITLAB}
		${BUNDLE} exec rake db:migrate RAILS_ENV=${RAILS_ENV}" \
			|| die "failed to migrate database."
}

pkg_config_do_upgrade_clear_redis_cache() {
	elog "Clean up cache ..."
	su -l ${GIT_USER} -s /bin/sh -c "
		export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
		cd ${GITLAB}
		${BUNDLE} exec rake cache:clear RAILS_ENV=${RAILS_ENV}" \
			|| die "failed to run cache:clear"
}

pkg_config_do_upgrade() {
	# do the upgrade
	pkg_config_do_upgrade_migrate_database

	pkg_config_do_upgrade_clear_redis_cache
}

pkg_config_initialize() {
	# check config and initialize database
	local conf_dir="${CONF_DIR}"
	use gitlab-config && conf_dir="${GITLAB_CONFIG}"

	## Check config files existence ##
	elog "Checking configuration files ..."
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
	elog "Initializing database ..."
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
		elog "No need to run \"emerge --config\" after a rebuild."
	elif [ "$MODUS" = "patch" ] || [ "$MODUS" = "minor" ] || [ "$MODUS" = "major" ]; then
		pkg_config_do_upgrade
		local ret=$?
		if [ $ret -ne 0 ]; then return $ret; fi
	fi

	if [ "$MODUS" = "new" ]; then
		elog
		elog "Now start ${PN} with"
		if use systemd; then
			elog "\$ systemctl start ${PN}.target"
		else
			elog "\$ rc-service ${PN} start"
		fi
	fi

	elog
	elog "You might want to check your application status. Run this:"
	elog "\$ cd ${GITLAB}"
	elog "\$ sudo -u ${GIT_USER} ${BUNDLE} exec rake gitlab:check RAILS_ENV=${RAILS_ENV}"
	elog
	elog "GitLab is prepared now."
	if [ "$MODUS" = "patch" ] || [ "$MODUS" = "minor" ] || [ "$MODUS" = "major" ]; then
		elog "Ensure you're still up-to-date with the latest NGINX configuration changes:"
		elog "\$ cd /opt/gitlab/gitlab"
		elog "\$ git -P diff v${vINST}:lib/support/nginx/ v${PV}:lib/support/nginx/"
	elif [ "$MODUS" = "new" ]; then
		elog "To configure your nginx site have a look at the examples configurations"
		elog "in the ${GITLAB}/lib/support/nginx/ folder."
		if use relative_url; then
			elog "For a relative URL installation several modifications must be made to nginx"
			elog "\t Move everything in the top-level 'server' block to top-level nginx.conf"
			elog "\t Remove the top-level 'server' block"
			elog "\t Add a 'location /gitlab at the top where the server block was"
			elog "\t Change 'location /' to 'location /gitlab/'"
			elog "\t Symlink <htdocs>/gitlab to ${GITLAB}/public"
			elog "In order for the Background Jobs page to work, add"
			elog "\t 'location ~ ^/gitlab/admin/sidekiq/* {"
			elog "\t proxy_pass http://gitlab-workhorse;"
			elog "\t }"
			elog "under the main gitlab location block"
		fi
	fi
}
