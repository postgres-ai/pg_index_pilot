\set ON_ERROR_STOP

--disable useless (in this particular case) NOTICE noise
set client_min_messages to WARNING;

DROP FUNCTION IF EXISTS index_pilot.check_pg_version_bugfixed();
CREATE OR REPLACE FUNCTION index_pilot._check_pg_version_bugfixed()
RETURNS BOOLEAN AS
$BODY$
BEGIN
   IF ((current_setting('server_version_num')::INTEGER >= 120010) AND
               (current_setting('server_version_num')::INTEGER < 130000)) OR
      ((current_setting('server_version_num')::INTEGER >= 130006) AND
               (current_setting('server_version_num')::INTEGER < 140000)) OR
      (current_setting('server_version_num')::INTEGER >= 140002)
      THEN RETURN TRUE;
      ELSE RETURN FALSE;
    END IF;
END;
$BODY$
LANGUAGE plpgsql;


DROP FUNCTION IF EXISTS index_pilot.check_pg14_version_bugfixed();
CREATE OR REPLACE FUNCTION index_pilot._check_pg14_version_bugfixed()
RETURNS BOOLEAN AS
$BODY$
BEGIN
  IF (current_setting('server_version_num')::INTEGER >= 140000) AND
          (current_setting('server_version_num')::INTEGER < 140004)
       THEN RETURN FALSE;
       ELSE RETURN TRUE;
  END IF;
END;
$BODY$
LANGUAGE plpgsql;


DO $$
BEGIN
  IF current_setting('server_version_num')<'12'
  THEN
    RAISE 'This library works only for PostgreSQL 12 or higher!';
  ELSE
    IF NOT index_pilot._check_pg_version_bugfixed()
    THEN
       RAISE WARNING 'The database version % affected by PostgreSQL bugs which make use pg_index_pilot potentially unsafe, please update to latest minor release. For additional info please see:
   https://www.postgresql.org/message-id/E1mumI4-0001Zp-PB@gemulon.postgresql.org
   and
   https://www.postgresql.org/message-id/E1n8C7O-00066j-Q5@gemulon.postgresql.org',
       current_setting('server_version');
    END IF;
    IF NOT index_pilot._check_pg14_version_bugfixed()
      THEN
         RAISE WARNING 'The database version % affected by PostgreSQL bug BUG #17485 which make use pg_index_pilot unsafe, please update to latest minor release. For additional info please see:
       https://www.postgresql.org/message-id/202205251144.6t4urostzc3s@alvherre.pgsql',
        current_setting('server_version');
    END IF;
  END IF;
END; $$;


CREATE EXTENSION IF NOT EXISTS dblink;
-- ALTER EXTENSION dblink UPDATE;

--current version of code
CREATE OR REPLACE FUNCTION index_pilot.version()
RETURNS TEXT AS
$BODY$
BEGIN
    RETURN '1.04';
END;
$BODY$
LANGUAGE plpgsql IMMUTABLE;



--minimum table structure version required
CREATE OR REPLACE FUNCTION index_pilot._check_structure_version()
RETURNS VOID AS
$BODY$
DECLARE
  _tables_version INTEGER;
  _required_version INTEGER := 8;
BEGIN
    SELECT version INTO STRICT _tables_version FROM index_pilot.tables_version;
    IF (_tables_version<_required_version) THEN
       RAISE EXCEPTION 'Current tables version % is less than minimally required % for % code version, please update tables structure', _tables_version, _required_version, index_pilot.version();
    END IF;
END;
$BODY$
LANGUAGE plpgsql;



CREATE OR REPLACE FUNCTION index_pilot.check_update_structure_version()
RETURNS VOID AS
$BODY$
DECLARE
   _tables_version INTEGER;
   _required_version INTEGER := 8;
BEGIN
   SELECT version INTO STRICT _tables_version FROM index_pilot.tables_version;
   WHILE (_tables_version<_required_version) LOOP
      EXECUTE 'SELECT index_pilot._structure_version_'||_tables_version||'_'||_tables_version+1||'()';
   _tables_version := _tables_version+1;
END LOOP;
    RETURN;
END;
$BODY$
LANGUAGE plpgsql;


--update table structure version from 1 to 2
CREATE OR REPLACE FUNCTION index_pilot._structure_version_1_2()
RETURNS VOID AS
$BODY$
BEGIN
   CREATE VIEW index_pilot.history AS
      SELECT date_trunc('second', entry_timestamp)::timestamp AS ts,
         datname AS db, schemaname AS schema, relname AS table,
         indexrelname AS index, indexsize_before AS size_before, indexsize_after AS size_after,
         (indexsize_before::float/indexsize_after)::numeric(12,2) AS ratio,
         estimated_tuples AS tuples, date_trunc('seconds', reindex_duration) AS duration
      FROM index_pilot.reindex_history ORDER BY id DESC;
   UPDATE index_pilot.tables_version SET version=2;
   RETURN;
END;
$BODY$
LANGUAGE plpgsql;


--update table structure version from 2 to 3
CREATE OR REPLACE FUNCTION index_pilot._structure_version_2_3()
RETURNS VOID AS
$BODY$
BEGIN
   CREATE TABLE IF NOT EXISTS index_pilot.index_current_state
   (
     id bigserial primary key,
     mtime timestamptz not null default now(),
     datname name not null,
     schemaname name not null,
     relname name not null,
     indexrelname name not null,
     indexsize BIGINT not null,
     estimated_tuples BIGINT not null,
     best_ratio REAL
   );
   CREATE UNIQUE INDEX index_current_state_index on index_pilot.index_current_state(datname, schemaname, relname, indexrelname);

   UPDATE index_pilot.config SET value='128kB'
   WHERE key='minimum_reliable_index_size' AND pg_size_bytes(value)<pg_size_bytes('128kB');

   WITH
    _last_reindex_values AS (
    SELECT
      DISTINCT ON (datname, schemaname, relname, indexrelname)
      reindex_history.datname, reindex_history.schemaname, reindex_history.relname, reindex_history.indexrelname, entry_timestamp, estimated_tuples, indexsize_after AS indexsize
      FROM index_pilot.reindex_history
      ORDER BY datname, schemaname, relname, indexrelname, entry_timestamp DESC
    ),
    _all_history_since_reindex AS (
       --last reindexed value
       SELECT _last_reindex_values.datname, _last_reindex_values.schemaname, _last_reindex_values.relname, _last_reindex_values.indexrelname, _last_reindex_values.entry_timestamp, _last_reindex_values.estimated_tuples, _last_reindex_values.indexsize
       FROM _last_reindex_values
       UNION ALL
       --all values since reindex or from start
       SELECT index_history.datname, index_history.schemaname, index_history.relname, index_history.indexrelname, index_history.entry_timestamp, index_history.estimated_tuples, index_history.indexsize
       FROM index_pilot.index_history
       LEFT JOIN _last_reindex_values USING (datname, schemaname, relname, indexrelname)
       WHERE index_history.entry_timestamp>=coalesce(_last_reindex_values.entry_timestamp, '-INFINITY'::timestamp)
    ),
    _best_values AS (
      --only valid best if reindex entry exists
      SELECT
        DISTINCT ON (datname, schemaname, relname, indexrelname)
        _all_history_since_reindex.*,
        _all_history_since_reindex.indexsize::real/_all_history_since_reindex.estimated_tuples::real as best_ratio
      FROM _all_history_since_reindex
      JOIN _last_reindex_values USING (datname, schemaname, relname, indexrelname)
      WHERE _all_history_since_reindex.indexsize > pg_size_bytes('128kB')
      ORDER BY datname, schemaname, relname, indexrelname, _all_history_since_reindex.indexsize::real/_all_history_since_reindex.estimated_tuples::real
    ),
    _current_state AS (
     SELECT
        DISTINCT ON (datname, schemaname, relname, indexrelname)
        _all_history_since_reindex.*
      FROM _all_history_since_reindex
      ORDER BY datname, schemaname, relname, indexrelname, entry_timestamp DESC
    )
    INSERT INTO index_pilot.index_current_state
      (mtime, datname, schemaname, relname, indexrelname, indexsize, estimated_tuples, best_ratio)
      SELECT c.entry_timestamp, c.datname, c.schemaname, c.relname, c.indexrelname, c.indexsize, c.estimated_tuples, best_ratio
      FROM _current_state c JOIN _best_values USING (datname, schemaname, relname, indexrelname);
   DROP TABLE index_pilot.index_history;
   UPDATE index_pilot.tables_version SET version=3;
   RETURN;
END;
$BODY$
LANGUAGE plpgsql;


-- set dblink connection for current database using FDW approach
-- Secure connection using ONLY postgres_fdw USER MAPPING (secure approach)
create or replace function index_pilot._connect_securely(_datname name) returns void as
$BODY$
begin
    -- Only allow connection to current database (managed services compatible mode)
    if _datname != current_database() then
        raise exception 'Only current database % is supported. Cannot access database %', current_database(), _datname;
    end if;
    
    -- Disconnect existing connection if any
    if _datname = any(dblink_get_connections()) then
        perform dblink_disconnect(_datname);
    end if;
    
    -- Use ONLY postgres_fdw with USER MAPPING (secure approach)
    -- Password is stored securely in PostgreSQL catalog, not in plain text
    begin
        perform dblink_connect_u(_datname, 'index_pilot_self');
    exception when others then
        raise exception 'FDW connection failed. Please setup postgres_fdw USER MAPPING using setup_rds_connection(): %', sqlerrm;
    end;
end;
$BODY$
language plpgsql;

create or replace function index_pilot._dblink_connect_if_not(_datname name) returns void as
$BODY$
begin
    -- Use secure FDW connection if not already connected
    if _datname = any(dblink_get_connections()) is not true then
        perform index_pilot._connect_securely(_datname);
    end if;
    return;
end;
$BODY$
language plpgsql;



CREATE OR REPLACE FUNCTION index_pilot._remote_get_indexes_indexrelid(_datname name)
RETURNS TABLE(datname name, schemaname name, relname name, indexrelname name, indexrelid OID)
AS
$BODY$
DECLARE
    _use_toast_tables text;
BEGIN
    IF index_pilot._check_pg_version_bugfixed() THEN _use_toast_tables := 'True';
    ELSE _use_toast_tables := 'False';
    END IF;
    -- Secure FDW connection for querying indexes
    PERFORM index_pilot._connect_securely(_datname);
    
    RETURN QUERY SELECT
      _datname, _res.schemaname, _res.relname, _res.indexrelname, _res.indexrelid
    FROM
    dblink(_datname,
    format(
    $SQL$
      SELECT
          n.nspname AS schemaname
        , c.relname
        , i.relname AS indexrelname
        , x.indexrelid
      FROM pg_index x
      JOIN pg_catalog.pg_class c           ON c.oid = x.indrelid
      JOIN pg_catalog.pg_class i           ON i.oid = x.indexrelid
      JOIN pg_catalog.pg_namespace n       ON n.oid = c.relnamespace
      JOIN pg_catalog.pg_am a              ON a.oid = i.relam
      --toast indexes info
      LEFT JOIN pg_catalog.pg_class c1     ON c1.reltoastrelid = c.oid AND n.nspname = 'pg_toast'
      LEFT JOIN pg_catalog.pg_namespace n1 ON c1.relnamespace = n1.oid

      WHERE
      TRUE
      --limit reindex for indexes on tables/mviews/toast
      --AND c.relkind = ANY (ARRAY['r'::"char", 't'::"char", 'm'::"char"])
      --limit reindex for indexes on tables/mviews (skip topast until bugfix of BUG #17268)
      AND ( (c.relkind = ANY (ARRAY['r'::"char", 'm'::"char"])) OR
            ( (c.relkind = 't'::"char") AND %s )
          )
      --ignore exclusion constraints
      AND NOT EXISTS (SELECT FROM pg_constraint WHERE pg_constraint.conindid=i.oid and pg_constraint.contype='x')
      --ignore indexes for system tables and index_pilot own tables
      AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'index_pilot')
      --ignore indexes on toast tables of system tables and index_pilot own tables
      AND (n1.nspname IS NULL OR n1.nspname NOT IN ('pg_catalog', 'information_schema', 'index_pilot'))
      --skip BRIN indexes... please see bug BUG #17205 https://www.postgresql.org/message-id/flat/17205-42b1d8f131f0cf97%%40postgresql.org
      AND a.amname NOT IN ('brin') AND x.indislive IS TRUE
      --skip indexes on temp relations
      AND c.relpersistence<>'t'
      --debug only
      --ORDER by 1,2,3
    $SQL$, _use_toast_tables)
    )
    AS _res(schemaname name, relname name, indexrelname name, indexrelid OID)
    ;
END;
$BODY$
LANGUAGE plpgsql;



--update table structure version from 3 to 4
CREATE OR REPLACE FUNCTION index_pilot._structure_version_3_4()
RETURNS VOID AS
$BODY$
DECLARE
  _datname NAME;
BEGIN
   ALTER TABLE index_pilot.reindex_history
      ADD COLUMN indexrelid OID;
   CREATE INDEX reindex_history_oid_index on index_pilot.reindex_history(datname, indexrelid);

   ALTER TABLE index_pilot.index_current_state
      ADD COLUMN indexrelid OID;
   CREATE UNIQUE INDEX index_current_state_oid_index on index_pilot.index_current_state(datname, indexrelid);
   DROP INDEX IF EXISTS index_pilot.index_current_state_index;
   CREATE INDEX index_current_state_index on index_pilot.index_current_state(datname, schemaname, relname, indexrelname);

   -- add indexrelid values into index_current_state
   FOR _datname IN
     SELECT DISTINCT datname FROM index_pilot.index_current_state
     ORDER BY datname
   LOOP
     PERFORM index_pilot._dblink_connect_if_not(_datname);
     --update current state of ALL indexes in target database
     WITH _actual_indexes AS (
        SELECT schemaname, relname, indexrelname, indexrelid
        FROM index_pilot._remote_get_indexes_indexrelid(_datname)
     )
     UPDATE index_pilot.index_current_state AS i
        SET indexrelid=_actual_indexes.indexrelid
        FROM _actual_indexes
            WHERE
                 i.schemaname=_actual_indexes.schemaname
             AND i.relname=_actual_indexes.relname
             AND i.indexrelname=_actual_indexes.indexrelname
             AND i.datname=_datname;
     PERFORM dblink_disconnect(_datname);
   END LOOP;
   DELETE FROM index_pilot.index_current_state WHERE indexrelid IS NULL;
   ALTER TABLE index_pilot.index_current_state ALTER indexrelid SET NOT NULL;
   UPDATE index_pilot.tables_version SET version=4;
   RETURN;
END;
$BODY$
LANGUAGE plpgsql;


--update table structure version from 4 to 5
CREATE OR REPLACE FUNCTION index_pilot._structure_version_4_5()
RETURNS VOID AS
$BODY$
DECLARE
  _datname NAME;
BEGIN
   ALTER TABLE index_pilot.reindex_history
      ADD COLUMN datid OID;
   DROP INDEX IF EXISTS index_pilot.reindex_history_oid_index;
   CREATE INDEX reindex_history_oid_index on index_pilot.reindex_history(datid, indexrelid);

   ALTER TABLE index_pilot.index_current_state
      ADD COLUMN datid OID;
   DROP INDEX IF EXISTS index_pilot.index_current_state_oid_index;
   CREATE UNIQUE INDEX index_current_state_oid_index on index_pilot.index_current_state(datid, indexrelid);

   -- add datid values into index_current_state
  UPDATE index_pilot.index_current_state AS i
     SET datid=p.oid
     FROM pg_database p
         WHERE i.datname=p.datname;
   DELETE FROM index_pilot.index_current_state WHERE datid IS NULL;
   ALTER TABLE index_pilot.index_current_state ALTER datid SET NOT NULL;
   UPDATE index_pilot.tables_version SET version=5;
   RETURN;
END;
$BODY$
LANGUAGE plpgsql;


--update table structure version from 5 to 6
CREATE OR REPLACE FUNCTION index_pilot._structure_version_5_6()
RETURNS VOID AS
$BODY$
BEGIN
   ALTER TABLE index_pilot.index_current_state
      ADD COLUMN indisvalid BOOLEAN not null DEFAULT TRUE;
   UPDATE index_pilot.tables_version SET version=6;
   RETURN;
END;
$BODY$
LANGUAGE plpgsql;



--update table structure version from 6 to 7
CREATE OR REPLACE FUNCTION index_pilot._structure_version_6_7()
RETURNS VOID AS
$BODY$
BEGIN
   DROP VIEW IF EXISTS index_pilot.history;
   CREATE VIEW index_pilot.history AS
     SELECT date_trunc('second', entry_timestamp)::timestamp AS ts,
          datname AS db, schemaname AS schema, relname AS table,
          indexrelname AS index, pg_size_pretty(indexsize_before) AS size_before,
          pg_size_pretty(indexsize_after) AS size_after,
          (indexsize_before::float/indexsize_after)::numeric(12,2) AS ratio,
          pg_size_pretty(estimated_tuples) AS tuples, date_trunc('seconds', reindex_duration) AS duration
     FROM index_pilot.reindex_history ORDER BY id DESC;

   UPDATE index_pilot.tables_version SET version=7;
   RETURN;
END;
$BODY$
LANGUAGE plpgsql;


--update table structure version from 7 to 8
CREATE OR REPLACE FUNCTION index_pilot._structure_version_7_8()
RETURNS VOID AS
$BODY$
BEGIN
   CREATE TABLE IF NOT EXISTS index_pilot.current_processed_index
   (
      id bigserial primary key,
      mtime timestamptz not null default now(),
      datname name not null,
      schemaname name not null,
      relname name not null,
      indexrelname name not null
   );

   UPDATE index_pilot.tables_version SET version=8;
   RETURN;
END;
$BODY$
LANGUAGE plpgsql;


--convert patterns from psql format to like format
CREATE OR REPLACE FUNCTION index_pilot._pattern_convert(_var text)
RETURNS TEXT AS
$BODY$
BEGIN
    --replace * with .*
    _var := replace(_var, '*', '.*');
    --replace ? with .
    _var := replace(_var, '?', '.');

    RETURN  '^('||_var||')$';
END;
$BODY$
LANGUAGE plpgsql STRICT IMMUTABLE;


CREATE OR REPLACE FUNCTION index_pilot.get_setting(_datname text, _schemaname text, _relname text, _indexrelname text, _key TEXT)
RETURNS TEXT AS
$BODY$
DECLARE
    _value TEXT;
BEGIN
    PERFORM index_pilot._check_structure_version();
    --RAISE NOTICE 'DEBUG: |%|%|%|%|', _datname, _schemaname, _relname, _indexrelname;
    SELECT _t.value INTO _value FROM (
      --per index setting
      SELECT 1 AS priority, value FROM index_pilot.config WHERE
        _key=config.key
	AND (_datname      OPERATOR(pg_catalog.~) index_pilot._pattern_convert(config.datname))
	AND (_schemaname   OPERATOR(pg_catalog.~) index_pilot._pattern_convert(config.schemaname))
	AND (_relname      OPERATOR(pg_catalog.~) index_pilot._pattern_convert(config.relname))
	AND (_indexrelname OPERATOR(pg_catalog.~) index_pilot._pattern_convert(config.indexrelname))
	AND config.indexrelname IS NOT NULL
	AND TRUE
      UNION ALL
      --per table setting
      SELECT 2 AS priority, value FROM index_pilot.config WHERE
        _key=config.key
        AND (_datname      OPERATOR(pg_catalog.~) index_pilot._pattern_convert(config.datname))
        AND (_schemaname   OPERATOR(pg_catalog.~) index_pilot._pattern_convert(config.schemaname))
        AND (_relname      OPERATOR(pg_catalog.~) index_pilot._pattern_convert(config.relname))
        AND config.relname IS NOT NULL
        AND config.indexrelname IS NULL
      UNION ALL
      --per schema setting
      SELECT 3 AS priority, value FROM index_pilot.config WHERE
        _key=config.key
        AND (_datname      OPERATOR(pg_catalog.~) index_pilot._pattern_convert(config.datname))
        AND (_schemaname   OPERATOR(pg_catalog.~) index_pilot._pattern_convert(config.schemaname))
        AND config.schemaname IS NOT NULL
        AND config.relname IS NULL
      UNION ALL
      --per database setting
      SELECT 4 AS priority, value FROM index_pilot.config WHERE
        _key=config.key
        AND (_datname      OPERATOR(pg_catalog.~) index_pilot._pattern_convert(config.datname))
        AND config.datname IS NOT NULL
        AND config.schemaname IS NULL
      UNION ALL
      --global setting
      SELECT 5 AS priority, value FROM index_pilot.config WHERE
        _key=config.key
        AND config.datname IS NULL
    ) AS _t
    WHERE value IS NOT NULL
    ORDER BY priority
    LIMIT 1;
    RETURN _value;
END;
$BODY$
LANGUAGE plpgsql STABLE;


CREATE OR REPLACE FUNCTION index_pilot.set_or_replace_setting(_datname text, _schemaname text, _relname text, _indexrelname text, _key TEXT, _value text, _comment text)
RETURNS VOID AS
$BODY$
BEGIN
    PERFORM index_pilot._check_structure_version();
    IF _datname IS NULL       THEN
      INSERT INTO index_pilot.config (datname, schemaname, relname, indexrelname, key, value, comment)
      VALUES (_datname, _schemaname, _relname, _indexrelname, _key, _value, _comment)
      ON CONFLICT (key) WHERE datname IS NULL DO UPDATE SET value=EXCLUDED.value, comment=EXCLUDED.comment;
    ELSIF _schemaname IS NULL THEN
      INSERT INTO index_pilot.config (datname, schemaname, relname, indexrelname, key, value, comment)
      VALUES (_datname, _schemaname, _relname, _indexrelname, _key, _value, _comment)
      ON CONFLICT (key, datname) WHERE schemaname IS NULL DO UPDATE SET value=EXCLUDED.value, comment=EXCLUDED.comment;
    ELSIF _relname IS NULL    THEN
      INSERT INTO index_pilot.config (datname, schemaname, relname, indexrelname, key, value, comment)
      VALUES (_datname, _schemaname, _relname, _indexrelname, _key, _value, _comment)
      ON CONFLICT (key, datname, schemaname) WHERE relname IS NULL DO UPDATE SET value=EXCLUDED.value, comment=EXCLUDED.comment;
    ELSIF _indexrelname IS NULL THEN
      INSERT INTO index_pilot.config (datname, schemaname, relname, indexrelname, key, value, comment)
      VALUES (_datname, _schemaname, _relname, _indexrelname, _key, _value, _comment)
      ON CONFLICT (key, datname, schemaname, relname) WHERE indexrelname IS NULL DO UPDATE SET value=EXCLUDED.value, comment=EXCLUDED.comment;
    ELSE
      INSERT INTO index_pilot.config (datname, schemaname, relname, indexrelname, key, value, comment)
      VALUES (_datname, _schemaname, _relname, _indexrelname, _key, _value, _comment)
      ON CONFLICT (key, datname, schemaname, relname, indexrelname) DO UPDATE SET value=EXCLUDED.value, comment=EXCLUDED.comment;
    END IF;
    RETURN;
END;
$BODY$
LANGUAGE plpgsql;


DROP FUNCTION IF EXISTS index_pilot._remote_get_indexes_info(name,name,name,name);
CREATE OR REPLACE FUNCTION index_pilot._remote_get_indexes_info(_datname name, _schemaname name, _relname name, _indexrelname name)
RETURNS TABLE(datid OID, indexrelid OID, datname name, schemaname name, relname name, indexrelname name, indisvalid BOOLEAN, indexsize BIGINT, estimated_tuples BIGINT)
AS
$BODY$
DECLARE
   _use_toast_tables text;
BEGIN
    IF index_pilot._check_pg_version_bugfixed() THEN _use_toast_tables := 'True';
    ELSE _use_toast_tables := 'False';
    END IF;
    -- Secure FDW connection for querying index info
    PERFORM index_pilot._connect_securely(_datname);
    
    RETURN QUERY SELECT
      d.oid as datid, _res.indexrelid, _datname, _res.schemaname, _res.relname, _res.indexrelname, _res.indisvalid, _res.indexsize
      -- zero tuples clamp up 1 tuple (or bloat estimates will be infinity with all division by zero fun in multiple places)
      , greatest (1, indexreltuples)
      -- don't do relsize/relpage correction, that logic found to be way  too smart for his own good
      -- greatest (1, (CASE WHEN relpages=0 THEN indexreltuples ELSE relsize*indexreltuples/(relpages*current_setting('block_size')) END AS estimated_tuples))
    FROM
    dblink(_datname,
    format($SQL$
      SELECT
          x.indexrelid
        , n.nspname AS schemaname
        , c.relname
        , i.relname AS indexrelname
        , x.indisvalid
        , i.reltuples::BIGINT AS indexreltuples
        , pg_catalog.pg_relation_size(i.oid)::BIGINT AS indexsize
        --debug only
        --, pg_namespace.nspname
        --, c3.relname,
        --, am.amname
      FROM pg_index x
      JOIN pg_catalog.pg_class c           ON c.oid = x.indrelid
      JOIN pg_catalog.pg_class i           ON i.oid = x.indexrelid
      JOIN pg_catalog.pg_namespace n       ON n.oid = c.relnamespace
      JOIN pg_catalog.pg_am a              ON a.oid = i.relam
      --toast indexes info
      LEFT JOIN pg_catalog.pg_class c1     ON c1.reltoastrelid = c.oid AND n.nspname = 'pg_toast'
      LEFT JOIN pg_catalog.pg_namespace n1 ON c1.relnamespace = n1.oid

      WHERE TRUE
      --limit reindex for indexes on tables/mviews/toast
      --AND c.relkind = ANY (ARRAY['r'::"char", 't'::"char", 'm'::"char"])
      --limit reindex for indexes on tables/mviews (skip topast until bugfix of BUG #17268)
      AND ( (c.relkind = ANY (ARRAY['r'::"char", 'm'::"char"])) OR
            ( (c.relkind = 't'::"char") AND %s )
          )
      --ignore exclusion constraints
      AND NOT EXISTS (SELECT FROM pg_constraint WHERE pg_constraint.conindid=i.oid and pg_constraint.contype='x')
      --ignore indexes for system tables and index_pilot own tables
      AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'index_pilot')
      --ignore indexes on toast tables of system tables and index_pilot own tables
      AND (n1.nspname IS NULL OR n1.nspname NOT IN ('pg_catalog', 'information_schema', 'index_pilot'))
      --skip BRIN indexes... please see bug BUG #17205 https://www.postgresql.org/message-id/flat/17205-42b1d8f131f0cf97%%40postgresql.org
      AND a.amname NOT IN ('brin') AND x.indislive IS TRUE
      --skip indexes on temp relations
      AND c.relpersistence<>'t'
      --debug only
      --ORDER by 1,2,3
    $SQL$, _use_toast_tables)
    )
    AS _res(indexrelid OID, schemaname name, relname name, indexrelname name, indisvalid BOOLEAN, indexreltuples BIGINT, indexsize BIGINT),
    pg_database AS d
    WHERE
    d.datname=_datname
    AND
    (_schemaname IS NULL   OR _res.schemaname=_schemaname)
    AND
    (_relname IS NULL      OR _res.relname=_relname)
    AND
    (_indexrelname IS NULL OR _res.indexrelname=_indexrelname)
    ;
END;
$BODY$
LANGUAGE plpgsql;


DROP FUNCTION IF EXISTS index_pilot._record_indexes_info(name, name, name, name);
CREATE OR REPLACE FUNCTION index_pilot._record_indexes_info(_datname name, _schemaname name, _relname name, _indexrelname name, _force_populate boolean DEFAULT false)
RETURNS VOID
AS
$BODY$
DECLARE
  index_info RECORD;
BEGIN
  -- Establish dblink connection for managed services mode
  PERFORM index_pilot._dblink_connect_if_not(_datname);
  
  --merge index data fetched from the database and index_current_state
  --now keep info about all potentially interesting indexes (even small ones)
  --we can do it now because we keep exactly one entry in index_current_state per index (without history)
  WITH _actual_indexes AS (
     SELECT datid, indexrelid, datname, schemaname, relname, indexrelname, indisvalid, indexsize, estimated_tuples
     FROM index_pilot._remote_get_indexes_info(_datname, _schemaname, _relname, _indexrelname)
  ),
  _old_indexes AS (
       DELETE FROM index_pilot.index_current_state AS i
       WHERE NOT EXISTS (
           SELECT FROM _actual_indexes
           WHERE
               i.datid=_actual_indexes.datid
	        AND i.indexrelid=_actual_indexes.indexrelid
        )
        AND i.datname=_datname
        AND (_schemaname IS NULL   OR i.schemaname=_schemaname)
        AND (_relname IS NULL      OR i.relname=_relname)
        AND (_indexrelname IS NULL OR i.indexrelname=_indexrelname)
  )
  --todo: do something with ugly code duplication in index_pilot._reindex_index and index_pilot._record_indexes_info
  INSERT INTO index_pilot.index_current_state AS i
  (datid, indexrelid, datname, schemaname, relname, indexrelname, indisvalid, indexsize, estimated_tuples, best_ratio)
  SELECT datid, indexrelid, datname, schemaname, relname, indexrelname, indisvalid, indexsize, estimated_tuples,
    CASE
    --_force_populate=TRUE set (or write) best ratio to current ratio (except the case when index too small to be realiable estimated)
    WHEN (_force_populate AND indexsize > pg_size_bytes(index_pilot.get_setting(datname, schemaname, relname, indexrelname, 'minimum_reliable_index_size')))
      THEN indexsize::real/estimated_tuples::real
    --best_ratio estimation are NULL for the NEW index entries because we don't have any bloat information for it (default behavior)
    ELSE
      NULL
    END
    AS best_ratio
  FROM _actual_indexes
  ON CONFLICT (datid,indexrelid)
  DO UPDATE SET
    mtime=now(),
    datname=EXCLUDED.datname,
    schemaname=EXCLUDED.schemaname,
    relname=EXCLUDED.relname,
    indexrelname=EXCLUDED.indexrelname,
    indisvalid=EXCLUDED.indisvalid,
    indexsize=EXCLUDED.indexsize,
    estimated_tuples=EXCLUDED.estimated_tuples,
    best_ratio=
      CASE
      --_force_populate=TRUE set (or write) best ratio to current ratio (except the case when index too small to be realiable estimated)
      WHEN (_force_populate AND EXCLUDED.indexsize > pg_size_bytes(index_pilot.get_setting(EXCLUDED.datname, EXCLUDED.schemaname, EXCLUDED.relname, EXCLUDED.indexrelname, 'minimum_reliable_index_size')))
        THEN EXCLUDED.indexsize::real/EXCLUDED.estimated_tuples::real
      --if the new index size less than minimum_reliable_index_size - we cannot use it's size and tuples as reliable gauge for the best_ratio
      --so keep old best_ratio value instead as best guess
      WHEN (EXCLUDED.indexsize < pg_size_bytes(index_pilot.get_setting(EXCLUDED.datname, EXCLUDED.schemaname, EXCLUDED.relname, EXCLUDED.indexrelname, 'minimum_reliable_index_size')))
        THEN i.best_ratio
      --do not overrrid NULL best ratio (we don't have any reliable ratio info at this stage)
      WHEN (i.best_ratio IS NULL)
        THEN NULL
      -- set best_value as least from current value and new one
      ELSE
  least(i.best_ratio, EXCLUDED.indexsize::real/EXCLUDED.estimated_tuples::real)
      END;

  --tell about not valid indexes
  FOR index_info IN
    SELECT indexrelname, relname, schemaname, datname FROM index_pilot.index_current_state
      WHERE indisvalid IS FALSE
      AND datname=_datname
      AND (_schemaname IS NULL OR schemaname=_schemaname)
      AND (_relname IS NULL OR relname=_relname)
      AND (_indexrelname IS NULL OR indexrelname=_indexrelname)
    LOOP
      RAISE WARNING 'Not valid index % on %.% found in %.',
      index_info.indexrelname, index_info.schemaname, index_info.relname, index_info.datname;
    END LOOP;

END;
$BODY$
LANGUAGE plpgsql;



CREATE OR REPLACE FUNCTION index_pilot._cleanup_old_records() RETURNS VOID AS
$BODY$
BEGIN
    --TODO replace with fast distinct implementation
    WITH
        rels AS MATERIALIZED (SELECT DISTINCT datname, schemaname, relname, indexrelname FROM index_pilot.reindex_history),
        age_limit AS MATERIALIZED (SELECT *, now()-index_pilot.get_setting(datname,schemaname,relname,indexrelname,  'reindex_history_retention_period')::interval AS max_age FROM rels)
    DELETE FROM index_pilot.reindex_history
        USING age_limit
        WHERE
            reindex_history.datname=age_limit.datname
            AND reindex_history.schemaname=age_limit.schemaname
            AND reindex_history.relname=age_limit.relname
            AND reindex_history.indexrelname=age_limit.indexrelname
            AND reindex_history.entry_timestamp<age_limit.max_age;
    --clean index_current_state for not existing databases
    DELETE FROM index_pilot.index_current_state WHERE datid NOT IN (
      SELECT oid FROM pg_database
      WHERE
        NOT datistemplate
        AND datallowconn
        AND index_pilot.get_setting(datname, NULL, NULL, NULL, 'skip')::boolean IS DISTINCT FROM TRUE
    );

    RETURN;
END;
$BODY$
LANGUAGE plpgsql;




CREATE OR REPLACE FUNCTION index_pilot.get_index_bloat_estimates(_datname name)
RETURNS TABLE(datname name, schemaname name, relname name, indexrelname name, indexsize bigint, estimated_bloat real)
AS
$BODY$
DECLARE
   _datid OID;
BEGIN
  PERFORM index_pilot._check_structure_version();
  SELECT oid FROM pg_database d WHERE d.datname = _datname INTO _datid;
  -- compare current size to tuples ratio with the the best value
  RETURN QUERY
  SELECT _datname, i.schemaname, i.relname, i.indexrelname, i.indexsize,
  (i.indexsize::real/(i.best_ratio*estimated_tuples::real)) AS estimated_bloat
  FROM index_pilot.index_current_state AS i
  WHERE i.datid = _datid
  -- AND indisvalid IS TRUE
  --NULLS FIRST because indexes listed with NULL in estimated bloat going to be reindexed on next cron run
  --start from maximum bloated indexes
  ORDER BY estimated_bloat DESC NULLS FIRST;
END;
$BODY$
LANGUAGE plpgsql STRICT;




CREATE OR REPLACE FUNCTION index_pilot._reindex_index(_datname name, _schemaname name, _relname name, _indexrelname name)
RETURNS VOID
AS
$BODY$
DECLARE
  _indexsize_before BIGINT;
  _indexsize_after  BIGINT;
  _timestamp        TIMESTAMP;
  _reindex_duration INTERVAL;
  _analyze_duration INTERVAL :='0s';
  _estimated_tuples BIGINT;
  _indexrelid OID;
  _datid OID;
  _indisvalid BOOLEAN;
BEGIN
  -- Establish secure dblink connection via FDW (always recreate for reliability)
  BEGIN
    PERFORM index_pilot._connect_securely(_datname);
    RAISE NOTICE 'Created secure FDW connection: %', _datname;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Failed to create secure FDW connection "%": %', _datname, SQLERRM;
  END;

  --RAISE NOTICE 'working with %.%.% %', _datname, _schemaname, _relname, _indexrelname;

  --get initial actual index size and verify that the index indeed exists in the target database
  --PS: english articles are driving me mad periodically
  SELECT indexsize, estimated_tuples INTO _indexsize_before, _estimated_tuples
  FROM index_pilot._remote_get_indexes_info(_datname, _schemaname, _relname, _indexrelname)
  WHERE indisvalid IS TRUE;
  --index doesn't exist anymore
  IF NOT FOUND THEN
    RETURN;
  END IF;

  --perform reindex index using async dblink
  _timestamp := pg_catalog.clock_timestamp ();
  
  -- Simple async REINDEX CONCURRENTLY (fire-and-forget)
  IF dblink_send_query(_datname, 'REINDEX INDEX CONCURRENTLY '||pg_catalog.quote_ident(_schemaname)||'.'||pg_catalog.quote_ident(_indexrelname)) = 1 THEN
    RAISE NOTICE 'REINDEX CONCURRENTLY %I.%I started successfully (async)', _schemaname, _indexrelname;
    
    -- Simple check - is it still busy immediately?
    IF dblink_is_busy(_datname) = 1 THEN
      RAISE NOTICE 'REINDEX %I.%I is running in background', _schemaname, _indexrelname;
    ELSE
      -- Quick completion, get result
      PERFORM dblink_get_result(_datname);
      RAISE NOTICE 'REINDEX CONCURRENTLY %I.%I completed quickly', _schemaname, _indexrelname;
    END IF;
  ELSE
    RAISE NOTICE 'Failed to send async REINDEX for %I.%I - please execute manually: REINDEX INDEX CONCURRENTLY %I.%I;', _schemaname, _indexrelname, _schemaname, _indexrelname;
  END IF;

  _reindex_duration := pg_catalog.clock_timestamp ()-_timestamp;

  -- Fire-and-forget mode: REINDEX is running asynchronously
  -- Log the start of reindex operation immediately
  INSERT INTO index_pilot.reindex_history (
    datname, schemaname, relname, indexrelname,
    indexsize_before, indexsize_after, estimated_tuples, reindex_duration, analyze_duration,
    entry_timestamp
  ) VALUES (
    _datname, _schemaname, _relname, _indexrelname,
    _indexsize_before, _indexsize_before, _estimated_tuples, '0'::interval, '0'::interval,  -- Placeholder values
    now()
  );
  
  RAISE NOTICE 'REINDEX STARTED: %I.%I (fire-and-forget mode) - size before: %s', 
    _schemaname, _indexrelname, pg_size_pretty(_indexsize_before);
  
  -- The actual reindex completion and final size will be detected by periodic monitoring
  -- when it runs next time and compares current vs recorded sizes
END;
$BODY$
LANGUAGE plpgsql STRICT;



CREATE OR REPLACE PROCEDURE index_pilot.do_reindex(_datname name, _schemaname name, _relname name, _indexrelname name, _force BOOLEAN DEFAULT FALSE)
AS
$BODY$
DECLARE
  _index RECORD;
BEGIN
  PERFORM index_pilot._check_structure_version();

  IF _datname = ANY(dblink_get_connections()) IS NOT TRUE THEN
    PERFORM index_pilot._dblink_connect_if_not(_datname);
  END IF;
  FOR _index IN
    SELECT datname, schemaname, relname, indexrelname, indexsize, estimated_bloat
    -- index_size_threshold check logic moved to get_index_bloat_estimates
    -- force switch mean ignore index_rebuild_scale_factor and reindex all suitable indexes
    -- indexes too small (less than index_size_threshold) or manually set to skip in config will be ignored even with force switch
    -- todo: think about it someday
    FROM index_pilot.get_index_bloat_estimates(_datname)
    WHERE
      (_schemaname IS NULL OR schemaname=_schemaname)
      AND
      (_relname IS NULL OR relname=_relname)
      AND
      (_indexrelname IS NULL OR indexrelname=_indexrelname)
      AND
      (_force OR
          (
            --skip too small indexes to have any interest
            indexsize >= pg_size_bytes(index_pilot.get_setting(datname, schemaname, relname, indexrelname, 'index_size_threshold'))
            --skip indexes set to skip
            AND index_pilot.get_setting(datname, schemaname, relname, indexrelname, 'skip')::boolean IS DISTINCT FROM TRUE
            -- AND index_pilot.get_setting (for future configurability)
            AND (
                  estimated_bloat IS NULL
                  OR estimated_bloat >= index_pilot.get_setting(datname, schemaname, relname, indexrelname, 'index_rebuild_scale_factor')::float
            )
          )
      )
    LOOP
       INSERT INTO index_pilot.current_processed_index(
          datname,
          schemaname,
          relname,
          indexrelname
       )
       VALUES (
          _index.datname,
          _index.schemaname,
          _index.relname,
          _index.indexrelname
       );
       
       PERFORM index_pilot._reindex_index(_index.datname, _index.schemaname, _index.relname, _index.indexrelname);
       
       DELETE FROM index_pilot.current_processed_index
       WHERE
          datname=_index.datname AND
          schemaname=_index.schemaname AND
          relname=_index.relname AND
          indexrelname=_index.indexrelname;
    END LOOP;
  RETURN;
END;
$BODY$
LANGUAGE plpgsql;


--user callable shell over index_pilot._record_indexes_info(...  _force_populate=>TRUE)
--use to populate index bloa info from current state without reindexing
CREATE OR REPLACE FUNCTION index_pilot.do_force_populate_index_stats(_datname name, _schemaname name, _relname name, _indexrelname name)
RETURNS VOID
AS
$BODY$
BEGIN
  PERFORM index_pilot._check_structure_version();
  PERFORM index_pilot._dblink_connect_if_not(_datname);
  PERFORM index_pilot._record_indexes_info(_datname, _schemaname, _relname, _indexrelname, _force_populate=>TRUE);
  RETURN;
END;
$BODY$
LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION index_pilot._check_lock()
RETURNS bigint AS
$BODY$
DECLARE
  _id bigint;
  _is_not_running boolean;
BEGIN
  SELECT oid FROM pg_namespace WHERE nspname='index_pilot' INTO _id;
  SELECT pg_try_advisory_lock(_id) INTO _is_not_running;
  IF NOT _is_not_running THEN
      RAISE 'The previous launch of the index_pilot.periodic is still running.';
  END IF;
  RETURN _id;
END;
$BODY$
LANGUAGE plpgsql;


CREATE OR REPLACE PROCEDURE index_pilot._cleanup_our_not_valid_indexes() AS
$BODY$
DECLARE
  _index RECORD;
BEGIN
  FOR _index IN
    SELECT datname, schemaname, relname, indexrelname FROM
    index_pilot.current_processed_index
  LOOP
    PERFORM index_pilot._dblink_connect_if_not(_index.datname);
    IF EXISTS (SELECT FROM dblink(_index.datname,
           format(
            $SQL$
      SELECT x.indexrelid
      FROM pg_index x
      JOIN pg_catalog.pg_class c           ON c.oid = x.indrelid
      JOIN pg_catalog.pg_class i           ON i.oid = x.indexrelid
      JOIN pg_catalog.pg_namespace n       ON n.oid = c.relnamespace

      WHERE
        n.nspname = '%1$s'
        AND c.relname = '%2$s'
        AND i.relname = '%3$s_ccnew'
        AND x.indisvalid IS FALSE
        $SQL$
    , _index.schemaname, _index.relname, _index.indexrelname)) AS _res(indexrelid OID) )
    THEN
      IF NOT EXISTS (SELECT FROM dblink(_index.datname,
           format(
            $SQL$
        SELECT x.indexrelid
        FROM pg_index x
        JOIN pg_catalog.pg_class c           ON c.oid = x.indrelid
        JOIN pg_catalog.pg_class i           ON i.oid = x.indexrelid
        JOIN pg_catalog.pg_namespace n       ON n.oid = c.relnamespace

      WHERE
        n.nspname = '%1$s'
        AND c.relname = '%2$s'
        AND i.relname = '%3$s'
        $SQL$
    , _index.schemaname, _index.relname, _index.indexrelname)) AS _res(indexrelid OID) )
      THEN
        RAISE WARNING 'The invalid index %.%_ccnew exists, but no original index %.% was found in database %', _index.schemaname, _index.indexrelname, _index.schemaname, _index.indexrelname, _index.datname;
      END IF;
      PERFORM dblink(_index.datname, format('DROP INDEX CONCURRENTLY %I.%I_ccnew', _index.schemaname, _index.indexrelname));
      RAISE WARNING 'The invalid index %.%_ccnew was dropped in database %', _index.schemaname, _index.indexrelname, _index.datname;
    END IF;
    DELETE FROM index_pilot.current_processed_index
       WHERE
          datname=_index.datname AND
          schemaname=_index.schemaname AND
          relname=_index.relname AND
          indexrelname=_index.indexrelname;

  END LOOP;
END;
$BODY$
LANGUAGE plpgsql;


DROP PROCEDURE IF EXISTS index_pilot.periodic(BOOLEAN);
CREATE OR REPLACE PROCEDURE index_pilot.periodic(real_run BOOLEAN DEFAULT FALSE, force BOOLEAN DEFAULT FALSE) AS
$BODY$
DECLARE
  _datname name;
  _schemaname name;
  _relname name;
  _indexrelname name;
  _id bigint;
BEGIN
    IF NOT index_pilot._check_pg14_version_bugfixed()
      THEN
         RAISE 'The database version % affected by PostgreSQL bug BUG #17485 which make use pg_index_pilot unsafe, please update to latest minor release. For additional info please see:
       https://www.postgresql.org/message-id/202205251144.6t4urostzc3s@alvherre.pgsql',
        current_setting('server_version');
    END IF;
    IF NOT index_pilot._check_pg_version_bugfixed()
    THEN
        RAISE WARNING 'The database version % affected by PostgreSQL bugs which make use pg_index_pilot potentially unsafe, please update to latest minor release. For additional info please see:
   https://www.postgresql.org/message-id/E1mumI4-0001Zp-PB@gemulon.postgresql.org
   and
   https://www.postgresql.org/message-id/E1n8C7O-00066j-Q5@gemulon.postgresql.org',
      current_setting('server_version');
    END IF;

    SELECT index_pilot._check_lock() INTO _id;
    PERFORM index_pilot.check_update_structure_version();

    -- Managed services mode: process only current database
    delete from index_pilot.reindex_history
    where datname = current_database()
    and entry_timestamp < now() - coalesce(
            index_pilot.get_setting(datname, schemaname, relname, indexrelname, 'reindex_history_retention_period')::interval,
            '10 years'::interval
        );

    -- Process current database
    perform index_pilot._record_indexes_info(current_database(), null, null, null);

    if real_run then
        call index_pilot.do_reindex(current_database(), null, null, null, force);
    end if;

    -- Complete reindex history records for fire-and-forget operations
    -- Update size_after and reindex_duration for records that have placeholder values
    WITH completed_reindexes AS (
        UPDATE index_pilot.reindex_history 
        SET 
            indexsize_after = (
                SELECT indexsize 
                FROM index_pilot._remote_get_indexes_info(datname, schemaname, relname, indexrelname)
                WHERE indisvalid IS TRUE
            ),
            reindex_duration = now() - entry_timestamp
        WHERE 
            datname = current_database()
            AND indexsize_after = indexsize_before  -- Placeholder values
            AND entry_timestamp > now() - interval '1 hour'  -- Recent records only
            AND EXISTS (
                SELECT 1 
                FROM index_pilot._remote_get_indexes_info(datname, schemaname, relname, indexrelname)
                WHERE indisvalid IS TRUE
            )
        RETURNING datname, schemaname, relname, indexrelname, indexsize_after, estimated_tuples
    )
    -- Update best_ratio for successfully reindexed indexes
    UPDATE index_pilot.index_current_state AS ics
    SET best_ratio = cr.indexsize_after::real / GREATEST(1, cr.estimated_tuples)::real
    FROM completed_reindexes cr
    WHERE ics.datname = cr.datname
      AND ics.schemaname = cr.schemaname
      AND ics.relname = cr.relname
      AND ics.indexrelname = cr.indexrelname
      AND cr.indexsize_after > pg_size_bytes(
          index_pilot.get_setting(cr.datname, cr.schemaname, cr.relname, cr.indexrelname, 'minimum_reliable_index_size')
      );

    PERFORM pg_advisory_unlock(_id);
END;
$BODY$
LANGUAGE plpgsql;

-- Permission check function for managed services mode
create or replace function index_pilot.check_permissions()
returns table(permission text, status boolean) as
$BODY$
begin
    return query
    select 'Can create indexes'::text,
           has_database_privilege(current_database(), 'CREATE');

    return query
    select 'Can read pg_stat_user_indexes'::text,
           has_table_privilege('pg_stat_user_indexes', 'SELECT');

    return query
    select 'Has dblink extension'::text,
           exists (select 1 from pg_extension where extname = 'dblink');

    return query
    select 'Has postgres_fdw extension'::text,
           exists (select 1 from pg_extension where extname = 'postgres_fdw');

    return query
    select 'Has index_pilot_self server'::text,
           exists (select 1 from pg_foreign_server where srvname = 'index_pilot_self');

    return query
    select 'Has user mapping for dblink'::text,
           exists (
               select 1 from pg_user_mappings 
               where srvname = 'index_pilot_self' 
               and usename = current_user
           );

    -- Check if we can REINDEX by trying to find at least one index we own
    return query
    select 'Can REINDEX (owns indexes)'::text,
           exists (
           select 1 from pg_index i
               join pg_class c on i.indexrelid = c.oid
               join pg_namespace n on c.relnamespace = n.oid
               where n.nspname not in ('pg_catalog', 'information_schema')
               and pg_has_role(c.relowner, 'USAGE')
               limit 1
           );
end;
$BODY$
language plpgsql;

-- At installation, show permission status and configuration information
do $$
declare
    _perm record;
    _all_ok boolean := true;
begin
    raise notice 'pg_index_pilot - monitoring current database only';
    raise notice 'Database: %', current_database();
    raise notice '';
    raise notice 'Checking permissions...';

    for _perm in select * from index_pilot.check_permissions() loop
        raise notice '  %: %',
                rpad(_perm.permission, 30),
            case when _perm.status then 'OK' else 'MISSING' end;
        if not _perm.status then
                _all_ok := false;
        end if;
    end loop;

    raise notice '';
    if _all_ok then
        raise notice 'All permissions OK. You can use pg_index_pilot.';
    else
        raise warning 'Some permissions are missing. pg_index_pilot may not work correctly.';
    end if;

    raise notice '';
    raise notice 'Usage: call index_pilot.periodic(true);  -- true = perform actual reindexing';
end $$;

-- Setup functions for FDW + DB-Link configuration (managed services mode)

-- Function to setup foreign server for self-connection
create or replace function index_pilot.setup_fdw_self_connection(
    _host text default 'localhost',
    _port integer default null,
    _dbname text default null
) returns text as
$BODY$
declare
    _actual_port integer;
    _actual_dbname text;
    _result text;
begin
    -- Use current connection parameters if not provided
    _actual_port := coalesce(_port, current_setting('port')::integer);
    _actual_dbname := coalesce(_dbname, current_database());
    
    -- Create foreign server if it doesn't exist
    if not exists (select 1 from pg_foreign_server where srvname = 'index_pilot_self') then
        execute format('create server index_pilot_self foreign data wrapper postgres_fdw options (host %L, port %L, dbname %L)', 
                       _host, _actual_port::text, _actual_dbname);
        _result := 'Created foreign server index_pilot_self';
    else
        _result := 'Foreign server index_pilot_self already exists';
    end if;
    
    return _result;
end;
$BODY$
language plpgsql;

-- Function to setup user mapping for index_pilot user
create or replace function index_pilot.setup_user_mapping(
    _username text default null,
    _password text default null
) returns text as
$BODY$
declare
    _actual_username text;
    _result text;
begin
    -- Use current user if not provided
    _actual_username := coalesce(_username, current_user);
    
    -- Check if foreign server exists
    if not exists (select 1 from pg_foreign_server where srvname = 'index_pilot_self') then
        raise exception 'Foreign server index_pilot_self does not exist. Run setup_fdw_self_connection() first.';
    end if;
    
    -- Create or update user mapping
    if exists (
        select 1 from pg_user_mappings 
        where srvname = 'index_pilot_self' 
        and usename = _actual_username
    ) then
        if _password is not null then
            execute format('alter user mapping for %I server index_pilot_self options (set password %L)', 
                           _actual_username, _password);
            _result := format('Updated user mapping for %s', _actual_username);
        else
            _result := format('User mapping for %s already exists', _actual_username);
        end if;
    else
        if _password is null then
            raise exception 'Password is required for new user mapping';
        end if;
        
        execute format('create user mapping for %I server index_pilot_self options (user %L, password %L)', 
                       _actual_username, _actual_username, _password);
        _result := format('Created user mapping for %s', _actual_username);
    end if;
    
    return _result;
end;
$BODY$
language plpgsql;

-- Check postgres_fdw setup status and permissions  
create or replace function index_pilot.check_fdw_security_status() 
returns table(component text, status text, details text) as
$BODY$
begin
    -- Check postgres_fdw extension
    return query select 
        'postgres_fdw extension'::text,
        case when exists (select 1 from pg_extension where extname = 'postgres_fdw') 
             then 'INSTALLED' else 'MISSING' end::text,
        case when exists (select 1 from pg_extension where extname = 'postgres_fdw')
             then 'postgres_fdw extension is available'
             else 'Run: CREATE EXTENSION postgres_fdw;' end::text;

    -- Check FDW usage privilege
    return query select 
        'FDW usage privilege'::text,
        case when has_foreign_data_wrapper_privilege(current_user, 'postgres_fdw', 'USAGE')
             then 'GRANTED' else 'DENIED' end::text,
        case when has_foreign_data_wrapper_privilege(current_user, 'postgres_fdw', 'USAGE')
             then format('User %s can use postgres_fdw', current_user)
             else format('REQUIRED: GRANT USAGE ON FOREIGN DATA WRAPPER postgres_fdw TO %s;', current_user) end::text;
             
    -- Check foreign server
    return query select 
        'Foreign server'::text,
        case when exists (select 1 from pg_foreign_server where srvname = 'index_pilot_self')
             then 'EXISTS' else 'MISSING' end::text,
        case when exists (select 1 from pg_foreign_server where srvname = 'index_pilot_self')
             then 'index_pilot_self server configured'
             else 'Run setup_rds_connection() to create' end::text;
             
    -- Check user mapping
    return query select 
        'User mapping'::text,
        case when exists (select 1 from pg_user_mappings where srvname = 'index_pilot_self' and usename = current_user)
             then 'EXISTS' else 'MISSING' end::text,
        case when exists (select 1 from pg_user_mappings where srvname = 'index_pilot_self' and usename = current_user)
             then format('Secure password mapping exists for %s', current_user)
             else 'Run setup_rds_connection() to create' end::text;
             
    -- Overall security status
    return query select 
        'Security compliance'::text,
        case when has_foreign_data_wrapper_privilege(current_user, 'postgres_fdw', 'USAGE')
                  and exists (select 1 from pg_foreign_server where srvname = 'index_pilot_self')
                  and exists (select 1 from pg_user_mappings where srvname = 'index_pilot_self' and usename = current_user)
             then 'SECURE' else 'SETUP_REQUIRED' end::text,
        case when has_foreign_data_wrapper_privilege(current_user, 'postgres_fdw', 'USAGE')
                  and exists (select 1 from pg_foreign_server where srvname = 'index_pilot_self')
                  and exists (select 1 from pg_user_mappings where srvname = 'index_pilot_self' and usename = current_user)
             then 'Secure implementation: ONLY postgres_fdw USER MAPPING (no plain text passwords)'
             else 'Complete setup_rds_connection() for secure operation' end::text;
end;
$BODY$
language plpgsql;

-- Setup secure connection using postgres_fdw USER MAPPING ONLY
-- Secure approach: password provided once via CREATE USER MAPPING
CREATE OR REPLACE FUNCTION index_pilot.setup_rds_connection(_host text, _port integer DEFAULT 5432, _username text DEFAULT 'index_pilot', _password text DEFAULT NULL)
RETURNS text
AS
$BODY$
DECLARE
    _setup_result text;
    _has_fdw_usage boolean;
BEGIN
    -- Check if user has USAGE privilege on postgres_fdw
    SELECT has_foreign_data_wrapper_privilege(current_user, 'postgres_fdw', 'USAGE') INTO _has_fdw_usage;
    
    IF NOT _has_fdw_usage THEN
        RAISE EXCEPTION 'ERROR: User % does not have USAGE privilege on postgres_fdw.

REQUIRED SETUP:
1. Connect as database owner or admin user:
   psql -h % -U <admin_user> -d %

2. Grant FDW usage to index_pilot:
   GRANT USAGE ON FOREIGN DATA WRAPPER postgres_fdw TO %;

3. Then retry this function.

NOTE: This follows security best practices to use ONLY postgres_fdw USER MAPPING (no plain text passwords).', 
                current_user, _host, current_database(), current_user;
    END IF;
    
    -- Password is required for secure USER MAPPING
    IF _password IS NULL THEN
        RAISE EXCEPTION 'Password is required for secure postgres_fdw USER MAPPING setup';
    END IF;
    
    -- Setup FDW foreign server
    SELECT index_pilot.setup_fdw_self_connection(_host, _port, null) INTO _setup_result;
    
    -- Setup USER MAPPING with password (stored securely in PostgreSQL catalog)
    SELECT index_pilot.setup_user_mapping(_username, _password) INTO _setup_result;
    
    -- Test the secure FDW connection
    BEGIN
        PERFORM dblink_connect_u('test_fdw', 'index_pilot_self');
        PERFORM dblink_disconnect('test_fdw');
        RETURN format('SUCCESS: Secure postgres_fdw USER MAPPING configured for %s@%s:%s (password stored in PostgreSQL catalog)', _username, _host, _port);
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'FDW connection test failed: %', SQLERRM;
    END;
END;
$BODY$
LANGUAGE plpgsql;

-- Convenience function to setup complete FDW configuration
create or replace function index_pilot.setup_fdw_complete(
    _password text,
    _host text default 'localhost',
    _port integer default null,
    _username text default null
) returns table(step text, result text) as
$BODY$
declare
    _setup_result text;
begin
    -- Step 1: Setup foreign server
    select index_pilot.setup_fdw_self_connection(_host, _port, null) into _setup_result;
    return query select 'Foreign Server'::text, _setup_result;
    
    -- Step 2: Setup user mapping
    select index_pilot.setup_user_mapping(_username, _password) into _setup_result;
    return query select 'User Mapping'::text, _setup_result;
    
    -- Step 3: Setup connection parameters
    select index_pilot.setup_rds_connection(_host, _port, coalesce(_username, 'index_pilot'), _password) into _setup_result;
    return query select 'Connection Setup'::text, _setup_result;
    
    -- Step 4: Test connection
    begin
        perform dblink_connect_u('test_connection', 'index_pilot_self');
        perform dblink_disconnect('test_connection');
        return query select 'Connection Test'::text, 'SUCCESS - dblink can connect via FDW'::text;
    exception when others then
        return query select 'Connection Test'::text, format('FAILED - %s', sqlerrm)::text;
    end;
end;
$BODY$
language plpgsql;

-- Function to check FDW configuration status
create or replace function index_pilot.check_fdw_status()
returns table(component text, status text, details text) as
$BODY$
begin
    -- Check postgres_fdw extension
    return query
    select 'postgres_fdw extension'::text,
           case when exists (select 1 from pg_extension where extname = 'postgres_fdw') 
                then 'OK' else 'MISSING' end::text,
           case when exists (select 1 from pg_extension where extname = 'postgres_fdw') 
                then 'Extension is installed' 
                else 'Run: CREATE EXTENSION postgres_fdw;' end::text;
    
    -- Check foreign server
    return query
    select 'Foreign server'::text,
           case when exists (select 1 from pg_foreign_server where srvname = 'index_pilot_self') 
                then 'OK' else 'MISSING' end::text,
           case when exists (select 1 from pg_foreign_server where srvname = 'index_pilot_self') 
                then 'Server index_pilot_self exists'
                else 'Run: SELECT index_pilot.setup_fdw_self_connection();' end::text;
    
    -- Check user mapping
    return query
    select 'User mapping'::text,
           case when exists (
               select 1 from pg_user_mappings 
               where srvname = 'index_pilot_self' and usename = current_user
           ) then 'OK' else 'MISSING' end::text,
           case when exists (
               select 1 from pg_user_mappings 
               where srvname = 'index_pilot_self' and usename = current_user
           ) then format('Mapping exists for user %s', current_user)
           else format('Run: SELECT index_pilot.setup_user_mapping(''%s'', ''your_password'');', current_user) end::text;
end;
$BODY$
language plpgsql;


