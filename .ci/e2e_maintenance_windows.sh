#!/bin/bash

set -euo pipefail

# Logging
exec > >(tee -a e2e_windows.log) 2>&1

# Env
export PAGER=cat
DB_HOST="${DB_HOST:-postgres}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-test_index_pilot}" # base name used across e2e
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

echo "[windows] Create test tables: 1 large (slow), 2 small (fast)"
psql_c "${CONTROL_DB}" "do \$\$
begin
  perform index_pilot._connect_securely('${TARGET_DB}'::name);
  perform dblink_exec('${TARGET_DB}', \$db\$
    create schema if not exists e2e;
    drop table if exists e2e.large_table, e2e.small_table_1, e2e.small_table_2 cascade;
    
    -- Large table: ~500k rows, will take >5 seconds to reindex
    create table e2e.large_table(id bigserial primary key, data text);
    insert into e2e.large_table(data) select repeat('x', 100) from generate_series(1, 500000);
    create index large_idx on e2e.large_table(data);
    
    -- Small table 1: ~50k rows, fast reindex (<1 sec)
    create table e2e.small_table_1(id bigserial primary key, data text);
    insert into e2e.small_table_1(data) select repeat('y', 50) from generate_series(1, 50000);
    create index small_idx_1 on e2e.small_table_1(data);
    
    -- Small table 2: ~50k rows, fast reindex (<1 sec)
    create table e2e.small_table_2(id bigserial primary key, data text);
    insert into e2e.small_table_2(data) select repeat('z', 50) from generate_series(1, 50000);
    create index small_idx_2 on e2e.small_table_2(data);
  \$db\$);
end
\$\$;"

echo "[windows] Snapshot before bloat"
psql_c "${CONTROL_DB}" "call index_pilot.periodic(false);"

echo "[windows] Show initial index sizes"
psql_c "${CONTROL_DB}" "
do \$\$
declare
  _rec record;
begin
  perform index_pilot._connect_securely('${TARGET_DB}'::name);
  raise notice 'Initial index sizes:';
  for _rec in 
    select * from dblink('${TARGET_DB}', \$db\$
      select indexname, pg_size_pretty(pg_relation_size(schemaname||'.'||indexname)) as size
      from pg_indexes where schemaname = 'e2e' order by indexname
    \$db\$) as t(indexname name, size text)
  loop
    raise notice '  %: %', _rec.indexname, _rec.size;
  end loop;
end
\$\$;"

echo "[windows] Induce bloat in all tables (no analyze)"
psql_c "${CONTROL_DB}" "do \$\$
begin
  perform index_pilot._connect_securely('${TARGET_DB}'::name);
  perform dblink_exec('${TARGET_DB}', \$db\$
    delete from e2e.large_table where id % 2 = 0;
    delete from e2e.small_table_1 where id % 2 = 0;
    delete from e2e.small_table_2 where id % 2 = 0;
  \$db\$);
end
\$\$;"

echo "[windows] Show index sizes after bloat"
psql_c "${CONTROL_DB}" "
do \$\$
declare
  _rec record;
begin
  perform index_pilot._connect_securely('${TARGET_DB}'::name);
  raise notice 'Index sizes after bloat:';
  for _rec in 
    select * from dblink('${TARGET_DB}', \$db\$
      select indexname, pg_size_pretty(pg_relation_size(schemaname||'.'||indexname)) as size
      from pg_indexes where schemaname = 'e2e' order by indexname
    \$db\$) as t(indexname name, size text)
  loop
    raise notice '  %: %', _rec.indexname, _rec.size;
  end loop;
end
\$\$;"

echo "[windows] Update snapshot after bloat"
psql_c "${CONTROL_DB}" "call index_pilot.periodic(false);"

echo "[windows] TEST 1: First pass without windows - collect statistics"
psql_c "${CONTROL_DB}" "call index_pilot.periodic(true, true);"

COUNT_PASS1=$(psql_c "${CONTROL_DB}" "select count(*) from index_pilot.reindex_history where datname='${TARGET_DB}' and status='completed';")
echo "[windows] Pass 1 completed: ${COUNT_PASS1} indexes (expected 6: 3 pkeys + 3 data indexes)"

if [[ "${COUNT_PASS1}" -lt 6 ]]; then
  echo "[windows] FAIL: Pass 1 should reindex all 6 indexes" >&2
  exit 1
fi

echo "[windows] TEST 2: Run outside active window - should skip database"
psql_c "${CONTROL_DB}" "delete from index_pilot.maintenance_windows where database_name='${TARGET_DB}';"
psql_c "${CONTROL_DB}" "insert into index_pilot.maintenance_windows(database_name, day_of_week, start_time, end_time, enabled)
select '${TARGET_DB}', extract(dow from clock_timestamp())::int,
       '00:00:00'::time,
       '01:00:00'::time,
       true;"

COUNT_BEFORE_SKIP=$(psql_c "${CONTROL_DB}" "select count(*) from index_pilot.reindex_history where datname='${TARGET_DB}' and status='completed';")
psql_c "${CONTROL_DB}" "call index_pilot.periodic(true, true);" 2>&1 | tee /tmp/skip_test.log

COUNT_AFTER_SKIP=$(psql_c "${CONTROL_DB}" "select count(*) from index_pilot.reindex_history where datname='${TARGET_DB}' and status='completed';")

if [[ "${COUNT_AFTER_SKIP}" != "${COUNT_BEFORE_SKIP}" ]]; then
  echo "[windows] FAIL: Should skip database outside window (before=${COUNT_BEFORE_SKIP}, after=${COUNT_AFTER_SKIP})" >&2
  exit 1
fi

if ! grep -q "Skipping database ${TARGET_DB}" /tmp/skip_test.log; then
  echo "[windows] FAIL: Expected 'Skipping database' notice" >&2
  exit 1
fi

echo "[windows] TEST 3: Short window (3 seconds) - only fast indexes should complete"

echo "[windows] Show current index sizes and bloat ratios"
psql_c "${CONTROL_DB}" "
select 
  ils.indexrelname,
  pg_size_pretty(ils.indexsize) as current_size,
  coalesce(ils.best_ratio::numeric(10,2), 1.0) as best_ratio
from index_pilot.index_latest_state ils
where ils.datname = '${TARGET_DB}' and ils.schemaname = 'e2e'
order by ils.indexsize desc;"

psql_c "${CONTROL_DB}" "delete from index_pilot.maintenance_windows where database_name='${TARGET_DB}';"
psql_c "${CONTROL_DB}" "insert into index_pilot.maintenance_windows(database_name, day_of_week, start_time, end_time, enabled)
select '${TARGET_DB}', extract(dow from clock_timestamp())::int,
       (clock_timestamp())::time,
       (clock_timestamp() + interval '3 seconds')::time,
       true;"

COUNT_BEFORE_SHORT=$(psql_c "${CONTROL_DB}" "select count(*) from index_pilot.reindex_history where datname='${TARGET_DB}' and status='completed';")
psql_c "${CONTROL_DB}" "call index_pilot.periodic(true, true);"

COUNT_AFTER_SHORT=$(psql_c "${CONTROL_DB}" "select count(*) from index_pilot.reindex_history where datname='${TARGET_DB}' and status='completed';")
REINDEXED_IN_WINDOW=$((COUNT_AFTER_SHORT - COUNT_BEFORE_SHORT))

echo "[windows] Short window completed: ${REINDEXED_IN_WINDOW} indexes reindexed"

# Check that large_table was NOT reindexed in this pass (too slow for 3-sec window)
LARGE_COUNT=$(psql_c "${CONTROL_DB}" "select count(*) from index_pilot.reindex_history 
  where datname='${TARGET_DB}' and status='completed' 
  and (indexrelname = 'large_table_pkey' or indexrelname = 'large_idx')
  and entry_timestamp > clock_timestamp() - interval '1 minute';")

if [[ "${LARGE_COUNT}" -gt 0 ]]; then
  echo "[windows] FAIL: Large table should not be reindexed in 3-second window" >&2
  exit 1
fi

if [[ "${REINDEXED_IN_WINDOW}" -lt 2 ]]; then
  echo "[windows] FAIL: At least 2 small indexes should complete in 3-second window" >&2
  exit 1
fi

echo "[windows] Maintenance windows smart scheduling — ALL TESTS PASS"
