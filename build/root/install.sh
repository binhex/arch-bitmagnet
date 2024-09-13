#!/bin/bash

# exit script if return code != 0
set -e

# release tag name from buildx arg, stripped of build ver using string manipulation
RELEASETAG="${1}"

# target arch from buildx arg
TARGETARCH="${2}"

if [[ -z "${RELEASETAG}" ]]; then
	echo "[warn] Release tag name from build arg is empty, exiting script..."
	exit 1
fi

if [[ -z "${TARGETARCH}" ]]; then
	echo "[warn] Target architecture name from build arg is empty, exiting script..."
	exit 1
fi

# write RELEASETAG to file to record the release tag used to build the image
echo "IMAGE_RELEASE_TAG=${RELEASETAG}" >> '/etc/image-release'

# build scripts
####

# download build scripts from github
curl --connect-timeout 5 --max-time 600 --retry 5 --retry-delay 0 --retry-max-time 60 -o /tmp/scripts-master.zip -L https://github.com/binhex/scripts/archive/master.zip

# unzip build scripts
unzip /tmp/scripts-master.zip -d /tmp

# move shell scripts to /root
mv /tmp/scripts-master/shell/arch/docker/*.sh /usr/local/bin/


# pacman packages
####

# define pacman packages
pacman_packages="go git postgresql postgresql-libs"

# install compiled packages using pacman
if [[ ! -z "${pacman_packages}" ]]; then
	pacman -S --needed $pacman_packages --noconfirm
fi

# custom
####

# define new result limit for bitmagnet as it's currently hard set to 100, which means we
# miss magnet links due to the sheer number of magnets added in a short time period.
#
# note pagination via 'offset' does work but only for bitmagnet torznab api, it is not
# working yet for jacket (see https://github.com/Jackett/Jackett/pull/13996) or prowlarr
# (see https://github.com/Prowlarr/Prowlarr/issues/379#issuecomment-1509457805)
max_limit='5000'
default_limit='100'

install_path="/tmp/bitmagnet"

# download bitmagnet from releases
github.sh --install-path "${install_path}" --github-owner 'bitmagnet-io' --github-repo 'bitmagnet' --query-type 'release' --download-branch 'main'

# update result limit for bitmagnet
sed -i -e "s~maxLimit:[[:space:]]*[[:digit:]]*.*~maxLimit:     ${max_limit},~g" "${install_path}/internal/torznab/adapter/adapter.go"
sed -i -e "s~defaultLimit:[[:space:]]*[[:digit:]]*.*~defaultLimit: ${default_limit},~g" "${install_path}/internal/torznab/adapter/adapter.go"

# set location to install bitmagnet via GOBIN and then go install
cd "${install_path}" && GOBIN=/usr/local/bin/ go install

# create path to store postgres lock file
mkdir -p /run/postgresql

# aur packages
####

# define aur packages
aur_packages=""

# call aur install script (arch user repo)
source aur.sh

# container perms
####

# define comma separated list of paths
install_paths="/run/postgresql,/var/lib/postgres,/home/nobody"

# split comma separated string into list for install paths
IFS=',' read -ra install_paths_list <<< "${install_paths}"

# process install paths in the list
for i in "${install_paths_list[@]}"; do

	# confirm path(s) exist, if not then exit
	if [[ ! -d "${i}" ]]; then
		echo "[crit] Path '${i}' does not exist, exiting build process..." ; exit 1
	fi

done

# convert comma separated string of install paths to space separated, required for chmod/chown processing
install_paths=$(echo "${install_paths}" | tr ',' ' ')

# set permissions for container during build - Do NOT double quote variable for install_paths otherwise this will wrap space separated paths as a single string
chmod -R 775 ${install_paths}

# create file with contents of here doc, note EOF is NOT quoted to allow us to expand current variable 'install_paths'
# we use escaping to prevent variable expansion for PUID and PGID, as we want these expanded at runtime of init.sh
cat <<EOF > /tmp/permissions_heredoc

# get previous puid/pgid (if first run then will be empty string)
previous_puid=\$(cat "/root/puid" 2>/dev/null || true)
previous_pgid=\$(cat "/root/pgid" 2>/dev/null || true)

# if first run (no puid or pgid files in /tmp) or the PUID or PGID env vars are different
# from the previous run then re-apply chown with current PUID and PGID values.
if [[ ! -f "/root/puid" || ! -f "/root/pgid" || "\${previous_puid}" != "\${PUID}" || "\${previous_pgid}" != "\${PGID}" ]]; then

	# set permissions inside container - Do NOT double quote variable for install_paths otherwise this will wrap space separated paths as a single string
	chown -R "\${PUID}":"\${PGID}" ${install_paths}

fi

# write out current PUID and PGID to files in /root (used to compare on next run)
echo "\${PUID}" > /root/puid
echo "\${PGID}" > /root/pgid

EOF

# replace permissions placeholder string with contents of file (here doc)
sed -i '/# PERMISSIONS_PLACEHOLDER/{
    s/# PERMISSIONS_PLACEHOLDER//g
    r /tmp/permissions_heredoc
}' /usr/local/bin/init.sh
rm /tmp/permissions_heredoc

# cleanup
cleanup.sh
