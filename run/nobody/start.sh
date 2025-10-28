#!/usr/bin/dumb-init /bin/bash

# define variables, note bitmagnet uses hardcoded values for database and credentials
postgres_host='127.0.0.1'
postgres_username='postgres'
postgres_password='postgres'
postgres_database='bitmagnet'
postgres_data='/config/postgres/data'
postgres_install_path='/opt/pgsql-16'
bitmagnet_install_path='/opt/bitmagnet'
bitmagnet_config_path='/config/bitmagnet'
bitmagnet_config_filename='config.yml'
bitmagnet_classifier_filename='classifier.yml'

# source in script to wait for child processes to exit
source waitproc.sh

function check_for_classifier_file() {
	# if classifier file exists then rename config.yml to config.yml.disabled and set classifier workflow to custom
	if [[ -f "${bitmagnet_config_path}/${bitmagnet_classifier_filename}" ]]; then
		echo "[info] bitmagnet ${bitmagnet_classifier_filename} found"
		if [[ -f "${bitmagnet_config_path}/${bitmagnet_config_filename}" ]]; then
			echo "[info] Renaming ${bitmagnet_config_filename} to ${bitmagnet_config_filename}.disabled as we cannot have both ${bitmagnet_classifier_filename} and ${bitmagnet_config_filename} defined..."
			mv -f "${bitmagnet_config_path}/${bitmagnet_config_filename}" "${bitmagnet_config_path}/${bitmagnet_config_filename}.disabled"
		fi
		echo "[info] Setting env var for custom workflow..."
		export CLASSIFIER_WORKFLOW=custom
	# if classifier file does not exist and config.yml.disabled exists then re-enable config.yml by renaming config.yml.disabled to config.yml
	else
		echo "[info] bitmagnet ${bitmagnet_classifier_filename} not found"
		if [[ -f "${bitmagnet_config_path}/${bitmagnet_config_filename}.disabled" ]]; then
			echo "[info] Renaming ${bitmagnet_config_path}/${bitmagnet_config_filename}.disabled to ${bitmagnet_config_path}/${bitmagnet_config_filename} as no ${bitmagnet_classifier_filename} found..."
			mv -f "${bitmagnet_config_path}/${bitmagnet_config_filename}.disabled" "${bitmagnet_config_path}/${bitmagnet_config_filename}"
		fi
	fi
}

function copy_example_files() {
	mkdir -p "${bitmagnet_config_path}"

	bitmagnet_config_files="${bitmagnet_config_filename} ${bitmagnet_classifier_filename}"

	# check if bitmagnet config files exist, if not copy example files
	for bitmagnet_config_file in ${bitmagnet_config_files}; do

		if [[ ! -f "${bitmagnet_config_path}/${bitmagnet_config_file}" && ! -f "${bitmagnet_config_path}/${bitmagnet_config_file}.example" ]]; then
			echo "[info] Copying example bitmgnet ${bitmagnet_config_file} file..."
			cp "/home/nobody/${bitmagnet_config_file}.example" "${bitmagnet_config_path}/${bitmagnet_config_file}.example"
		else
			echo "[info] bitmagnet ${bitmagnet_config_file} file already exists, skipping copy..."
		fi

		if [[ -f "${bitmagnet_config_path}/${bitmagnet_config_file}" ]]; then
			# symlink config.yml/classifier.yml to the correct location for bitmagnet
			ln -fs "${bitmagnet_config_path}/${bitmagnet_config_file}" "${bitmagnet_install_path}/${bitmagnet_config_file}"
		else
			# unlink symlink if the file does not exist (renamed or deleted)
			unlink "${bitmagnet_install_path}/${bitmagnet_config_file}" 2>/dev/null
		fi
	done
}

function delete_pid_file() {
	if [ -f "${postgres_data}/postmaster.pid" ]; then
		echo "[info] Deleting ${postgres_data}/postmaster.pid from previous run..."
		rm -f "${postgres_data}/postmaster.pid"
	fi
}

function init_database() {
	# Initialize the database if it is not already initialized.
	if [ ! -s "${postgres_data}/PG_VERSION" ]; then

		# Create a temporary file to hold the password
		temp_password_file=$(mktemp)
		echo "${postgres_password}" > "${temp_password_file}"

		# Initialize the database with the specified username and password
		"${postgres_install_path}/bin/initdb" --locale=C.UTF-8 --encoding=UTF8 -D "${postgres_data}" --username="${postgres_username}" --pwfile="${temp_password_file}"

		# Remove the temporary password file
		rm -f "${temp_password_file}"

	fi
}

function run_postgres() {
	# run postgres in the background.
	"${postgres_install_path}/bin/postgres" -D "${postgres_data}" -h "${postgres_host}" &
}

function wait_for_postgres() {
    until "${postgres_install_path}/bin/pg_isready" -q -d "${postgres_database}" -h "${postgres_host}" -U "${postgres_username}"; do
        echo "[info] Waiting for PostgreSQL to be ready..."
        sleep 1s
    done
    echo "[info] PostgreSQL is ready."
}

function create_database() {
	# Export the PostgreSQL password to avoid being prompted
	export PGPASSWORD="${postgres_password}"
	# Create the database if it does not exist.
	if [ -z "$("${postgres_install_path}/bin/psql" -U "${postgres_username}" -d "${postgres_database}" -h "${postgres_host}" -Atqc "\\list ${postgres_database}")" ]; then
		"${postgres_install_path}/bin/createdb" -U "${postgres_username}" "${postgres_database}" -h "${postgres_host}"
	fi
}

function wait_for_database() {
    until "${postgres_install_path}/bin/psql" -U "${postgres_username}" -d "${postgres_database}" -h "${postgres_host}" -c '\q' 2>/dev/null; do
        echo "[info] Waiting for database ${postgres_database} to be created..."
        sleep 1s
    done
    echo "[info] Database ${postgres_database} has been created."
}

function vacuum_database() {
	# Perform FULL VACUUM on the database if requested via environment variable
	if [[ "${POSTGRES_VACUUM_DB}" == "true" ]]; then
		echo "[info] Performing FULL VACUUM on database ${postgres_database}..."
		echo "[info] This operation may take a significant amount of time and will lock tables..."

		# Export the PostgreSQL password to avoid being prompted
		export PGPASSWORD="${postgres_password}"

		# Perform FULL VACUUM on the database
		if "${postgres_install_path}/bin/psql" -U "${postgres_username}" -d "${postgres_database}" -h "${postgres_host}" -c "VACUUM FULL;" 2>/dev/null; then
			echo "[info] FULL VACUUM completed successfully"
		else
			echo "[warn] FULL VACUUM failed or was interrupted"
		fi
	else
		echo "[info] FULL VACUUM skipped (set POSTGRES_VACUUM_DB=true to enable)"
	fi
}

function reindex_database() {
	# Perform REINDEX on the database if requested via environment variable
	if [[ "${POSTGRES_REINDEX_DB}" == "true" ]]; then
		echo "[info] Performing REINDEX on database ${postgres_database}..."
		echo "[info] This operation may take a significant amount of time and will lock tables..."

		# Export the PostgreSQL password to avoid being prompted
		export PGPASSWORD="${postgres_password}"

		# Perform REINDEX on the entire database
		if "${postgres_install_path}/bin/psql" -U "${postgres_username}" -d "${postgres_database}" -h "${postgres_host}" -c "REINDEX DATABASE ${postgres_database};" 2>/dev/null; then
			echo "[info] REINDEX completed successfully"
		else
			echo "[warn] REINDEX failed or was interrupted"
		fi
	else
		echo "[info] REINDEX skipped (set POSTGRES_REINDEX_DB=true to enable)"
	fi
}

function run_bitmagnet() {
	# change to loction of bitmagnet install path to ensure working directory is correctly set to pick up config.yml/classifier.yml
	cd "${bitmagnet_install_path}" || exit 1

	# run bitmagnet in the foreground.
	"${bitmagnet_install_path}/bitmagnet" worker run --keys=http_server --keys=queue_server --keys=dht_crawler
}

function main() {
	# Run the functions in the correct order
	check_for_classifier_file
	copy_example_files
	delete_pid_file
	init_database
	run_postgres
	wait_for_postgres
	create_database
	wait_for_database

	# Optional database maintenance operations
	vacuum_database
	reindex_database

	run_bitmagnet
}

# kickoff
main