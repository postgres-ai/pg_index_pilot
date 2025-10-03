#!/bin/bash

set -euo pipefail

# Logging
exec > >(tee -a e2e_cleanup.log) 2>&1

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

echo "[cleanup] Dropping maintenance windows"
psql_c postgres "do $$
begin
  if exists (select 1 from pg_database where datname='${CONTROL_DB}') then
    perform dblink_connect('ctl', format('host=%s port=%s dbname=%s user=%s password=%s', '${DB_HOST}','${DB_PORT}','${CONTROL_DB}','${DB_USER}','${DB_PASS}'));
    perform dblink_exec('ctl', $$ delete from index_pilot.maintenance_windows $$);
    perform dblink_disconnect('ctl');
  end if;
exception when others then
  null;
end
$$;"

echo "[cleanup] Dropping control and target databases"
psql_c postgres "drop database if exists ${CONTROL_DB};"
psql_c postgres "drop database if exists ${TARGET_DB};"

echo "[cleanup] Done"
