#!/usr/bin/dumb-init /bin/bash

# define variables, note bitmagnet uses hardcoded values for database and credentials
postgres_username=postgres
postgres_password=postgres
postgres_database=bitmagnet
postgres_data=/config/postgres/data

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
        echo "Waiting for PostgreSQL to be ready..."
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
        echo "Waiting for database ${postgres_database} to be created..."
        sleep 1s
    done
    echo "Database ${postgres_database} has been created."
}

function run_bitmagnet() {
	# run bitmagnet in the foreground.
	/usr/local/bin/bitmagnet worker run --keys=http_server --keys=queue_server --keys=dht_crawler
}

function main() {
	# Run the functions in the correct order
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