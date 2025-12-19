#!/usr/bin/dumb-init /bin/bash

# define variables, note bitmagnet uses hardcoded values for database and credentials
postgres_host='127.0.0.1'
postgres_username='postgres'
postgres_password='postgres'
postgres_database='bitmagnet'
postgres_data='/config/postgres/data'
postgres_install_path='/opt/postgresql16'
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

function backup_database() {
	# Perform database backup
	echo "[info] Performing backup of database ${postgres_database}..."

	# Define backup directory and filename with timestamp
	backup_dir="${bitmagnet_config_path}/backups"
	backup_timestamp=$(date +"%Y%m%d_%H%M%S")
	backup_file="${backup_dir}/${postgres_database}_${backup_timestamp}"

	# Create backup directory if it doesn't exist
	mkdir -p "${backup_dir}"

	# Export the PostgreSQL password to avoid being prompted
	export PGPASSWORD="${postgres_password}"

	# Perform backup using directory format with compression and parallel jobs
	if "${postgres_install_path}/bin/pg_dump" -U "${postgres_username}" -h "${postgres_host}" -Fd -j 4 -Z 6 "${postgres_database}" -f "${backup_file}"; then
		echo "[info] Database backup completed successfully: ${backup_file}"

		# Optional: Clean up old backups (keep last 7 days)
		if [[ "${POSTGRES_BACKUP_RETENTION_DAYS}" =~ ^[0-9]+$ ]]; then
			echo "[info] Removing backups older than ${POSTGRES_BACKUP_RETENTION_DAYS} days..."
			find "${backup_dir}" -type d -name "${postgres_database}_*" -mtime "+${POSTGRES_BACKUP_RETENTION_DAYS}" -exec rm -rf {} \; 2>/dev/null
		fi
	else
		echo "[warn] Database backup failed"
	fi
}

function scheduled_backup_loop() {
	# Run scheduled backups in background if enabled (but not if restore is enabled)
	if [[ "${POSTGRES_RESTORE_DB}" != "true" && ("${POSTGRES_BACKUP_DB}" == "true" || "${POSTGRES_SCHEDULED_BACKUP}" == "true") ]]; then
		# Set default interval to 24 hours if not specified
		backup_interval_hours="${POSTGRES_SCHEDULED_BACKUP_INTERVAL_HOURS:-24}"
		backup_interval_seconds=$((backup_interval_hours * 3600))

		if [[ "${POSTGRES_BACKUP_DB}" == "true" ]]; then
			# Perform initial backup on startup
			echo "[info] Running database backup on startup..."
			backup_database
		fi
		if [[ "${POSTGRES_SCHEDULED_BACKUP}" == "true" ]]; then
			echo "[info] Scheduled database backup enabled: running every ${backup_interval_hours} hours"

			# Run in background loop
			while true; do
				sleep "${backup_interval_seconds}"
				echo "[info] Running scheduled database backup..."
				backup_database
			done
		fi
	fi
}

function restore_database() {
	# Perform database restore if requested via environment variable
	if [[ "${POSTGRES_RESTORE_DB}" == "true" ]]; then
		echo "[info] Database restore requested..."

		# Define backup directory
		backup_dir="${bitmagnet_config_path}/backups"

		# Check if POSTGRES_RESTORE_PATH is set, otherwise use latest backup
		if [[ -n "${POSTGRES_RESTORE_PATH}" ]]; then
			restore_file="${POSTGRES_RESTORE_PATH}"
			echo "[info] Using specified backup: ${restore_file}"
		else
			# Find the most recent backup directory
			restore_file=$(find "${backup_dir}" -type d -name "${postgres_database}_*" | sort -r | head -n 1)
			if [[ -z "${restore_file}" ]]; then
				echo "[warn] No backup files found in ${backup_dir}"
				return 1
			fi
			echo "[info] Using latest backup: ${restore_file}"
		fi

		# Verify backup file exists
		if [[ ! -d "${restore_file}" ]]; then
			echo "[warn] Backup directory does not exist: ${restore_file}"
			return 1
		fi

		echo "[warn] This will drop and recreate the database ${postgres_database}!"
		echo "[info] Dropping database ${postgres_database}..."

		# Export the PostgreSQL password to avoid being prompted
		export PGPASSWORD="${postgres_password}"

		# Drop the existing database
		"${postgres_install_path}/bin/psql" -U "${postgres_username}" -h "${postgres_host}" -c "DROP DATABASE IF EXISTS ${postgres_database};" 2>/dev/null

		echo "[info] Creating empty database ${postgres_database}..."
		"${postgres_install_path}/bin/createdb" -U "${postgres_username}" "${postgres_database}" -h "${postgres_host}"

		echo "[info] Restoring database from backup..."
		if "${postgres_install_path}/bin/pg_restore" -U "${postgres_username}" -h "${postgres_host}" -d "${postgres_database}" -j 4 "${restore_file}"; then
			echo "[info] Database restore completed successfully"
		else
			echo "[warn] Database restore failed or completed with errors"
		fi
	else
		echo "[info] Database restore skipped (set POSTGRES_RESTORE_DB=true to enable)"
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
	# Note ordering of the functions is important here
	check_for_classifier_file
	copy_example_files
	delete_pid_file
	init_database
	run_postgres
	wait_for_postgres
	create_database
	wait_for_database

	# perform restore if enabled
	restore_database

	# Optional database maintenance
	vacuum_database
	reindex_database

	# Start scheduled backup loop in background
	scheduled_backup_loop &

	# Run bitmagnet
	run_bitmagnet
}

# kickoff
main