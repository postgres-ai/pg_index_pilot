#!/bin/bash

set -euo pipefail

# Logging
exec > >(tee -a e2e_windows.log) 2>&1

# Env
export PAGER=cat
DB_HOST="${DB_HOST:-postgres}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-test_index_pilot}"  # base name used across e2e
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

echo "[windows] Using pre-installed control/target DBs from setup"

echo "Create small table and index to have candidates"
psql_c "${CONTROL_DB}" "do $$
begin
  perform index_pilot._connect_securely('${TARGET_DB}'::name);
  perform dblink_exec('${TARGET_DB}', $$
    create schema if not exists e2e;
    drop table if exists e2e.win_table cascade;
    create table e2e.win_table(id serial primary key, v text);
    insert into e2e.win_table(v) select 'x' from generate_series(1,10000);
    create index win_idx on e2e.win_table(v);
    analyze e2e.win_table;
  $$);
end
$$;"

echo "[windows] Lower thresholds to ensure candidacy"
psql_c "${CONTROL_DB}" "select index_pilot.set_or_replace_setting('${TARGET_DB}', null, null, null, 'index_size_threshold', '0', 'windows test');"
psql_c "${CONTROL_DB}" "select index_pilot.set_or_replace_setting('${TARGET_DB}', null, null, null, 'index_rebuild_scale_factor', '1.01', 'windows test');"

echo "[windows] Initialize snapshot"
psql_c "${CONTROL_DB}" "call index_pilot.periodic(false);"

echo "[windows] Configure short active window (now -> now+15s)"
psql_c "${CONTROL_DB}" "delete from index_pilot.maintenance_windows where database_name='${TARGET_DB}';"
psql_c "${CONTROL_DB}" "insert into index_pilot.maintenance_windows(database_name, day_of_week, start_time, end_time, priority, enabled)
select '${TARGET_DB}', extract(dow from clock_timestamp())::int,
       (clock_timestamp())::time,
       (clock_timestamp() + interval '15 seconds')::time,
       10, true;"

COUNT_BEFORE=$(psql_c "${CONTROL_DB}" "select count(*) from index_pilot.reindex_history where datname='${TARGET_DB}' and status='completed';")
echo "[windows] History before: ${COUNT_BEFORE}"

echo "[windows] Run periodic with implicit window (should schedule nothing)"
psql_c "${CONTROL_DB}" "call index_pilot.periodic(true,false);"

COUNT_AFTER=$(psql_c "${CONTROL_DB}" "select count(*) from index_pilot.reindex_history where datname='${TARGET_DB}' and status='completed';")
echo "[windows] History after:  ${COUNT_AFTER}"

if [[ "${COUNT_AFTER}" != "${COUNT_BEFORE}" ]]; then
  echo "[windows] FAIL: maintenance window gating failed (before=${COUNT_BEFORE}, after=${COUNT_AFTER})" >&2
  exit 1
fi

echo "[windows] Maintenance windows gating — PASS"
