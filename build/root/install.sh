#!/bin/bash

# exit script if return code != 0
set -e

# app name from buildx arg, used in healthcheck to identify app and monitor correct process
APPNAME="${1}"
shift

# release tag name from buildx arg, stripped of build ver using string manipulation
RELEASETAG="${1}"
shift

# target arch from buildx arg
TARGETARCH="${1}"
shift

if [[ -z "${APPNAME}" ]]; then
	echo "[warn] App name from build arg is empty, exiting script..."
	exit 1
fi

if [[ -z "${RELEASETAG}" ]]; then
	echo "[warn] Release tag name from build arg is empty, exiting script..."
	exit 1
fi

if [[ -z "${TARGETARCH}" ]]; then
	echo "[warn] Target architecture name from build arg is empty, exiting script..."
	exit 1
fi

# write APPNAME and RELEASETAG to file to record the app name and release tag used to build the image
echo -e "export APPNAME=${APPNAME}\nexport IMAGE_RELEASE_TAG=${RELEASETAG}\nexport TARGETARCH=${TARGETARCH}\n" >> '/etc/image-build-info'

# ensure we have the latest builds scripts
refresh.sh

# pacman packages
####

# define pacman packages
#
# IMPORTANT AOR package 'postgresql-old-upgrade' is the previous version to the current version of the 'postgresql' package,
# in this case the previous version is v16 but this may change over time, we need to keep an eye on this package version,
# if it looks like it will be bumped up then we need to code up to perform the dump and load of the data during the postgreql
# upgrade.
pacman_packages="go git postgresql-old-upgrade postgresql-libs sqlite jq"

# install compiled packages using pacman
if [[ -n "${pacman_packages}" ]]; then
	# arm64 currently targetting aor not archive, so we need to update the system first
	if [[ "${TARGETARCH}" == "arm64" ]]; then
		pacman -Syu --noconfirm
	fi
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
#

download_path="/tmp/bitmagnet"
install_path="/opt/bitmagnet"

mkdir -p "${download_path}" "${install_path}"

# download bitmagnet source code release via gh script
gh.sh --github-owner bitmagnet-io --github-repo bitmagnet --download-type release --release-type source --download-path "${download_path}"

# unpack to install path
tar -xvf "${download_path}/"*.tar.gz -C "${download_path}"

# safely expand glob into an array (enable nullglob so pattern with no matches yields empty array)
shopt -s nullglob
# note new location from source and will be in next release is '"${download_path}/"bitmagnet*/internal/torznab/profile.go'
_matches=( "${download_path}"/bitmagnet*/internal/torznab/adapter/adapter.go )
shopt -u nullglob

if [[ ${#_matches[@]} -eq 0 ]]; then
	echo "[crit] Could not find adapter.go under ${download_path}, exiting build process..." ; exit 1
fi

limit_source_filepath="${_matches[0]}"

max_limit='5000'
default_limit='100'

# update result limit for bitmagnet to ensure we don't miss any new magnets due
# to the current max limit of 100, note we keep the default limit at 100, so
# unless you specify 'limit=xxxx' in the query then you will only get a maximum
# of 100 results returned
sed -i -E "s~MaxLimit:.*,$~MaxLimit:     ${max_limit},~g" "${limit_source_filepath}"
sed -i -E "s~DefaultLimit:.*,$~DefaultLimit: ${default_limit},~g" "${limit_source_filepath}"

# set location to install bitmagnet via GOBIN and then go install
# safely expand glob into an array to find bitmagnet directory
shopt -s nullglob
_bitmagnet_dirs=( "${download_path}"/bitmagnet* )
shopt -u nullglob

if [[ ${#_bitmagnet_dirs[@]} -eq 0 ]]; then
	echo "[crit] Could not find bitmagnet directory under ${download_path}, exiting build process..." ; exit 1
fi

cd "${_bitmagnet_dirs[0]}" && GOBIN="${install_path}" go install

# create path to store postgres lock file
mkdir -p /run/postgresql

# add bitmagnet to path to ease user interaction via console
echo "export PATH=${install_path}:\${PATH}" >> '/home/nobody/.bashrc'

# container perms
####

# define comma separated list of paths
install_paths="/opt/bitmagnet,/run/postgresql,/opt/pgsql-16,/home/nobody"

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
}' /usr/bin/init.sh
rm /tmp/permissions_heredoc

# env vars
####

cat <<'EOF' > /tmp/envvars_heredoc

export POSTGRES_VACUUM_DB=$(echo "${POSTGRES_VACUUM_DB}" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
if [[ ! -z "${POSTGRES_VACUUM_DB}" ]]; then
	echo "[info] POSTGRES_VACUUM_DB defined as '${POSTGRES_VACUUM_DB}'" | ts '%Y-%m-%d %H:%M:%.S'
else
	echo "[info] POSTGRES_VACUUM_DB not defined,(via -e POSTGRES_VACUUM_DB), defaulting to 'false'" | ts '%Y-%m-%d %H:%M:%.S'
	export POSTGRES_VACUUM_DB="false"
fi

export POSTGRES_REINDEX_DB=$(echo "${POSTGRES_REINDEX_DB}" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
if [[ ! -z "${POSTGRES_REINDEX_DB}" ]]; then
	echo "[info] POSTGRES_REINDEX_DB defined as '${POSTGRES_REINDEX_DB}'" | ts '%Y-%m-%d %H:%M:%.S'
else
	echo "[info] POSTGRES_REINDEX_DB not defined,(via -e POSTGRES_REINDEX_DB), defaulting to 'false'" | ts '%Y-%m-%d %H:%M:%.S'
	export POSTGRES_REINDEX_DB="false"
fi

EOF

# replace env vars placeholder string with contents of file (here doc)
sed -i '/# ENVVARS_PLACEHOLDER/{
    s/# ENVVARS_PLACEHOLDER//g
    r /tmp/envvars_heredoc
}' /usr/bin/init.sh
rm /tmp/envvars_heredoc

# cleanup
cleanup.sh
