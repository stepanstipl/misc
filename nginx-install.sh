#!/bin/bash

# Script to set-up nginx server and simple website
# Supports CentOS/RHEL 5 & 6
# 
# No paramters, return 0 if success, otherwise 1
#
# Stepan Stipl <stepan@stipl.net>

NGINX_REPO='/etc/yum.repos.d/nginx.repo'
NGINX_GPG='http://nginx.org/keys/nginx_signing.key'

NGINX_INIT_CMD='/etc/init.d/nginx'

NGINX_SITE='/etc/nginx/conf.d/puppet_labs.conf'
NGINX_PORT='8080'
NGINX_SITE_DIR='/usr/share/nginx/puppet_labs'
NGINX_SITE_NAME='puppet_labs.local'
NGINX_CONTENT='https://raw.github.com/puppetlabs/exercise-webpage/master/index.html'

YUM_CMD='/usr/bin/yum'
IPTABLES_CMD='/sbin/iptables'
CHKCONFIG_CMD='/sbin/chkconfig'
RPM_CMD='/bin/rpm'
CURL_CMD='/usr/bin/curl'



# Some default in case detection would fail somehow
OS='centos'
OS_MAJOR='6'
FORCE=0

# Check if we have colors available, it looks good
COLORS=$(tput colors)
if [[ -n $COLORS && $COLORS -ge 8 ]]; then
        GREEN=$(tput setaf 2)
        RED=$(tput setaf 1)
        NOCOL=$(tput sgr0)
        BOLD=$(tput bold)
fi

echo_usage() {
        echo -e "nginx-install.sh [-f]"
        echo -e ""
	echo -e "This script will try to install ang setup nginx."
	echo -e "Supported OSs are RHEL & CentOS 5 & 6"
	echo -e ""
        echo -e "accepted arguments:"
        echo -e "\t-f\t- will overwrite any resources in case they exist"
        echo -e "\t-h\t- prints this help"
}

echo_ok() {
	printf '%*s%*s\n' "-70" "$*" "-10" "${GREEN}[OK]${NOCOL}"
	return $?
}

echo_fail() {
	printf '%*s%*s\n' "-70" "$*" "-10" "${RED}[FAIL]${NOCOL}" 1>&2
	return $?
}

echo_skip() {
	printf '%*s%*s\n' "-70" "$*" "-10" "[SKIP]"
	return $?
}

error_exit()
{
	echo_fail $1
	exit 1	 
}

test_pre() {
    # Make sure we're on CentOS or Red Hat 5/6
    grep -E '^(CentOS|Red Hat).*\s[56]+' -q /etc/redhat-release 1>/dev/null 2>&1 || error_exit "It doesn't look like we're on supported system"

    # Make sure we have permissions to do what we want
    [[ $EUID -eq 0 ]] || error_exit "This script needs to be run as root or with elevated priviledges"
    
    [[ -x ${YUM_CMD} ]] || error_exit "Can't find yum"
    [[ -x ${RPM_CMD} ]] || error_exit "Can't find rpm"
    [[ -x ${CURL_CMD} ]] || error_exit "Can't find curl"
    [[ -x ${IPTABLES_CMD} ]] || error_exit "Can't find iptables"
    [[ -x ${CHKCONFIG_CMD} ]] || error_exit "Can't find chkconfig"
}

setup_nginx_repo() {
	# If repo definition exists, we don't want to mees with it
	[[ $FORCE -eq 1 ]] && rm -f ${NGINX_REPO} && echo_ok "Cleaning up nginx repo"
    [[ $FORCE -eq 1 ]] && ${YUM_CMD} clean all >/dev/null && echo_ok "Cleaning yum caches"

	if [[ -f ${NGINX_REPO} ]]
	then
		echo_skip "Looks like nginx yum repo is set up"
	else
	
		# If we're on Red Hat (CentOS is default)
		grep -E '^Red Hat' -q /etc/redhat-release 1>/dev/null 2>&1 && OS='rhel'

		# In case we're running v5 (6 is default)
		grep -E '^(CentOS|Red Hat).*5\.[0-9]+' -q /etc/redhat-release 1>/dev/null 2>&1 && OS_MAJOR='5'
	
		# Setup actual repo
		echo "[nginx]
name=nginx repo
baseurl=http://nginx.org/packages/${OS}/${OS_MAJOR}/\$basearch/
enabled=1" >> ${NGINX_REPO}

		echo_ok "Setting up nginx yum repository"
	fi
	
	# Cleanup nginx GPG keys
	for key in $(${RPM_CMD} -q gpg-pubkey --qf '%{name}-%{version}-%{release} - %{summary}\n' | grep 'nginx signing key' | cut -f1 -d' ')
	do
		[[ $FORCE -eq 1 ]] && ${RPM_CMD} -e $key && echo_ok "Cleaning up nginx repo GPG key"
	done

	# Get and import GPG key
	if ( ${RPM_CMD} -q gpg-pubkey --qf '%{summary}\n' | grep -q 'nginx signing key' )
	then
		echo_skip "Looks like we already have nginx repo GPG key"
	else
		${CURL_CMD} -s ${NGINX_GPG} > /tmp/nginx.key || error_exit "Can't get nginx repo GPG key from ${NGINX_GPG}, this won't work"
		( ${RPM_CMD} --import /tmp/nginx.key && echo_ok "Importin nginx repo GPG key" ) || error_exit "Can't import nginx repo GPG key"
		rm -f /tmp/nginx.key
	fi

	return 0
}

install_nginx() {
	# Nuke nginx
	[[ $FORCE -eq 1 ]] && ( rpm -qa | grep -q "^nginx" ) && yum -y -q remove nginx 1>/dev/null && echo_ok "Cleaning up nginx install"

	# Install nginx from nginx repo if not found already
	if ( ${RPM_CMD} -qa | grep -q "^nginx" )
	then
		echo_skip "Looks like nginx is already installed"
	else
		${YUM_CMD} -y -q install nginx 1>/dev/null || error_exit "Installing nginx"
		echo_ok "Installing nginx"

	fi
	return 0
}

setup_nginx() {
	[[ $FORCE -eq 1 ]] && [[ -f ${NGINX_SITE} ]] && rm -f ${NGINX_SITE} && echo_ok "Cleaning up nginx site"

	# Put our config into separate site (don't want to brake anything that's already setup"
	if [[ -f ${NGINX_SITE} ]]
	then
		echo_skip "Looks like nginx site is already there"
	else
		echo > ${NGINX_SITE} "server {
    listen       ${NGINX_PORT};
    server_name  ${NGINX_SITE_NAME};

    location / {
        root   ${NGINX_SITE_DIR};
        index  index.html index.htm;
    }

}"
		echo_ok "Configuring nginx site"
		
		# We should reload because we changed config
		${NGINX_INIT_CMD} status >/dev/null && ${NGINX_INIT_CMD} reload >/dev/null && echo_ok "Reloading nginx config"
	fi

	# Make sure nginx is running 
	( ${NGINX_INIT_CMD} status >/dev/null && echo_skip "Looks like nginx is already running" ) || ( ${NGINX_INIT_CMD} start >/dev/null && echo_ok "Starting nginx" )
	
	# Make sure we start after reboot
	${CHKCONFIG_CMD} nginx >/dev/null || ( ${CHKCONFIG_CMD} nginx on >/dev/null && echo_ok "Adding nginx to init" )
	return 0
}

setup_content() {
	# Cleanup content
	[[ $FORCE -eq 1 ]] && [[ -d ${NGINX_SITE_DIR} ]] && rm -fr ${NGINX_SITE_DIR} && echo_ok "Cleaning up nginx content directory"

	# Check if content dir exists
	if [[ -d ${NGINX_SITE_DIR} ]]
	then
		echo_skip "Looks like directory with content already exists"
	else
		mkdir -p ${NGINX_SITE_DIR} && echo_ok "Created directory for content ${NGINX_SITE_DIR}"
	fi

	# Download files
	pushd >/dev/null 2>&1 ${NGINX_SITE_DIR}
	for file in ${NGINX_CONTENT} 
	do
		filename=$(basename $file)
		if [[ -f ${NGINX_SITE_DIR}/${filename} ]]
		then
			echo_skip "File ${filename} already exists"
		else
			( curl -s -k -O -L ${file} && echo_ok "Downloading ${file}" ) || echo_fail "Can't fetch ${file}"
		fi
	done
	
	popd >/dev/null 2>&1

	return 0
}

setup_iptables() {
	# Try to allow 8080 port for incoming connection
	# if system uses standard iptables setup

	# Do we actually have iptables?
	if ( /etc/init.d/iptables status 1>/dev/null )
	then
		if ( ${IPTABLES_CMD} -L INPUT -n | grep -q -E "^ACCEPT.*tcp.*NEW.*8080" )
		then
			echo_skip "Looks like iptables are already setup"
		else
			# This can be very tricky, but idea is to insert my rule 
			# before any reject rule in input chain
			FIRST_BAD_RULE=$( ${IPTABLES_CMD} -L INPUT -n --line-numbers | grep -E "(REJECT|DROP)" | head -n1 | cut -d' ' -f1)
			[[ -z $FIRST_BAD_RULE ]] && FIRST_BAD_RULE=1
			${IPTABLES_CMD} -I INPUT ${FIRST_BAD_RULE} -m state --state NEW -m tcp -p tcp --dport ${NGINX_PORT} -j ACCEPT && echo_ok "Setting up iptables"
		fi
	else
		echo_skip "Looks like no iptables on this system"
	fi
	return 0
}


fix_page() {
	# Well the page from GitHub is nowhere near correct html page
	# We can try to do basic fix to get a bit better result
    if [[ -f ${NGINX_SITE_DIR}/index.html ]]
    then
    	grep -i -q  "<HTML" ${NGINX_SITE_DIR}/index.html 2>/dev/null || ( sed -i '1s/^/<HTML>\n/'  ${NGINX_SITE_DIR}/index.html && echo_ok "Trying to fix the page - add <HTML> tag" )
	    grep -i -q  "</HTML" ${NGINX_SITE_DIR}/index.html 2>/dev/null || ( echo "</HTML>" >> ${NGINX_SITE_DIR}/index.html && echo_ok "Trying to fix the page - add </HTML> tag" )
    fi

}

while getopts "fh" opt
do
        case $opt in
                f) FORCE=1
			;;
		h) echo_usage
                        exit 1
                        ;;
                \?) echo "Invalid option: -$OPTARG" >&2
                        echo_usage
                        exit 1
                        ;;
                :) echo "Option -$OPTARG requires an argument." >&2
                        echo_usage
                        exit 1
                        ;;
        esac
done

test_pre
setup_nginx_repo
install_nginx
setup_content
setup_nginx
setup_iptables
fix_page

exit 0
