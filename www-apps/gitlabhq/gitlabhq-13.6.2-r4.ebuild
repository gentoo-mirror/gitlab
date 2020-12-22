# Copyright 1999-2015 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header: $

EAPI="5"

# Mainteiner notes:
# - This ebuild uses Bundler to download and install all gems in deployment mode
#   (i.e. into isolated directory inside application). That's not Gentoo way how
#   it should be done, but GitLab has too many dependencies that it will be too
#   difficult to maintain them via ebuilds.

USE_RUBY="ruby27"

EGIT_REPO_URI="https://gitlab.com/gitlab-org/gitlab-foss.git"
EGIT_COMMIT="v${PV}"
EGIT_CHECKOUT_DIR="${WORKDIR}/all"

inherit eutils ruby-ng versionator user linux-info systemd git-r3

DESCRIPTION="GitLab is a complete DevOps platform"
HOMEPAGE="https://gitlab.com/gitlab-org/gitlab-foss"

LICENSE="MIT"
RESTRICT="network-sandbox splitdebug strip"
SLOT=$(get_version_component_range 1-2)
KEYWORDS="~amd64 ~x86"
IUSE="favicon gitaly_git kerberos mysql +postgres -puma +unicorn"
REQUIRED_USE="
	^^ ( puma unicorn )
	^^ ( mysql postgres )"
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
#   mysql				virtual/mysql
#
GEMS_DEPEND="
	app-crypt/gpgme
	dev-libs/icu
	dev-libs/libxml2
	dev-libs/libxslt
	dev-util/ragel
	dev-libs/yajl
	>=net-libs/nodejs-12
	postgres? ( >=dev-db/postgresql-11 )
	mysql? ( virtual/mysql )
	net-libs/http-parser"
DEPEND="${GEMS_DEPEND}
	acct-user/git[gitlab]
	acct-group/git
	>=dev-lang/ruby-2.7[ssl]
	>=dev-vcs/gitlab-shell-13.13.0
	dev-vcs/gitlab-gitaly:${SLOT}
	>=www-servers/gitlab-workhorse-8.56.0
	!gitaly_git? ( >=dev-vcs/git-2.29.0[pcre,pcre-jit] )
	gitaly_git? ( dev-vcs/gitlab-gitaly[gitaly_git] )
	app-eselect/eselect-gitlabhq
	net-misc/curl
	virtual/ssh
	>=sys-apps/yarn-1.15.0
	dev-libs/re2
	<=sys-apps/gawk-4.9999"
RDEPEND="${DEPEND}
	>=dev-db/redis-5.0
	virtual/mta
	kerberos? ( app-crypt/mit-krb5 )
	favicon? ( media-gfx/graphicsmagick )"
ruby_add_bdepend "
	virtual/rubygems
	>=dev-ruby/bundler-2:2"

RUBY_PATCHES=(
	"${PN}-${SLOT}-fix-checks-gentoo.patch"
	"${PN}-${SLOT}-fix-sendmail-param.patch"
)

GIT_USER="git"
GIT_GROUP="git"
GIT_HOME="/var/lib/gitlab"
BASE_DIR="/opt/gitlab"
DEST_DIR="${BASE_DIR}/${PN}-${SLOT}"
CONF_DIR="/etc/${PN}-${SLOT}"
WORKHORSE_BIN="${BASE_DIR}/gitlab-workhorse/bin"

GIT_REPOS="${GIT_HOME}/repositories"
GITLAB_SHELL="${BASE_DIR}/gitlab-shell"
GITLAB_GITALY="${BASE_DIR}/gitlab-gitaly-${SLOT}"
GITALY_CONF="/etc/gitlab-gitaly-${SLOT}"

RAILS_ENV=${RAILS_ENV:-production}
NODE_ENV=${RAILS_ENV:-production}
BUNDLE="ruby /usr/bin/bundle"

all_ruby_unpack() {
	git-r3_src_unpack
}

each_ruby_prepare() {
	# Update paths for gitlab
	# Note: Order of -e expressions is important here
	sed -i \
		-e "s|/sockets/private/|/sockets/|g" \
		-e "s|/home/git/gitlab-shell|${GITLAB_SHELL}|g" \
		-e "s|/home/git/gitlab/|${DEST_DIR}/|g" \
		-e "s|/home/git/gitaly|${GITLAB_GITALY}|g" \
		-e "s|/home/git|${GIT_HOME}|g" \
		config/gitlab.yml.example || die "failed to filter gitlab.yml.example"

	# remove needless files
	rm .foreman .gitignore
	use postgres || rm config/database*.yml.postgresql
	use puma     || rm config/puma*
	use unicorn  || rm config/unicorn.rb.example*

	# Update paths for unicorn
	if use unicorn; then
		sed -i \
			-e "s|/home/git/gitlab/tmp/|${DEST_DIR}/tmp/|g" \
			-e "s|/home/git/gitlab|${DEST_DIR}|g" \
			-e "s|^stderr_path|#stderr_path|g" \
			-e "s|^stdout_path|#stdout_path|g" \
			config/unicorn.rb.example \
			|| die "failed to modify unicorn.rb.example"
	fi
}

find_files() {
	local f t="${1}"
	for f in $(find ${ED}${2} -type ${t}) ; do
		echo $f | sed "s#${ED}##"
	done
}

continue_or_skip() {
	local answer=""
	while true
	do
		read -r answer
		if   [[ $answer =~ ^(s|S)$ ]] ; then answer="" && break
		elif [[ $answer =~ ^(c|C)$ ]] ; then answer=1  && break
		else echo "Please type either \"c\" to continue or \"s\" to skip ... " >&2
		fi
	done
	echo $answer
}

src_install() {
	# DO NOT REMOVE - without this, the package won't install
	ruby-ng_src_install

	local file webserver webserver_bin webserver_name
	if use puma; then
		webserver="puma"
		webserver_bin="puma"
		webserver_name="Puma"
		webserver_unit="${T}/${PN}-${SLOT}-puma.service"
	elif use unicorn; then
		webserver="unicorn"
		webserver_bin="unicorn_rails"
		webserver_name="Unicorn"
		webserver_unit="${T}/${PN}-${SLOT}-unicorn.service"
	fi

	elog "Installing systemd unit files"
	sed -e "s#@DEST_DIR@#${DEST_DIR}#g" \
		-e "s#@CONF_DIR@#${DEST_DIR}/config#g" \
		-e "s#@TMP_DIR@#${DEST_DIR}/tmp#g" \
		-e "s#@SLOT@#${SLOT}#g" \
		-e "s#@WEBSERVER@#${webserver}#g" \
		-e "s#@WEBSERVER_BIN@#${webserver_bin}#g" \
		-e "s#@WEBSERVER_NAME@#${webserver_name}#g" \
		"${FILESDIR}/${PN}-${SLOT}"-webserver.service_model \
		> $webserver_unit || die "Failed to configure: $webserver_unit"

	for file in "${FILESDIR}/${PN}-${SLOT}"*.{service,target}
	do
		unit=$(basename $file)
		sed -e "s#@BASE_DIR@#${BASE_DIR}#g" \
			-e "s#@DEST_DIR@#${DEST_DIR}#g" \
			-e "s#@CONF_DIR@#${DEST_DIR}/config#g" \
			-e "s#@TMP_DIR@#${DEST_DIR}/tmp#g" \
			-e "s#@WORKHORSE_BIN@#${WORKHORSE_BIN}#g" \
			-e "s#@SLOT@#${SLOT}#g" \
			-e "s#@WEBSERVER@#${webserver}#g" \
			-e "s#@WEBSERVER_BIN@#${webserver_bin}#g" \
			-e "s#@WEBSERVER_NAME@#${webserver_name}#g" \
			"${file}" > "${T}/${unit}" || die "Failed to configure: $unit"
		systemd_dounit "${T}/${unit}"
	done

	systemd_dotmpfilesd "${FILESDIR}/${PN}-${SLOT}-tmpfiles.conf"

	## RC script ##
	local rcscript=${PN}-${SLOT}.init

	cp "${FILESDIR}/${rcscript}" "${T}" || die
	sed -i \
		-e "s|@RAILS_ENV@|${RAILS_ENV}|g" \
		-e "s|@GIT_USER@|${GIT_USER}|g" \
		-e "s|@GIT_GROUP@|${GIT_GROUP}|g" \
		-e "s|@SLOT@|${SLOT}|g" \
		-e "s|@DEST_DIR@|${DEST_DIR}|g" \
		-e "s|@LOG_DIR@|${logs}|g" \
		-e "s|@GITLAB_GITALY@|${GITLAB_GITALY}|g" \
		-e "s|@GITALY_CONF@|${GITALY_CONF}|g" \
		-e "s|@WORKHORSE_BIN@|${WORKHORSE_BIN}|g" \
		-e "s#@WEBSERVER@#${webserver}#g" \
		-e "s#@WEBSERVER_BIN@#${webserver_bin}#g" \
		-e "s#@WEBSERVER_NAME@#${webserver_name}#g" \
		"${T}/${rcscript}" \
		|| die "failed to filter ${rcscript}"

	newinitd "${T}/${rcscript}" "${PN}-${SLOT}"
}

each_ruby_install() {
	local temp="/var/tmp/${PN}-${SLOT}"
	local logs="/var/log/${PN}-${SLOT}"
	local uploads="${DEST_DIR}/public/uploads"

	## Prepare directories ##

	diropts -m750
	keepdir "${logs}"
	keepdir "${temp}"

	diropts -m755
	dodir "${DEST_DIR}"
	dodir "${uploads}"

	dosym "${temp}" "${DEST_DIR}/tmp"
	dosym "${logs}" "${DEST_DIR}/log"

	## Install configs ##

	# Note that we cannot install the config to /etc and symlink
	# it to ${DEST_DIR} since require_relative in config/application.rb
	# seems to get confused by symlinks. So let's install the config
	# to ${DEST_DIR} and create a smylink to /etc/${P}
	dosym "${DEST_DIR}/config" "${CONF_DIR}"

	echo "export RAILS_ENV=${RAILS_ENV}" > "${D}/${DEST_DIR}/.profile"

	## Install all others ##

	# remove needless dirs
	rm -Rf tmp log

	insinto "${DEST_DIR}"
	doins -r ./

	# make binaries executable
	exeinto "${DEST_DIR}/bin"
	doexe bin/*
	exeinto "${DEST_DIR}/qa/bin"
	doexe qa/bin/*

	## Install logrotate config ##

	dodir /etc/logrotate.d
	sed -e "s|@LOG_DIR@|${logs}|g" \
		"${FILESDIR}"/gitlab.logrotate > "${D}"/etc/logrotate.d/${PN}-${SLOT} \
		|| die "failed to filter gitlab.logrotate"

	## Install gems via bundler ##

	cd "${D}/${DEST_DIR}"

	local without="development test coverage omnibus"
	local flag; for flag in ${WITHOUTflags}; do
		without+="$(use $flag || echo ' '$flag)"
	done
	${BUNDLE} config set deployment 'true'
	${BUNDLE} config set without "${without}"
	${BUNDLE} config build.gpgm --use-system-libraries
	${BUNDLE} config build.nokogiri --use-system-libraries
	${BUNDLE} config build.yajl-ruby --use-system-libraries

	einfo "Current ruby version is \"$(ruby --version)\""

	einfo "Running bundle install ..."
	${BUNDLE} install --jobs=$(nproc) || die "bundler failed"

	## Clean ##

	local ruby_vpath=$(ruby_rbconfig_value 'ruby_version')

	# remove gems cache
	rm -Rf vendor/bundle/ruby/${ruby_vpath}/cache

	# fix permissions
	fowners -R ${GIT_USER}:${GIT_GROUP} "${DEST_DIR}" "${CONF_DIR}" "${temp}" "${logs}"
	fperms o+Xr "${temp}" # Let nginx access the puma/unicorn socket

	# fix QA Security Notice: world writable file(s)
	elog "Fixing permissions of world writable files"
	local gemsdir="vendor/bundle/ruby/${ruby_vpath}/gems"
	local wwfgems="gitlab-labkit nakayoshi_fork"
	# If we are using wildcards, the shell fills them without prefixing ${ED}. Thus
	# we would target a file list from the real system instead from the sandbox.
	for gem in ${wwfgems}; do
		for file in $(find_files "d,f" "${DEST_DIR}/${gemsdir}/${gem}-*") ; do
			fperms go-w $file
		done
	done
	# in the nakayoshi_fork gem all files are also executable
	for file in $(find_files "f" "${DEST_DIR}/${gemsdir}/nakayoshi_fork-*") ; do
		fperms a-x $file
	done
}

pkg_preinst() {
	# if the tmp dir for our ${SLOT} exists
	# set a flag file to keep it (see pkg_postrm())
	local temp="/var/tmp/${PN}-${SLOT}"
	if [ -e "$temp" ]; then
		einfo "Keeping temporary files from \"$temp\" ..."
		touch "${temp}/MINOR-UPGRADE"
	fi
}

pkg_postinst() {
	if [ ! -e "${GIT_HOME}/.gitconfig" ]; then
		einfo "Setting git user in ${GIT_HOME}/.gitconfig, feel free to "
		einfo "modify this file according to your needs!"
		su -l ${GIT_USER} -s /bin/sh -c "
			git config --global core.autocrlf 'input';
			git config --global gc.auto 0;
			git config --global user.email 'gitlab@localhost';
			git config --global user.name 'GitLab'
			git config --global repack.writeBitmaps true" \
			|| die "failed to setup git configuration"
	fi

	elog "If this is a new installation, proceed with the following steps:"
	elog
	elog "  1. Copy ${CONF_DIR}/gitlab.yml.example to ${CONF_DIR}/gitlab.yml"
	elog "     and edit this file in order to configure your GitLab settings."
	elog
	elog "  2. Copy ${CONF_DIR}/database.yml.* to ${CONF_DIR}/database.yml"
	elog "     and edit this file in order to configure your database settings"
	elog "     for \"${RAILS_ENV}\" environment."
	elog
	elog "  3. Copy ${CONF_DIR}/initializers/rack_attack.rb.example"
	elog "     to ${CONF_DIR}/initializers/rack_attack.rb"
	elog
	elog "  4. Copy ${CONF_DIR}/resque.yml.example to ${CONF_DIR}/resque.yml"
	elog "     and edit this file in order to configure your Redis settings"
	elog "     for \"${RAILS_ENV}\" environment."
	elog

	if use unicorn; then
		elog "  4a. Copy ${CONF_DIR}/unicorn.rb.example to ${CONF_DIR}/unicorn.rb"
		elog
	fi

	if use puma; then
		elog "  4a. Puma support isn't ready yet. Sorry."
		elog
	fi

	elog "  5. If this is a new installation, create a database for your GitLab instance."
	if use postgres; then
		elog "     If you have local PostgreSQL running, just copy&run:"
		elog "         su postgres"
		elog "         psql -c \"CREATE ROLE gitlab PASSWORD 'gitlab' \\"
		elog "             NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT LOGIN;\""
		elog "         createdb -E UTF-8 -O gitlab gitlab_${RAILS_ENV}"
		elog "     Note: You should change your password to something more random..."
		elog
		elog "     GitLab uses polymorphic associations which are not SQL-standard friendly."
		elog "     To get it work you must use this ugly workaround:"
		elog "         psql -U postgres -d gitlab"
		elog "         CREATE CAST (integer AS text) WITH INOUT AS IMPLICIT;"
		elog
		elog "     GitLab needs two PostgreSQL extensions: pg_trgm and btree_gist."
		elog "     To check the 'List of installed extensions' run:"
		elog "         psql -U postgres -d gitlab -c \"\dx\""
		elog "     To create the extensions if they are missing do:"
		elog "         psql -U postgres -d gitlab"
		elog "         CREATE EXTENSION IF NOT EXISTS pg_trgm;"
		elog "         CREATE EXTENSION IF NOT EXISTS btree_gist;"
		elog
	fi
	elog "  6. Execute the following command to finalize your setup:"
	elog "         emerge --config \"=${CATEGORY}/${PF}\""
	elog "     Note: Do not forget to start Redis server."
	elog
	elog "To update an existing instance,"
	elog "run the following command and choose upgrading when prompted:"
	elog "    emerge --config \"=${CATEGORY}/${PF}\""
	elog
	elog "Important: Do not remove the earlier version prior migration!"

	if linux_config_exists; then
		if linux_chkconfig_present PAX ; then
			elog  ""
			ewarn "Warning: PaX support is enabled!"
			ewarn "You must disable mprotect for ruby. Otherwise FFI will"
			ewarn "trigger mprotect errors that are hard to trace. Please run: "
			ewarn "    paxctl -m ruby"
		fi
	else
		elog  ""
		einfo "Important: Cannot find a linux kernel configuration!"
		einfo "So cannot check for PaX support."
		einfo "If CONFIG_PAX is set, you should disable mprotect for ruby"
		einfo "since FFI may trigger mprotect errors."
	fi
}

pkg_config_do_upgrade_migrate_uploads() {
	einfo "Migrating uploads ..."
	einfo "This will move your uploads from \"$LATEST_DEST\" to \"${DEST_DIR}\"."
	einfon "(C)ontinue or (s)kip? "
	local migrate_uploads=$(continue_or_skip)
	if [[ $migrate_uploads ]] ; then
		su -l ${GIT_USER} -s /bin/sh -c "
			rm -rf ${DEST_DIR}/public/uploads && \
			mv ${LATEST_DEST}/public/uploads ${DEST_DIR}/public/uploads" \
			|| die "failed to migrate uploads."

		# Fix permissions
		find "${DEST_DIR}/public/uploads/" -type d -exec chmod 0700 {} \;
	fi
}

pkg_config_do_upgrade_migrate_shared_data() {
	einfo "Migrating shared data ..."
	einfo "This will move your shared data from \"$LATEST_DEST\" to \"${DEST_DIR}\"."
	einfon "(C)ontinue or (s)kip? "
	local migrate_shared=$(continue_or_skip)
	if [[ $migrate_shared ]] ; then
		su -l ${GIT_USER} -s /bin/sh -c "
			rm -rf ${DEST_DIR}/shared && \
			mv ${LATEST_DEST}/shared ${DEST_DIR}/shared" \
			|| die "failed to migrate shared data."

		# Fix permissions
		find "${DEST_DIR}/shared/" -type d -exec chmod 0700 {} \;
	fi
}

pkg_config_do_upgrade_migrate_configuration() {
	local conf
	einfon "Migrate configuration, (C)ontinue or (s)kip? "
	local migrate_config=$(continue_or_skip)
	if [[ $migrate_config ]]
	then
		for conf in database.yml gitlab.yml resque.yml unicorn.rb secrets.yml ; do
			einfo "Migration config file \"$conf\" ..."
			cp -p "${LATEST_DEST}/config/${conf}" "${DEST_DIR}/config/"
			sed -i \
			    -e "s|$(basename $LATEST_DEST)|${PN}-${SLOT}|g" \
			    "${DEST_DIR}/config/$conf"

			example="${DEST_DIR}/config/${conf}.example"
			test -f "${example}" && \
				cp -p "${example}" "${DEST_DIR}/config/._cfg0000_${conf}"
		done

		# if the user's console is not 80x24, it is better to manually run dispatch-conf
		einfon "Merge config with dispatch-conf, (C)ontinue or (q)uit? "
		while true
		do
			read -r merge_config
			if [[ $merge_config =~ ^(q|Q)$ ]]    ; then merge_config="" && break
			elif [[ $merge_config =~ ^(c|C|)$ ]] ; then merge_config=1  && break
			else eerror "Please type either \"c\" to continue or \"q\" to quit ... " ; fi
		done
		if [[ $merge_config ]] ; then
			local errmsg="failed to automatically migrate config, run "
			errmsg+="\"CONFIG_PROTECT=${DEST_DIR} dispatch-conf\" by hand, re-run "
			errmsg+="this routine and skip config migration to proceed."
			local mmsg="Manually run \"CONFIG_PROTECT=${DEST_DIR} dispatch-conf\" "
			mmsg+="and re-run this routine and skip config migration to proceed."
			CONFIG_PROTECT="${DEST_DIR}" dispatch-conf || die "${errmsg}"
		else
			echo "${mmsg}" 
			return 1
		fi
	fi
}

pkg_config_do_upgrade_clean_up_old_gems() {
	einfo "Clean up old gems ..."
	su -l ${GIT_USER} -s /bin/sh -c "
		export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
		cd ${DEST_DIR}
		${BUNDLE} clean" \
			|| die "failed to clean up old gems ..."
}

pkg_config_do_upgrade_migrate_database() {
	einfo "Migrating database ..."
	su -l ${GIT_USER} -s /bin/sh -c "
		export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
		cd ${DEST_DIR}
		${BUNDLE} exec rake db:migrate RAILS_ENV=${RAILS_ENV}" \
			|| die "failed to migrate database."
}

pkg_config_do_upgrade_clear_redis_cache() {
	einfo "Clear redis cache ..."
	su -l ${GIT_USER} -s /bin/sh -c "
		export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
		cd ${DEST_DIR}
		${BUNDLE} exec rake cache:clear RAILS_ENV=${RAILS_ENV}" \
			|| die "failed to run cache:clear"
}

pkg_config_do_upgrade_clean_up_assets() {
	einfo "Clean up assets ..."
	su -l ${GIT_USER} -s /bin/sh -c "
		export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
		cd ${DEST_DIR}
		${BUNDLE} exec rake gitlab:assets:clean \
			RAILS_ENV=${RAILS_ENV} NODE_ENV=${NODE_ENV}" \
			|| die "failed to run gitlab:assets:clean"
}

pkg_config_do_upgrade_configure_git() {
	einfo "Configure Git to generate packfile bitmaps ..."
	su -l ${GIT_USER} -s /bin/sh -c "
		git config --global repack.writeBitmaps true" \
			|| die "failed to configure Git"
}

pkg_config_do_upgrade() {
	# do the upgrade
	LATEST_DEST=$(test -n "${LATEST_DEST}" && echo ${LATEST_DEST} || \
		find /opt -maxdepth 1 -iname "${PN}"'-*' -and -type d | \
		sort -rV | head -n1)

	if [[ -z "${LATEST_DEST}" || ! -d "${LATEST_DEST}" ]] ; then
		einfon "Please enter the path to your latest Gitlab instance:"
		while true
		do
			read -r LATEST_DEST
			test -d ${LATEST_DEST} && break ||\
				eerror "Please specify a valid path to your Gitlab instance!"
		done
	else
		einfo "Found your latest Gitlab instance at \"${LATEST_DEST}\"."
	fi

	local backup_rake_cmd="rake gitlab:backup:create RAILS_ENV=${RAILS_ENV}"
	einfo "Please make sure that you've created a backup"
	einfo "and stopped your running Gitlab instance: "
	elog "\$ cd \"${LATEST_DEST}\""
	elog "\$ sudo -u ${GIT_USER} ${BUNDLE} exec ${backup_rake_cmd}"
	elog "\$ systemctl stop ${PN}.target"
	elog "or"
	elog "\$ /etc/init.d/${LATEST_DEST#*/opt/} stop"
	elog ""

	einfon "Proceed? [Y|n] "
	read -r proceed
	if [[ !( $proceed =~ ^(y|Y|)$ ) ]]
	then
		einfo "Aborting migration"
		return 1
	fi

	if [[ ${LATEST_DEST} != ${DEST_DIR} ]] ;
	then
		einfo "Found major update, migrate data from \"$LATEST_DEST\":"

		pkg_config_do_upgrade_migrate_uploads

		pkg_config_do_upgrade_migrate_shared_data

		pkg_config_do_upgrade_migrate_configuration
		local ret=$?
		if [ $ret -ne 0 ]; then return $ret; fi

	fi

	pkg_config_do_upgrade_clean_up_old_gems

	pkg_config_do_upgrade_migrate_database

	pkg_config_do_upgrade_clear_redis_cache

	pkg_config_do_upgrade_clean_up_assets

	pkg_config_do_upgrade_configure_git
}

pkg_config_initialize() {
	# check config and initialize database
	## Check config files existence ##
	einfo "Checking configuration files ..."

	if [ ! -r "${CONF_DIR}/database.yml" ] ; then
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

	einfo "Initializing database ..."
	su -l ${GIT_USER} -s /bin/sh -c "
		export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
		cd ${DEST_DIR}
		${BUNDLE} exec rake gitlab:setup RAILS_ENV=${RAILS_ENV}" \
			|| die "failed to run rake gitlab:setup"
}

pkg_config_compile_assets() {
	einfo "Compile assets ..."
	su -l ${GIT_USER} -s /bin/sh -c "
		export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
		cd ${DEST_DIR}
		echo \"Fixing https://gitlab.com/gitlab-org/gitlab-ce/issues/38275 ...\"
		yarn add ajv@^4.0.0
		yarn install --production=false --pure-lockfile --no-progress
		${BUNDLE} exec rake gitlab:assets:compile \
			RAILS_ENV=${RAILS_ENV} NODE_ENV=${NODE_ENV} \
			NODE_OPTIONS=\"--max-old-space-size=4096\"" \
			|| die "failed to run yarn install and gitlab:assets:compile"
}

pkg_config_compile_po_files() {
	einfo "Compile GetText PO files ..."
	su -l ${GIT_USER} -s /bin/sh -c "
		export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
		cd ${DEST_DIR}
		${BUNDLE} exec rake gettext:compile RAILS_ENV=${RAILS_ENV}" \
			|| die "failed to compile GetText PO files"
}

pkg_config_do_fhs() {
	# do the FHS migration
	LATEST_DEST="/opt/gitlabhq-13.6"

	if [[ -z "${LATEST_DEST}" || ! -d "${LATEST_DEST}" ]] ; then
		einfo "The automatic migration to FHS compliant installation paths"
		einfo "is supported for slot 13.6 gitlabhq versions only. If this is"
		einfo "not an upgrade from www-apps/gitlabhq-13.6.2-r2 to -r4 please"
		einfo "try a manual migration. Reading the ebuild code and the news"
		einfo "\"FHS compliant directory structure\" will tell you what to do."
		return 1
	else
		einfo "Found your latest Gitlab instance at \"${LATEST_DEST}\"."
	fi

	local backup_rake_cmd="rake gitlab:backup:create RAILS_ENV=${RAILS_ENV}"
	einfo "Please make sure that you've created a backup"
	einfo "and stopped your running Gitlab instance: "
	elog "\$ cd \"${LATEST_DEST}\""
	elog "\$ sudo -u ${GIT_USER} ${BUNDLE} exec ${backup_rake_cmd}"
	elog "\$ systemctl stop ${PN}.target"
	elog "or"
	elog "\$ /etc/init.d/${LATEST_DEST#*/opt/} stop"
	elog ""

	einfo "First we will move the contents of /home/git to ${GIT_HOME}"
	einfon "(C)ontinue or (s)kip? "
	local proceed=$(continue_or_skip)
	if [[ $proceed ]] ; then
		# remove .gitconfig and .ssh/ created by pkg_postinst() here and the
		# gitlab-shell ebuild respectively because of the new empty git HOME
		rm -rf ${GIT_HOME}/.ssh ${GIT_HOME}/.gitconfig
		# remove the unneded gitlab -> /opt/gitlab/gitlabhq link
		rm -f /home/git/gitlab
		mv /home/git/.[a-zA-Z]* /home/git/* ${GIT_HOME} || \
			die "Failed to move git HOME content"
		rmdir /home/git || die
	fi

	einfo "Next we will fix the command path in ${GIT_HOME}/.ssh/authorized_keys"
	einfon "(C)ontinue or (s)kip? "
	proceed=$(continue_or_skip)
	if [[ $proceed ]] ; then
		sed -i -e "s|/var/lib/gitlab-shell|/opt/gitlab/gitlab-shell|" \
			${GIT_HOME}/.ssh/authorized_keys || die "Fixing authorized_keys failed"
	fi

	einfo "Now we will move the .gitlab_shell_secret to ${DEST_DIR} and"
	einfo "link to it in the new gitlab-shell dir. We will also create"
	einfo "the ${BASE_DIR}/${PN} symlink to the current slot."
	einfon "(C)ontinue or (s)kip? "
	proceed=$(continue_or_skip)
	if [[ $proceed ]] ; then
		mv /opt/gitlabhq-13.6/.gitlab_shell_secret ${DEST_DIR} || \
			die "Failed to move the .gitlab_shell_secret file"
		ln -s ${DEST_DIR}/.gitlab_shell_secret ${GITLAB_SHELL}/.gitlab_shell_secret || \
			die "Failed to link the .gitlab_shell_secret file"
		ln -s ${DEST_DIR} ${BASE_DIR}/${PN}  || \
			die "Failed to create the ${BASE_DIR}/${PN} symlink"
	fi

	einfo "Finally we migrate the data from \"$LATEST_DEST\":"
	einfon "(C)ontinue or (s)kip? "
	proceed=$(continue_or_skip)
	if [[ $proceed ]] ; then
		pkg_config_do_upgrade_migrate_uploads
		pkg_config_do_upgrade_migrate_shared_data
		pkg_config_do_upgrade_migrate_configuration
	fi

	einfo ""
	einfo "You have to adopt the config of your webserver to the new paths."
	einfo "For nginx e. g. that would at least be the new workhorse socket:"
	einfo "    unix:${BASE_DIR}/${PN}/tmp/sockets/gitlab-workhorse.socket"
	einfo ""
	einfo "There will be some leftover directories that we didn't remove"
	einfo "in case you have non-GitLab files there:"
	einfo "    /home/git/"
	einfo "    /var/lib/git/"
	einfo "    /var/lib/gitlab-shell/"
	einfo "We also did not remove the old"
	einfo "    /opt/gitlabhq -> gitlabhq-13.6/"
	einfo "    /opt/gitlabhq-13.6/"
	einfo ""
}

pkg_config() {
	einfo "Do you want to migrate to the new FHS compliant installation paths?"
	einfon "(Enter \"n\" if this is a new installation.) [Y|n] "
	local do_fhs="" ret=0
	while true
	do
		read -r do_fhs
		if [[ $do_fhs =~ ^(n|N|)$ ]]  ; then do_fhs="" && break
		elif [[ $do_fhs =~ ^(y|Y)$ ]] ; then do_fhs=1  && break
		else eerror "Please type either \"y\" or \"n\" ... " ; fi
	done

	if [[ $do_fhs ]] ; then
		pkg_config_do_fhs
		if [ $ret -ne 0 ]; then return; fi
	fi

	einfon "Is this an upgrade to a new slot? [Y|n] "
	local do_upgrade=""
	while true
	do
		read -r do_upgrade
		if [[ $do_upgrade =~ ^(n|N|)$ ]]  ; then do_upgrade="" && break
		elif [[ $do_upgrade =~ ^(y|Y)$ ]] ; then do_upgrade=1  && break
		else eerror "Please type either \"y\" or \"n\" ... " ; fi
	done

	if [[ $do_upgrade ]] ; then
		ewarn "WARNING: It's not recommended to run the \"emerge --config\""
		ewarn "of this \"${CATEGORY}/${PN}\" version for a new slot upgrade!"
		ewarn "This is untested and probably will fail."
		einfon "Proceed anyway? [Y|n] "
		read -r proceed
		if [[ $proceed =~ ^(y|Y)$ ]]
		then
			einfo "You've been warned!"
			sleep 5
			pkg_config_do_upgrade
			if [ $ret -ne 0 ]; then return; fi
		else
			einfo "Aborting migration"
			return
		fi
	else
		if [[ ! $do_fhs ]] ; then
			einfon "Is this a new installation? [Y|n] "
			read -r proceed
			if [[ $proceed =~ ^(y|Y)$ ]]
			then
				pkg_config_initialize
			fi
		fi
	fi

	pkg_config_compile_assets

	pkg_config_compile_po_files

	## (Re-)Link gitlab-shell-secret into gitlab-shell
	if test -L "${GITLAB_SHELL}/.gitlab_shell_secret"
	then
		rm "${GITLAB_SHELL}/.gitlab_shell_secret"
		ln -s "${DEST_DIR}/.gitlab_shell_secret" "${GITLAB_SHELL}/.gitlab_shell_secret"
	fi

	einfo "You might want to run this in order to check your application status:"
	einfo "\$ cd ${DEST_DIR}"
	einfo "\$ sudo -u ${GIT_USER} ${BUNDLE} exec rake gitlab:check RAILS_ENV=${RAILS_ENV}"
	einfo ""
	einfo "GitLab is prepared, now you should configure your web server."
}

pkg_postrm() { # see pkg_preinst()
	local temp="/var/tmp/${PN}-${SLOT}"
	if [ -e "${temp}/MINOR-UPGRADE" ]; then
		rm "${temp}/MINOR-UPGRADE"
	else
		einfo "Removing temporary files from \"$temp\" ..."
		rm -r "$temp"
	fi
}
