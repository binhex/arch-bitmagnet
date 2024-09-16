#!/usr/bin/dumb-init /bin/bash

# define variables, note bitmagnet uses hardcoded values for database and credentials
postgres_username=postgres
postgres_password=postgres
postgres_database=bitmagnet
postgres_data=/config/postgres/data
bitmagnet_install_path="/opt/bitmagnet"
bitmagnet_config_path="/config/bitmagnet"
bitmagnet_config_filename="config.yml"

# source in script to wait for child processes to exit
source /usr/local/bin/waitproc.sh

function copy_example_bitmagnet_config() {
	mkdir -p "${bitmagnet_config_path}"

	if [[ ! -f "${bitmagnet_config_path}/${bitmagnet_config_filename}" && ! -f "${bitmagnet_config_path}/${bitmagnet_config_filename}.example" ]]; then
		echo "[info] Copying example bitmgnet config file..."
		cp "/home/nobody/${bitmagnet_config_filename}.example" "${bitmagnet_config_path}/${bitmagnet_config_filename}.example"
	else
		echo "[info] bitmagnet config file already exists, skipping copy..."
	fi

	if [[ -f "${bitmagnet_config_path}/${bitmagnet_config_filename}" ]]; then
		# symlink config.yml to the correct location for bitmagnet
		ln -fs "${bitmagnet_config_path}/${bitmagnet_config_filename}" "${bitmagnet_install_path}/${bitmagnet_config_filename}"
	fi
}

function database_version_check() {
	# Prints the warning message if the database version on disk
	# does not match the PostgreSQL major version.
	if [ -d "${postgres_data}" ]; then
		/usr/bin/postgresql-check-db-dir "${postgres_data}" || true
	fi
}

function init_database() {
	# Initialize the database if it is not already initialized.
	if [ ! -s "${postgres_data}/PG_VERSION" ]; then

		# Create a temporary file to hold the password
		temp_password_file=$(mktemp)
		echo "${postgres_password}" > "${temp_password_file}"

		# Initialize the database with the specified username and password
		initdb --locale=C.UTF-8 --encoding=UTF8 -D "${postgres_data}" --username="${postgres_username}" --pwfile="${temp_password_file}"

		# Remove the temporary password file
		rm -f "${temp_password_file}"

	fi
}

function run_postgres() {
	# run postgres in the background.
	/usr/bin/postgres -D "${postgres_data}" &
}

function wait_for_postgres() {
    until pg_isready -q -d "${postgres_database}" -U "${postgres_username}"; do
        echo "[info] Waiting for PostgreSQL to be ready..."
        sleep 1s
    done
    echo "PostgreSQL is ready."
}

function create_database() {
	# Export the PostgreSQL password to avoid being prompted
	export PGPASSWORD="${postgres_password}"
	# Create the database if it does not exist.
	if [ -z "$(psql -U "${postgres_username}" -d "${postgres_database}" -Atqc "\\list ${postgres_database}")" ]; then
		createdb -U "${postgres_username}" "${postgres_database}"
	fi
}

function wait_for_database() {
    until psql -U "${postgres_username}" -d "${postgres_database}" -c '\q' 2>/dev/null; do
        echo "[info] Waiting for database ${postgres_database} to be created..."
        sleep 1s
    done
    echo "[info] Database ${postgres_database} has been created."
}

function run_bitmagnet() {
	# change to loction of bitmagnet install path to ensure working directory is correctly set to pick up config.yml
	cd "${bitmagnet_install_path}" || exit 1
	# run bitmagnet in the foreground.
	"${bitmagnet_install_path}/bitmagnet" worker run --keys=http_server --keys=queue_server --keys=dht_crawler
}

function main() {
	# Run the functions in the correct order
	copy_example_bitmagnet_config
	database_version_check
	init_database
	run_postgres
	wait_for_postgres
	create_database
	wait_for_database
	run_bitmagnet
}

# kickoff
main