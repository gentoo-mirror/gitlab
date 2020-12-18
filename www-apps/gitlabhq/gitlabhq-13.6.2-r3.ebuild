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
	>=dev-lang/ruby-2.7[ssl]
	>=dev-vcs/gitlab-shell-13.13.0
	>=dev-vcs/gitlab-gitaly-13.6.1-r1
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
GIT_HOME="/var/lib/git"
DEST_DIR="/opt/${PN}-${SLOT}"
CONF_DIR="/etc/${PN}-${SLOT}"

GIT_REPOS="${GIT_HOME}/repositories"
GITLAB_SHELL="/var/lib/gitlab-shell"
GITLAB_GITALY="/var/lib/gitlab-gitaly-${SLOT}"

RAILS_ENV=${RAILS_ENV:-production}
BUNDLE="ruby /usr/bin/bundle"

pkg_setup() {
	enewgroup ${GIT_GROUP}
	enewuser ${GIT_USER} -1 -1 ${DEST_DIR} "${GIT_GROUP} redis"
}

all_ruby_unpack() {
	git-r3_src_unpack
}

each_ruby_prepare() {
	# modify gitlab settings
	sed -i \
		-e "s|/home/git/gitlab-shell|${GITLAB_SHELL}|" \
		-e "s|/home/git/gitaly|${GITLAB_GITALY}|" \
		-e "s|/home/git|${GITLAB_HOME}|" \
		-e "s|/tmp/sockets/private/gitaly.socket|/tmp/sockets/gitaly.socket|" \
		config/gitlab.yml.example || die "failed to filter gitlab.yml.example"

	# remove needless files
	rm .foreman .gitignore
	use postgres || rm config/database*.yml.postgresql
	use puma     || rm config/puma*
	use unicorn  || rm config/unicorn.rb.example*

	# Update pathes for unicorn
	if use unicorn; then
		sed -i \
			-e "s|/home/git/gitlab|${DEST_DIR}|" \
			-e "s|^stderr_path|#stderr_path|" \
			-e "s|^stdout_path|#stdout_path|" \
			config/unicorn.rb.example \
			|| die "failed to modify unicorn.rb.example"
	fi
}

src_install() {
	# DO NOT REMOVE - without this, the package won't install
	ruby-ng_src_install

	elog "Installing systemd unit files"
	for file in "${FILESDIR}/${PN}-${SLOT}"*.{service,target}
	do
		unit=$(basename $file)
		sed -e "s#@GIT_HOME@#${GIT_HOME}#g" \
		    -e "s#@DEST_DIR@#${DEST_DIR}#g" \
		    -e "s#@CONF_DIR@#${DEST_DIR}/config#" \
		    -e "s#@LOG_DIR@#${DEST_DIR}/log#" \
		    -e "s#@TMP_DIR@#${DEST_DIR}/tmp#g" \
		    -e "s#@SLOT@#${SLOT}#g" \
			"${file}" > "${T}/${unit}" || die "Failed to configure: $unit"
		systemd_dounit "${T}/${unit}" 
	done

	systemd_dotmpfilesd "${FILESDIR}/${PN}-${SLOT}-tmpfiles.conf"
}

each_ruby_install() {
	local dest="${DEST_DIR}"
	local conf="/etc/${PN}-${SLOT}"
	local temp="/var/tmp/${PN}-${SLOT}"
	local logs="/var/log/${PN}-${SLOT}"
	local uploads="${DEST_DIR}/public/uploads"

	## Prepare directories ##

	diropts -m750
	keepdir "${logs}"
	keepdir "${temp}"

	diropts -m755
	dodir "${dest}"
	dodir "${uploads}"

	dosym "${temp}" "${dest}/tmp"
	dosym "${logs}" "${dest}/log"

	## Install configs ##

	# Note that we cannot install the config to /etc and symlink
	# it to ${dest} since require_relative in config/application.rb
	# seems to get confused by symlinks. So let's install the config
	# to ${dest} and create a smylink to /etc/${P}
	dosym "${dest}/config" "${conf}"

	echo "export RAILS_ENV=${RAILS_ENV}" > "${D}/${dest}/.profile"

	## Install all others ##

	# remove needless dirs
	rm -Rf tmp log

	insinto "${dest}"
	doins -r ./

	## Make binaries executable
	exeinto "${dest}/bin"
	doexe bin/*
	exeinto "${dest}/qa/bin"
	doexe qa/bin/*

	## Install logrotate config ##

	dodir /etc/logrotate.d
	sed -e "s|@LOG_DIR@|${logs}|" \
		"${FILESDIR}"/gitlab.logrotate > "${D}"/etc/logrotate.d/${PN}-${SLOT} \
		|| die "failed to filter gitlab.logrotate"

	## Install gems via bundler ##

	cd "${D}/${dest}"

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

	local gemsdir=vendor/bundle/ruby/$(ruby_rbconfig_value 'ruby_version')

	# remove gems cache
	rm -Rf ${gemsdir}/cache

	# fix permissions
	fowners -R ${GIT_USER}:${GIT_GROUP} "${dest}" "${conf}" "${temp}" "${logs}"
	fperms o+Xr "${temp}" # Let nginx access the unicorn socket
	# fix QA Security Notice: world writable file(s)
	local wwfgems="gitlab-labkit nakayoshi_fork"
	local gem; for gem in ${wwfgems}; do
		fperms go-w -R ${dest}/${gemsdir}/gems/${gem}-*
	done

	## RC scripts ##
	local rcscript=${PN}-${SLOT}.init

	cp "${FILESDIR}/${rcscript}" "${T}" || die
	sed -i \
		-e "s|@GIT_USER@|${GIT_USER}|" \
		-e "s|@GIT_GROUP@|${GIT_USER}|" \
		-e "s|@SLOT@|${SLOT}|" \
		-e "s|@DEST_DIR@|${dest}|" \
		-e "s|@LOG_DIR@|${logs}|" \
		-e "s|@RESQUE_QUEUE@|${resque_queue}|" \
		"${T}/${rcscript}" \
		|| die "failed to filter ${rcscript}"

	newinitd "${T}/${rcscript}" "${PN}-${SLOT}"
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

	elog "  5. If this is a new installation, create a database for your GitLab instance."
	if use postgres; then
		elog "    If you have local PostgreSQL running, just copy&run:"
		elog "        su postgres"
		elog "        psql -c \"CREATE ROLE gitlab PASSWORD 'gitlab' \\"
		elog "            NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT LOGIN;\""
		elog "        createdb -E UTF-8 -O gitlab gitlab_${RAILS_ENV}"
		elog "    Note: You should change your password to something more random..."
		elog
		elog "    GitLab uses polymorphic associations which are not SQL-standard friendly."
		elog "    To get it work you must use this ugly workaround:"
		elog "        psql -U postgres -d gitlab"
		elog "        CREATE CAST (integer AS text) WITH INOUT AS IMPLICIT;"
		elog
		elog "    GitLab needs two PostgreSQL extensions: pg_trgm and btree_gist."
		elog "    To check the 'List of installed extensions' run:"
		elog "        psql -U postgres -d gitlab -c \"\dx\""
		elog "    To create the extensions if they are missing do:"
		elog "        psql -U postgres -d gitlab"
		elog "        CREATE EXTENSION IF NOT EXISTS pg_trgm;"
		elog "        CREATE EXTENSION IF NOT EXISTS btree_gist;"
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
	migrate_uploads=""
	while true
	do
		read -r migrate_uploads
		if [[ $migrate_uploads =~ ^(s|S)$ ]]    ; then migrate_uploads="" && break
		elif [[ $migrate_uploads =~ ^(c|C|)$ ]] ; then migrate_uploads=1  && break
		else eerror "Please type either \"c\" to continue or \"n\" to skip ... " ; fi
	done
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
	migrate_shared=""
	while true
	do
		read -r migrate_shared
		if [[ $migrate_shared =~ ^(s|S)$ ]]    ; then migrate_shared="" && break
		elif [[ $migrate_shared =~ ^(c|C|)$ ]] ; then migrate_shared=1  && break
		else eerror "Please type either \"c\" to continue or \"n\" to skip ... " ; fi
	done
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
	einfon "Migrate configuration, (C)ontinue or (s)kip? "
	while true
	do
		read -r migrate_config
		if [[ $migrate_config =~ ^(s|S)$ ]]    ; then migrate_config="" && break
		elif [[ $migrate_config =~ ^(c|C|)$ ]] ; then migrate_config=1  && break
		else eerror "Please type either \"c\" to continue or \"s\" to skip ... " ; fi
	done
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
			errmsg+= "\"CONFIG_PROTECT=${DEST_DIR} dispatch-conf\" by hand, re-run "
			errmsg+= "this routine and skip config migration to proceed."
			local mmsg="Manually run \"CONFIG_PROTECT=${DEST_DIR} dispatch-conf\" "
			mmsg+= "and re-run this routine and skip config migration to proceed."
			CONFIG_PROTECT="${DEST_DIR}" dispatch-conf || die "${errmsg}"
		else
			echo "${mmsg}" 
			return
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
			RAILS_ENV=${RAILS_ENV} NODE_ENV=${RAILS_ENV}" \
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

	einfo "Please make sure that you've created a backup"
	einfo "and stopped your running Gitlab instance: "
	elog "\$ cd \"${LATEST_DEST}\""
	elog "\$ sudo -u ${GIT_USER} ${BUNDLE} exec rake gitlab:backup:create RAILS_ENV=${RAILS_ENV}"
	elog "\$ /etc/init.d/${LATEST_DEST#*/opt/} stop"
	elog ""

	einfon "Proceeed? [Y|n] "
	read -r proceed
	if [[ !( $proceed =~ ^(y|Y|)$ ) ]]
	then
		einfo "Aborting migration"
		return
	fi

	if [[ ${LATEST_DEST} != ${DEST_DIR} ]] ;
	then
		einfo "Found major update, migrate data from \"$LATEST_DEST\":"

		pkg_config_do_upgrade_migrate_uploads

		pkg_config_do_upgrade_migrate_shared_data

		pkg_config_do_upgrade_migrate_configuration

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
			RAILS_ENV=${RAILS_ENV} NODE_ENV=${RAILS_ENV} \
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

pkg_config() {
	# Ask user whether this is the first installation
	einfon "Do you want to upgrade an existing installation? [Y|n] "
	do_upgrade=""
	while true
	do
		read -r do_upgrade
		if [[ $do_upgrade =~ ^(n|N|)$ ]]  ; then do_upgrade="" && break
		elif [[ $do_upgrade =~ ^(y|Y)$ ]] ; then do_upgrade=1  && break
		else eerror "Please type either \"y\" or \"n\" ... " ; fi
	done

	if [[ $do_upgrade ]] ; then

		pkg_config_do_upgrade

	else

		pkg_config_initialize

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

pkg_postrm() {
	local temp="/var/tmp/${PN}-${SLOT}"
	if [ -e "${temp}/MINOR-UPGRADE" ]; then
		rm "${temp}/MINOR-UPGRADE"
	else
		einfo "Removing temporary files from \"$temp\" ..."
		rm -r "$temp"
	fi
}
