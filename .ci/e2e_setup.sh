#!/bin/bash

set -euo pipefail

# Logging
exec > >(tee -a e2e_setup.log) 2>&1

# Env
export PAGER=cat
DB_HOST="${DB_HOST:-postgres}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-test_index_pilot}"
DB_USER="${POSTGRES_USER:-${DB_USER:-postgres}}"
DB_PASS="${POSTGRES_PASSWORD:-${DB_PASS:-postgres}}"

CONTROL_DB="${DB_NAME}_control"
TARGET_DB="${DB_NAME}"

export PGPASSWORD="${DB_PASS:-${POSTGRES_PASSWORD:-postgres}}"

psql_base() {
  psql --no-psqlrc -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" "$@"
}

psql_c() {
  local db="$1"
  shift
  psql_base -d "${db}" -v ON_ERROR_STOP=on -At -c "$*"
}

psql_f() {
  local db="$1"
  shift
  local file="$1"
  shift
  psql_base -d "${db}" -v ON_ERROR_STOP=on -f "${file}" "$@"
}

echo "[setup] Waiting for Postgres at ${DB_HOST}:${DB_PORT} ..."
for i in {1..120}; do
  if psql_base -d postgres -At -c "select 1" > /dev/null 2>&1; then
    echo "[setup] Postgres is up"
    break
  fi
  sleep 1
  if [[ "$i" == "120" ]]; then
    echo "[setup] Postgres did not become ready in time" >&2
    exit 1
  fi
done

echo "[setup] Creating control and target databases"
psql_c postgres "drop database if exists ${CONTROL_DB};"
psql_c postgres "drop database if exists ${TARGET_DB};"
psql_c postgres "create database ${CONTROL_DB};"
psql_c postgres "create database ${TARGET_DB};"

echo "[setup] Installing extensions in control DB"
psql_c "${CONTROL_DB}" "create extension if not exists dblink;"
psql_c "${CONTROL_DB}" "create extension if not exists postgres_fdw;"

echo "[setup] Installing pg_index_pilot into control DB"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
psql_f "${CONTROL_DB}" "${REPO_DIR}/index_pilot_tables.sql"
psql_f "${CONTROL_DB}" "${REPO_DIR}/index_pilot_functions.sql"
psql_f "${CONTROL_DB}" "${REPO_DIR}/index_pilot_fdw.sql"

echo "[setup] Setting up FDW server and registration (self-host 127.0.0.1)"
psql_c "${CONTROL_DB}" "drop server if exists index_pilot_target cascade;"
psql_c "${CONTROL_DB}" "create server index_pilot_target foreign data wrapper postgres_fdw options (host '127.0.0.1', port '${DB_PORT}', dbname '${TARGET_DB}');"
psql_c "${CONTROL_DB}" "insert into index_pilot.target_databases(database_name, host, port, fdw_server_name, enabled) values ('${TARGET_DB}', '127.0.0.1', ${DB_PORT}, 'index_pilot_target', true) on conflict (database_name) do update set host=excluded.host, port=excluded.port, fdw_server_name=excluded.fdw_server_name, enabled=true;"
psql_c "${CONTROL_DB}" "drop user mapping if exists for \"${DB_USER}\" server index_pilot_target;"
psql_c "${CONTROL_DB}" "create user mapping for \"${DB_USER}\" server index_pilot_target options (user '${DB_USER}', password '${DB_PASS}');"

echo "[setup] Testing secure FDW connectivity"
psql_c "${CONTROL_DB}" "select index_pilot._connect_securely('${TARGET_DB}'::name);"

echo "[setup] Done"
