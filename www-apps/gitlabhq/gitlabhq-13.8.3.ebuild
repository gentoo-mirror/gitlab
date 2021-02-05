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

DESCRIPTION="GitLab is a complete DevOps platform"
HOMEPAGE="https://gitlab.com/gitlab-org/gitlab-foss"

LICENSE="MIT"
RESTRICT="network-sandbox splitdebug strip"
SLOT=$PV
KEYWORDS="~amd64 ~x86"
IUSE="favicon gitaly_git kerberos -mail_room +puma -unicorn systemd"
REQUIRED_USE="
	^^ ( puma unicorn )"
# USE flags that affect the --without option below
# Current (2020-12-10) groups in Gemfile:
# unicorn puma metrics development test coverage omnibus ed25519 kerberos
WITHOUTflags="kerberos puma unicorn"

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
DEPEND="
	${GEMS_DEPEND}
	${RUBY_DEPS}
	acct-user/git[gitlab]
	acct-group/git
	dev-lang/ruby[ssl]
	~dev-vcs/gitlab-shell-13.15.0
	~dev-vcs/gitlab-gitaly-${PV}
	~www-servers/gitlab-workhorse-8.59.0
	!gitaly_git? ( >=dev-vcs/git-2.29.0[pcre,pcre-jit] )
	gitaly_git? ( dev-vcs/gitlab-gitaly[gitaly_git] )
	app-eselect/eselect-gitlabhq
	net-misc/curl
	virtual/ssh
	>=sys-apps/yarn-1.15.0
	dev-libs/re2"
RDEPEND="${DEPEND}
	>=dev-db/redis-5.0
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
DEST_DIR="${BASE_DIR}/${PN}-${SLOT}"
CONF_DIR="/etc/${PN}-${SLOT}"
LOG_DIR="/var/log/${PN}-${SLOT}"
TMP_DIR="/var/tmp/${PN}-${SLOT}"
WORKHORSE_BIN="${BASE_DIR}/gitlab-workhorse/bin"
vSYS=1 # version of SYStemd service files used by this ebuild
vORC=1 # version of OpenRC init files used by this ebuild

GIT_REPOS="${GIT_HOME}/repositories"
GITLAB_SHELL="${BASE_DIR}/gitlab-shell"
GITLAB_GITALY="${BASE_DIR}/gitlab-gitaly-${SLOT}"
GITALY_CONF="/etc/gitlab-gitaly-${SLOT}"

RAILS_ENV=${RAILS_ENV:-production}
NODE_ENV=${RAILS_ENV:-production}
BUNDLE="ruby /usr/bin/bundle"

src_prepare() {
	eapply -p0 "${FILESDIR}/${PN}-fix-checks-gentoo.patch"
	eapply -p0 "${FILESDIR}/${PN}-fix-sidekiq_check.patch"
	eapply -p0 "${FILESDIR}/${PN}-fix-sendmail-param.patch"

	eapply_user
	# Update paths for gitlab
	# Note: Order of -e expressions is important here.
	sed -i \
		-e "s|/sockets/private/|/sockets/|g" \
		-e "s|/home/git/gitlab-shell|${GITLAB_SHELL}|g" \
		-e "s|/home/git/gitlab/|${DEST_DIR}/|g" \
		-e "s|/home/git/gitaly|${GITLAB_GITALY}|g" \
		-e "s|/home/git|${GIT_HOME}|g" \
		config/gitlab.yml.example || die "failed to filter gitlab.yml.example"

	# remove needless files
	rm .foreman .gitignore
	use puma     || rm config/puma*
	use unicorn  || rm config/unicorn.rb.example*

	# Update paths for puma
	if use puma; then
		sed -i \
			-e "s|/home/git/gitlab|${DEST_DIR}|g" \
			config/puma.rb.example \
			|| die "failed to modify puma.rb.example"
	fi

	# Update paths for unicorn
	if use unicorn; then
		sed -i \
			-e "s|/home/git/gitlab|${DEST_DIR}|g" \
			config/unicorn.rb.example \
			|| die "failed to modify unicorn.rb.example"
	fi

	# "Compiling GetText PO files" wants to read these configs
	cp config/database.yml.postgresql config/database.yml
	cp config/gitlab.yml.example config/gitlab.yml
	# Note: The gitlab-shell path "${D}/${GITLAB_SHELL}" is set
	#       here to prevent lib/gitlab/shell.rb creating the
	#       gitlab_shell.secret symlink outside the sandbox.
	sed -i \
		-e "s|${GITLAB_SHELL}|${D}${GITLAB_SHELL}|g" \
		config/gitlab.yml || die "failed to fake the gitlab-shell path"

	# With version 13.7.1 we moved the "yarn install" call
	# from   pkg_config() - i.e. outside sandbox - to
	#       src_install() - i.e. inside  sandbox.
	# But yarn still wants to create/read /usr/local/share/.yarnrc
	addwrite /usr/local/share/
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

src_install() {
	## Prepare directories ##
	local uploads="${DEST_DIR}/public/uploads"
	diropts -m700
	dodir "${uploads}"

	diropts -m750
	keepdir "${LOG_DIR}"
	keepdir "${TMP_DIR}"

	diropts -m755
	keepdir "${GIT_REPOS}"
	dodir "${DEST_DIR}"

	## Install configs ##

	# Note that we cannot install the config to /etc and symlink
	# it to ${DEST_DIR} since require_relative in config/application.rb
	# seems to get confused by symlinks. So let's install the config
	# to ${DEST_DIR} and create a smylink to /etc/${P}
	dosym "${DEST_DIR}/config" "${CONF_DIR}"

	echo "export RAILS_ENV=${RAILS_ENV}" > "${D}/${DEST_DIR}/.profile"

	## Install all others ##

	insinto "${DEST_DIR}"
	doins -r ./

	# make binaries executable
	exeinto "${DEST_DIR}/bin"
	doexe bin/*
	exeinto "${DEST_DIR}/qa/bin"
	doexe qa/bin/*

	## Install logrotate config ##

	dodir /etc/logrotate.d
	sed -e "s|@LOG_DIR@|${LOG_DIR}|g" \
		"${FILESDIR}"/gitlab.logrotate > "${D}"/etc/logrotate.d/${PN}-${SLOT} \
		|| die "failed to filter gitlab.logrotate"

	# env file
	cat > 42"${PN}-${SLOT}" <<-EOF
		CONFIG_PROTECT="${DEST_DIR}/config"
	EOF
	doenvd 42"${PN}-${SLOT}"
	rm -f 42"${PN}-${SLOT}"

	## Install gems via bundler ##

	cd "${D}/${DEST_DIR}"

	if [ -d ${BASE_DIR}/${PN}/ ]; then
		einfo "Using parts of the installed gitlabhq to save time:"
	fi
	# Hack: Don't start from scratch, use the installed bundle
	if [ -d ${BASE_DIR}/${PN}/vendor/bundle ]; then
		portageq list_preserved_libs / >/dev/null # returns 1 when no preserved_libs found
		if [ "$?" = "1" ]; then
			einfo "   Copying ${BASE_DIR}/${PN}/vendor/bundle/ ..."
			cp -a ${BASE_DIR}/${PN}/vendor/bundle/ vendor/
		fi
	fi
	# Hack: Don't start from scratch, use the installed node_modules
	if [ -d ${BASE_DIR}/${PN}/node_modules ]; then
		einfo "   Copying ${BASE_DIR}/${PN}/node_modules/ ..."
		cp -a ${BASE_DIR}/${PN}/node_modules/ ./
	fi
	# Hack: Don't start from scratch, use the installed public/assets
	if [ -d ${BASE_DIR}/${PN}/public/assets ]; then
		einfo "   Copying ${BASE_DIR}/${PN}/public/assets/ ..."
		cp -a ${BASE_DIR}/${PN}/public/assets/ public/
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

	einfo "Current ruby version is \"$(ruby --version)\""

	einfo "Running bundle install ..."
	${BUNDLE} install --jobs=$(nproc) || die "bundle install failed"

	## Install GetText PO files, yarn, assets via bundler ##

	dodir ${GITLAB_SHELL}
	# Let lib/gitlab/shell.rb set the .gitlab_shell_secret synlink
	# inside the sandbox. The real symlink will be set in pkg_config().
	einfo "Update node dependencies and (re)compile assets ..."
	${BUNDLE} exec rake yarn:install gitlab:assets:clean gitlab:assets:compile \
		RAILS_ENV=${RAILS_ENV} NODE_ENV=${NODE_ENV} NODE_OPTIONS="--max_old_space_size=4096" \
		|| die "failed to update node dependencies and (re)compile assets"
	# Correct the gitlab-shell path we fooled lib/gitlab/shell.rb with.
	sed -i \
		-e "s|${D}${GITLAB_SHELL}|${GITLAB_SHELL}|g" \
		${D}/${DEST_DIR}/config/gitlab.yml || die "failed to change back gitlab-shell path"
	# Remove the ${GITLAB_SHELL} we fooled lib/gitlab/shell.rb with.
	rm -rf ${D}/${GITLAB_SHELL}

	## Clean ##

	# Clean up old gems (this is required due to our Hack above)
	${BUNDLE} clean

	local rubyV=$(ls vendor/bundle/ruby)
	local ruby_vpath=vendor/bundle/ruby/${rubyV}

	# remove gems cache
	rm -Rf ${ruby_vpath}/cache

	# fix permissions

	fowners -R ${GIT_USER}:$GIT_GROUP $DEST_DIR $CONF_DIR $TMP_DIR $LOG_DIR $GIT_REPOS
	fperms o+Xr "${TMP_DIR}" # Let nginx access the puma/unicorn socket

	# fix QA Security Notice: world writable file(s)
	elog "Fixing permissions of world writable files"
	local gemsdir="${ruby_vpath}/gems"
	local file gem wwfgems="gitlab-labkit nakayoshi_fork"
	# If we are using wildcards, the shell fills them without prefixing ${ED}. Thus
	# we would target a file list from the real system instead from the sandbox.
	for gem in ${wwfgems}; do
		for file in $(find_files "d,f" "${DEST_DIR}/${gemsdir}/${gem}-*"); do
			fperms go-w $file
		done
	done
	# in the nakayoshi_fork gem all files are also executable
	for file in $(find_files "f" "${DEST_DIR}/${gemsdir}/nakayoshi_fork-*"); do
		fperms a-x $file
	done

	# remove tmp and log dir of the build process
	rm -Rf tmp log
	dosym "${TMP_DIR}" "${DEST_DIR}/tmp"
	dosym "${LOG_DIR}" "${DEST_DIR}/log"

	# systemd/openrc files
	local webserver webserver_name
	if use puma; then
		webserver="puma"
		webserver_name="Puma"
	elif use unicorn; then
		webserver="unicorn"
		webserver_name="Unicorn"
	fi

	if use systemd; then
		## Systemd files ##
		elog "Installing systemd unit files"
		local service services="gitaly sidekiq workhorse ${webserver}" unit unitfile
		use mail_room && services+=" mailroom"
		for service in ${services}; do
			unitfile="${FILESDIR}/${PN}-${service}.service.${vSYS}"
			unit="${PN}-${SLOT}-${service}.service"
			sed -e "s|@BASE_DIR@|${BASE_DIR}|g" \
				-e "s|@DEST_DIR@|${DEST_DIR}|g" \
				-e "s|@CONF_DIR@|${DEST_DIR}/config|g" \
				-e "s|@TMP_DIR@|${TMP_DIR}|g" \
				-e "s|@WORKHORSE_BIN@|${WORKHORSE_BIN}|g" \
				-e "s|@SLOT@|${SLOT}|g" \
				-e "s|@WEBSERVER@|${webserver}|g" \
				"${unitfile}" > "${T}/${unit}" || die "failed to configure: $unit"
			systemd_dounit "${T}/${unit}"
		done

		local optional_wants=""
		use mail_room && optional_wants+="Wants=gitlabhq-${SLOT}-mailroom.service"
		sed -e "s|@SLOT@|${SLOT}|g" \
			-e "s|@WEBSERVER@|${webserver}|g" \
			-e "s|@OPTIONAL_WANTS@|${optional_wants}|" \
			"${FILESDIR}/${PN}.target.${vSYS}" > "${T}/${PN}-${SLOT}.target" \
			|| die "failed to configure: ${PN}-${SLOT}.target"
		systemd_dounit "${T}/${PN}-${SLOT}.target"

		sed -e "s|@SLOT@|${SLOT}|g" \
			"${FILESDIR}/${PN}-tmpfiles.conf.${vSYS}" > "${T}/${PN}-${SLOT}.conf" \
			|| die "failed to configure: ${PN}-${SLOT}-tmpfiles.conf"
		dotmpfiles "${T}/${PN}-${SLOT}.conf"
	else
		## OpenRC init scripts ##
		elog "Installing OpenRC init.d files"
		local mailroom_enabled=false service services="${PN} gitlab-gitaly" rc rcfile

		use mail_room && mailroom_enabled=true

		# The inner sed command will replace the newline(s) with the string "\n".
		# Note: We use this below to replace a matching line of the rcfile by
		# the contents of another file whose newlines would break the outer sed.
		rcfile="${FILESDIR}/${PN}.init.${vORC}"
		sed -e "s|@WEBSERVER_START@|$(sed -z 's/\n/\\n/g' ${rcfile}.${webserver} \
			| head -c -2)|" \
			${rcfile} > ${T}/${PN}.init.${vORC} || die "failed to prepare ${rcfile}"
		# Note: Continuation characters '\' in ${rcfile}.${webserver} have to be escaped!
		cp "${FILESDIR}/gitlab-gitaly.init.${vORC}" ${T}/

		for service in ${services}; do
			rcfile="${T}/${service}.init.${vORC}"
			rc="${service}-${SLOT}.init"
			sed -e "s|@RAILS_ENV@|${RAILS_ENV}|g" \
				-e "s|@GIT_USER@|${GIT_USER}|g" \
				-e "s|@GIT_GROUP@|${GIT_GROUP}|g" \
				-e "s|@SLOT@|${SLOT}|g" \
				-e "s|@DEST_DIR@|${DEST_DIR}|g" \
				-e "s|@LOG_DIR@|${DEST_DIR}/log|g" \
				-e "s|@WORKHORSE_BIN@|${WORKHORSE_BIN}|g" \
				-e "s|@MAILROOM_ENABLED@|${mailroom_enabled}|g" \
				-e "s|@GITLAB_GITALY@|${GITLAB_GITALY}|g" \
				-e "s|@GITALY_CONF@|${GITALY_CONF}|g" \
				-e "s|@WEBSERVER@|${webserver}|g" \
				-e "s|@WEBSERVER_NAME@|${webserver_name}|g" \
				"${rcfile}" > "${T}/${rc}" || die "failed to configure: ${rc}"
			doinitd "${T}/${rc}"
		done
	fi
}

pkg_postinst() {
	tmpfiles_process "${PN}-${SLOT}.conf"
	if [ ! -e "${GIT_HOME}/.gitconfig" ]; then
		einfo "Setting git user/email in ${GIT_HOME}/.gitconfig,"
		einfo "feel free to modify this file according to your needs!"
		su -l ${GIT_USER} -s /bin/sh -c "
			git config --global user.email 'gitlab@localhost';
			git config --global user.name 'GitLab'" \
			|| die "failed to setup git user/email"
	fi
	einfo "Configure Git global settings for git user"
	su -l ${GIT_USER} -s /bin/sh -c "
		git config --global core.autocrlf 'input';
		git config --global gc.auto 0;
		git config --global repack.writeBitmaps true;
		git config --global receive.advertisePushOptions true;
		git config --global core.fsyncObjectFiles true" \
		|| die "failed to Configure Git global settings for git user"

	local db_name=gitlab_${RAILS_ENV} db_user=gitlab
	elog
	elog "If this is a new installation, proceed with the following steps:"
	elog
	elog "  1. Create a database user for GitLab."
	elog "     On your database server (local ore remote), just copy&run:"
	elog "       su -l postgres"
	elog "       psql -d template1 -c \"CREATE USER ${db_user} CREATEDB PASSWORD 'gitlab'\""
	elog "     Note: You should change your password to something more random..."
	elog
	elog "     GitLab needs two PostgreSQL extensions: pg_trgm and btree_gist."
	elog "     To create the extensions if they are missing do:"
	elog "       su -l postgres"
	elog "       psql -d template1 -c \"CREATE EXTENSION IF NOT EXISTS pg_trgm;\""
	elog "       psql -d template1 -c \"CREATE EXTENSION IF NOT EXISTS btree_gist;\""
	elog
	elog "  2. Edit ${CONF_DIR}/database.yml in order to configure"
	elog "     database settings for \"${RAILS_ENV}\" environment."
	elog
	elog "  3. Edit ${CONF_DIR}/gitlab.yml"
	elog "     in order to configure your GitLab settings."
	elog
	elog "  4. Copy ${CONF_DIR}/resque.yml.example to ${CONF_DIR}/resque.yml"
	elog "     and edit this file in order to configure your Redis settings"
	elog "     for \"${RAILS_ENV}\" environment."
	elog

	if use unicorn; then
		elog "  5. Copy ${CONF_DIR}/unicorn.rb.example to ${CONF_DIR}/unicorn.rb"
		elog
	fi

	if use puma; then
		elog "  5. Copy ${CONF_DIR}/puma.rb.example to ${CONF_DIR}/puma.rb"
		elog
	fi

	elog "  6. You need to configure redis to have a UNIX socket and you may"
	elog "     adjust the maxmemory settings. Change /etc/redis/conf to"
	elog "       unixsocket /var/run/redis/redis.sock"
	elog "       unixsocketperm 770"
	elog "       maxmemory 1024MB"
	elog "       maxmemory-policy volatile-lru"
	elog
	elog "  7. Make sure the Redis server is running and execute:"
	elog "         emerge --config \"=${CATEGORY}/${PF}\""
	elog
	elog "If this is an upgrade of an existing GitLab instance,"
	elog "run the following command and choose upgrading when prompted:"
	elog "    emerge --config \"=${CATEGORY}/${PF}\""
	elog
	elog "  Important: Do not remove the earlier version prior migration!"
}

pkg_config_do_upgrade_migrate_data() {
	einfo  "-- Migrating data --"

	einfo  "1. This will move your public/uploads/ folder from"
	einfo  "   \"${LATEST_DEST}\" to \"${DEST_DIR}\"."
	einfon "   (C)ontinue or (s)kip? "
	local migrate_uploads=$(continue_or_skip)
	if [[ $migrate_uploads ]]; then
		einfon "   Moving the public/uploads/ folder ..."
		su -l ${GIT_USER} -s /bin/sh -c "
			rm -rf ${DEST_DIR}/public/uploads && \
			mv ${LATEST_DEST}/public/uploads ${DEST_DIR}/public/uploads" \
			|| die "failed to move the public/uploads/ folder."

		# Fix permissions
		find "${DEST_DIR}/public/uploads/" -type d -exec chmod 0700 {} \;
		einfo "finished."
	fi

	einfo  "2. This will move your shared/ data folder from"
	einfo  "   \"${LATEST_DEST}\" to \"${DEST_DIR}\"."
	einfon "   (C)ontinue or (s)kip? "
	local migrate_shared=$(continue_or_skip)
	if [[ $migrate_shared ]]; then
		einfon "   Moving the shared/ data folder ..."
		su -l ${GIT_USER} -s /bin/sh -c "
			rm -rf ${DEST_DIR}/shared && \
			mv ${LATEST_DEST}/shared ${DEST_DIR}/shared" \
			|| die "failed to move the shared/ data folder."

		# Fix permissions
		find "${DEST_DIR}/shared/" -type d -exec chmod 0700 {} \;
		einfo "finished."
	fi
}

pkg_config_do_upgrade_migrate_configuration() {
	local configs_to_migrate="database.yml gitlab.yml resque.yml secrets.yml"
	local initializers_to_migrate="smtp_settings.rb"
	use puma    && configs_to_migrate+=" puma.rb"
	use unicorn && configs_to_migrate+=" unicorn.rb"
	local conf example

	einfo  "-- Migrating configuration --"

	einfo  "1. This will move your current config from"
	einfo  "   \"${LATEST_DEST}/config\" to \"${DEST_DIR}/config\""
	einfo  "   and prepare the corresponding ._cfg0000_<conf> files."
	einfon "   (C)ontinue or (s)kip? "
	local migrate_config=$(continue_or_skip)
	if [[ $migrate_config ]]; then
		for conf in ${configs_to_migrate}; do
			test -f "${LATEST_DEST}/config/${conf}" || break
			einfo "   Moving config file \"$conf\" ..."
			cp -p "${LATEST_DEST}/config/${conf}" "${DEST_DIR}/config/"
			sed -i \
			-e "s|$(basename $LATEST_DEST)|${PN}-${SLOT}|g" \
			-e "s|/opt/gitlab/gitlab-gitaly-${LATEST_DEST##*-}|${GITLAB_GITALY}|g" \
			"${DEST_DIR}/config/$conf"

			example="${DEST_DIR}/config/${conf}.example"
			test -f "${example}" && \
				cp -p "${example}" "${DEST_DIR}/config/._cfg0000_${conf}"
		done
		for conf in ${initializers_to_migrate}; do
			test -f "${LATEST_DEST}/config/initializers/${conf}" || break
			einfo "   Moving config file \"initializers/$conf\" ..."
			cp -p "${LATEST_DEST}/config/initializers/${conf}" \
				"${DEST_DIR}/config/initializers/"
			sed -i \
				-e "s|$(basename $LATEST_DEST)|${PN}-${SLOT}|g" \
				"${DEST_DIR}/config/initializers/$conf"

			example="${DEST_DIR}/config/initializers/${conf}.sample"
			test -f "${example}" && \
				cp -p "${example}" "${DEST_DIR}/config/initializers/._cfg0000_${conf}"
		done

		einfo  "2. This will merge the current config with the new config."
		einfon "   Use (d)ispatch-conf, (e)tc-update or (q)uit? "
		while true
		do
			read -r merge_config
			if   [[ $merge_config =~ ^(q|Q)$  ]]; then merge_config=""               && break
			elif [[ $merge_config =~ ^(d|D|)$ ]]; then merge_config="dispatch-conf"  && break
			elif [[ $merge_config =~ ^(e|E|)$ ]]; then merge_config="etc-update"     && break
			else eerror "Please type either \"d\"/\"e\" to continue or \"q\" to quit. "; fi
		done
		if [[ $merge_config ]]; then
			local errmsg="failed to automatically migrate config, run "
			errmsg+="\"CONFIG_PROTECT=${DEST_DIR}/config ${merge_config}\" by hand, re-run "
			errmsg+="this routine and skip config migration to proceed."
			local mmsg="Manually run \"CONFIG_PROTECT=${DEST_DIR}/config ${merge_config}\" "
			mmsg+="and re-run this routine and skip config migration to proceed."
			# Set PATH without /usr/lib/portage/python*/ebuild-helpers because
			# the portageq helper (a bash script) would be executed by etc-update
			# explicitly with python leading to SyntaxErrors
			/bin/bash -c "PATH=/usr/sbin:/usr/bin:/sbin:/bin \
				CONFIG_PROTECT=\"${DEST_DIR}/config\" ${merge_config}" || die "${errmsg}"
		else
			echo "${mmsg}"
			return 1
		fi
	fi
}

pkg_config_do_upgrade_migrate_database() {
	einfo  "Gitaly must be running for the next step. Execute"
	if use systemd; then
		einfo "systemctl --job-mode=ignore-dependencies start ${PN}-${PREV_SLOT}-gitaly.service"
	else
		einfo "\$ rc-service gitlab-gitaly-${PREV_SLOT} start"
	fi
	einfon "Hit <Enter> to continue "
	local answer
	read -r answer
	einfo "Migrating database ..."
	su -l ${GIT_USER} -s /bin/sh -c "
		export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
		cd ${DEST_DIR}
		${BUNDLE} exec rake db:migrate RAILS_ENV=${RAILS_ENV}" \
			|| die "failed to migrate database."
	einfo "Stop the running Gitaly now. Execute"
	if use systemd; then
		einfo "systemctl stop ${PN}-${PREV_SLOT}-gitaly.service"
	else
		einfo "\$ rc-service gitlab-gitaly-${PREV_SLOT} stop"
	fi
	einfon "Hit <Enter> to continue "
	local answer
	read -r answer
}

pkg_config_do_upgrade_clear_redis_cache() {
	einfo "Clean up cache ..."
	su -l ${GIT_USER} -s /bin/sh -c "
		export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
		cd ${DEST_DIR}
		${BUNDLE} exec rake cache:clear RAILS_ENV=${RAILS_ENV}" \
			|| die "failed to run cache:clear"
}

pkg_config_do_upgrade_configure_git() {
	einfo "Configure Git to enable packfile bitmaps ..."
	su -l ${GIT_USER} -s /bin/sh -c "
		git config --global repack.writeBitmaps true" \
			|| die "failed to configure Git"
}

pkg_config_do_upgrade_check_background_migrations() {
	# ensure that any background migrations have been fully completed
	# see /opt/gitlab/gitlabhq-${SLOT}/doc/update/README.md
	einfo "Checking for background migrations..."
	local bm rails_cmd="'puts Gitlab::BackgroundMigration.remaining'"
	bm=$(su -l ${GIT_USER} -s /bin/sh -c "
		export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
		cd ${BASE_DIR}/${PN}
		${BUNDLE} exec rails runner -e ${RAILS_ENV} ${rails_cmd}" \
			|| die "failed to check for background migrations")
	if [ "${bm}" != "0" ]; then
		elog "The new version may require a set of background migrations to be finished."
		elog "For more information see:"
		elog "https://gitlab.com/gitlab-org/gitlab-foss/-/blob/master/doc/update/README.md#checking-for-background-migrations-before-upgrading"
		die "Number of remainig background migrations is ${bm}"
	else
		elog "OK: No remainig background migrations found."
	fi
}

pkg_config_do_upgrade() {
	# do the upgrade
	LATEST_DEST=$(test -n "${LATEST_DEST}" && echo ${LATEST_DEST} || \
		find /opt/gitlab -maxdepth 1 -iname "${PN}"'-*' -and -type d \
			-and -not -iname "${PN}-${SLOT}" | sort -rV | head -n1)

	if [[ -z "${LATEST_DEST}" || ! -d "${LATEST_DEST}" ]]; then
		einfon "Please enter the path to your latest Gitlab instance:"
		while true; do
			read -r LATEST_DEST
			test -d ${LATEST_DEST} && break ||\
				eerror "Please specify a valid path to your Gitlab instance!"
		done
	else
		einfo "Found your latest Gitlab instance at \"${LATEST_DEST}\"."
	fi
	PREV_SLOT=${LATEST_DEST##*-}
	# this global variable is used in pkg_config_do_upgrade_migrate_database()

	local backup_rake_cmd="rake gitlab:backup:create RAILS_ENV=${RAILS_ENV}"
	einfo "Please make sure that you've created a backup"
	einfo "and stopped your running Gitlab instance: "
	elog "\$ cd \"${LATEST_DEST}\""
	elog "\$ sudo -u ${GIT_USER} ${BUNDLE} exec ${backup_rake_cmd}"
	elog "\$ systemctl stop ${PN}.target"
	elog "or"
	elog "\$ rc-service ${PN} stop"
	elog ""

	einfon "Proceed? [Y|n] "
	read -r proceed
	if [[ !( $proceed =~ ^(y|Y|)$ ) ]]; then
		einfo "Aborting migration"
		return 1
	fi

	pkg_config_do_upgrade_check_background_migrations

	if [[ ${LATEST_DEST} != ${DEST_DIR} ]]; then
		einfo "Found update: Migration from \"${LATEST_DEST}\" to \"${DEST_DIR}\"."

		pkg_config_do_upgrade_migrate_data

		pkg_config_do_upgrade_migrate_configuration
		local ret=$?
		if [ $ret -ne 0 ]; then return $ret; fi

	fi

	pkg_config_do_upgrade_migrate_database

	pkg_config_do_upgrade_clear_redis_cache

	pkg_config_do_upgrade_configure_git
}

pkg_config_initialize() {
	# check config and initialize database
	## Check config files existence ##
	einfo "Checking configuration files ..."

	if [ ! -r "${CONF_DIR}/database.yml" ]; then
		eerror "Copy \"${CONF_DIR}/database.yml.*\" to \"${CONF_DIR}/database.yml\""
		eerror "and edit this file in order to configure your database settings for"
		eerror "\"${RAILS_ENV}\" environment."
		die
	fi
	if [ ! -r "${CONF_DIR}/gitlab.yml" ]; then
		eerror "Copy \"${CONF_DIR}/gitlab.yml.example\" to \"${CONF_DIR}/gitlab.yml\""
		eerror "and edit this file in order to configure your GitLab settings"
		eerror "for \"${RAILS_ENV}\" environment."
		die
	fi

	einfo  "Gitaly must be running for the next step. Execute"
	if use systemd; then
		einfo "systemctl --job-mode=ignore-dependencies start ${PN}-${SLOT}-gitaly.service"
	else
		einfo "\$ rc-service gitaly-${SLOT} start"
	fi
	einfon "Hit <Enter> to continue "
	local answer pw email
	read -r answer
	einfon "Set the Administrator/root password: "
	read -sr pw
	einfo
	einfon "Set the Administrator/root email: "
	read -r email
	einfo "Initializing database ..."
	su -l ${GIT_USER} -s /bin/sh -c "
		export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
		cd ${DEST_DIR}
		${BUNDLE} exec rake gitlab:setup RAILS_ENV=${RAILS_ENV} \
			GITLAB_ROOT_PASSWORD=${pw} GITLAB_ROOT_EMAIL=${email}" \
			|| die "failed to run rake gitlab:setup"
}

pkg_config() {
	local proceed ret=0

	einfon "Is this an upgrade of an existing installation? [Y|n] "
	local do_upgrade=""
	while true
	do
		read -r do_upgrade
		if   [[ $do_upgrade =~ ^(n|N|)$ ]]; then do_upgrade="" && break
		elif [[ $do_upgrade =~ ^(y|Y)$  ]]; then do_upgrade=1  && break
		else eerror "Please type either \"y\" or \"n\" ... "; fi
	done

	if [[ $do_upgrade ]]; then
		einfon "Is this an upgrade from a >=13.6.2-r4 version? [Y|n] "
		read -r proceed
		if [[ $proceed =~ ^(n|N)$ ]]; then
			ewarn "WARNING: You can't upgrade from a version <13.6.2-r4 here!"
			einfo "Aborting migration"
			return
		fi
		pkg_config_do_upgrade
		local ret=$?
		if [ $ret -ne 0 ]; then return $ret; fi
	else
		einfon "Is this a new installation? [Y|n] "
		read -r proceed
		if [[ $proceed =~ ^(y|Y)$ ]]; then
			pkg_config_initialize
		fi
	fi

	## (Re-)Link gitlab_shell_secret into gitlab-shell
	if [ -L "${GITLAB_SHELL}/.gitlab_shell_secret" ]; then
		rm "${GITLAB_SHELL}/.gitlab_shell_secret"
	fi
	ln -s "${DEST_DIR}/.gitlab_shell_secret" "${GITLAB_SHELL}/.gitlab_shell_secret"

	einfo
	einfo "Please select the gitlabhq slot now. Run:"
	einfo "\$ eselect gitlabhq set ${PN}-${SLOT}"
	einfo "It's recommended to use the same slot with gitaly. Run:"
	einfo "\$ eselect gitlab-gitaly set gitlab-gitaly-${SLOT}"
	einfo "Then start gitlab with"
	if use systemd; then
		einfo "\$ systemctl start ${PN}.target"
	else
		einfo "\$ rc-service ${PN} start"
	fi

	einfo
	einfo "You might want to check your application status. Run this:"
	einfo "\$ cd ${DEST_DIR}"
	einfo "\$ sudo -u ${GIT_USER} ${BUNDLE} exec rake gitlab:check RAILS_ENV=${RAILS_ENV}"
	einfo
	einfo "GitLab is prepared now."
	if [[ $do_upgrade ]]; then
		einfo "You should check the example nginx site configurations in the."
		einfo "${DEST_DIR}/lib/support/nginx/ folder "
		einfo "for any updates (e.g by diff with the previous version)."
	else
		einfo "To configure your nginx site have a look at the examples configurations"
		einfo "in the ${DEST_DIR}/lib/support/nginx/ folder."
	fi
}
