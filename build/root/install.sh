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
echo -e "export APPNAME=${APPNAME}\nexport IMAGE_RELEASE_TAG=${RELEASETAG}\n" >> '/etc/image-build-info'

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
#
max_limit='5000'
default_limit='100'

download_path="/tmp/bitmagnet"
install_path="/opt/bitmagnet"

mkdir -p "${install_path}"

# download bitmagnet from releases
github.sh --install-path "${download_path}" --github-owner 'bitmagnet-io' --github-repo 'bitmagnet' --query-type 'release' --download-branch 'main'

# update result limit for bitmagnet to ensure we don't miss any new magnets due
# to the current max limit of 100, note we keep the default limit at 100, so
# unless you specify 'limit=xxxx' in the query then you will only get a maximum
# of 100 results returned
sed -i -e "s~maxLimit:[[:space:]]*[[:digit:]]*.*~maxLimit:     ${max_limit},~g" "${download_path}/internal/torznab/adapter/adapter.go"
sed -i -e "s~defaultLimit:[[:space:]]*[[:digit:]]*.*~defaultLimit: ${default_limit},~g" "${download_path}/internal/torznab/adapter/adapter.go"

# switch sort order to be 'published' date not 'relevance', as relevance does
# not list latest added magnets first and thus you may end up missing new magnets
#
# create function to order by published_at in options.go
cat <<EOF >> "${download_path}/internal/database/query/options.go"
func OrderByPublishedAt() Option {
	return func(ctx OptionBuilder) (OptionBuilder, error) {
		return ctx.OrderBy(OrderByColumn{
			OrderByColumn: clause.OrderByColumn{
				Column:  clause.Column{Name: "published_at"},
				Desc:    true,
				Reorder: true,
			},
		}), nil
	}
}

EOF

# reference new function created in options.go to order by published_at
sed -i -e 's~options = append(options, query.QueryString(r.Query), query.OrderByQueryStringRank())~options = append(options, query.QueryString(r.Query), query.OrderByPublishedAt())~g' "${download_path}/internal/torznab/adapter/search.go"

# set location to install bitmagnet via GOBIN and then go install
cd "${download_path}" && GOBIN="${install_path}" go install

# create path to store postgres lock file
mkdir -p /run/postgresql

# add bitmagnet to path to ease user interaction via console
echo "export PATH=${install_path}:\${PATH}" >> '/home/nobody/.bashrc'

# aur packages
####

# define aur packages
aur_packages=""

# call aur install script (arch user repo)
source aur.sh

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

# cleanup
cleanup.sh
