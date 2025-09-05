\set ON_ERROR_STOP

-- disable useless (in this particular case) notice noise
set client_min_messages to WARNING;


drop function if exists index_pilot.check_pg_version_bugfixed();
create or replace function index_pilot._check_pg_version_bugfixed()
returns boolean as
$BODY$
begin
  if ((current_setting('server_version_num')::integer >= 120010) and
      (current_setting('server_version_num')::integer < 130000)) or
    ((current_setting('server_version_num')::integer >= 130006) and
      (current_setting('server_version_num')::integer < 140000)) or
    (current_setting('server_version_num')::integer >= 140002)
  then return true;
  else return false;
  end if;
end;
$BODY$
language plpgsql;

-- Preflight environment check aggregating key requirements and setup status
create or replace function index_pilot.check_environment()
returns table(component text, is_ok boolean, details text) as
$BODY$
declare
  _missing_permissions_count integer;
  _res record;
  _fdw_self_ok boolean := false;
begin
  -- PostgreSQL version
  return query 
  select 
    'PostgreSQL version (>=13)'::text,
    (current_setting('server_version_num')::int >= 130000),
    current_setting('server_version');

  -- Known bugfix statuses
  return query 
  select 
    'Known bugs fixed (PG12/13/14 chain)'::text,
    index_pilot._check_pg_version_bugfixed(),
    case when index_pilot._check_pg_version_bugfixed() then 'Minor version is safe' else 'Upgrade to latest minor recommended' end;

  return query 
  select 
    'PG14 bug #17485 fixed'::text,
    index_pilot._check_pg14_version_bugfixed(),
    case when index_pilot._check_pg14_version_bugfixed() then 'Not affected' else 'Update to 14.4 or newer' end;

  -- Extensions
  return query 
  select 
    'Extension: dblink'::text,
    exists (select 1 from pg_extension where extname = 'dblink'),
    'Run: create extension dblink;';

  return query 
  select 
    'Extension: postgres_fdw'::text,
    exists (select 1 from pg_extension where extname = 'postgres_fdw'),
    'Run: create extension postgres_fdw;';

  -- Schema presence
  return query 
  select 
    'Schema: index_pilot'::text,
    exists (select 1 from pg_namespace where nspname = 'index_pilot'),
    '';

  -- Required tables
  for _res in
    select unnest(array['config','index_current_state','reindex_history','current_processed_index','tables_version']) as tbl
  loop
    return query
    select 
      format('Table: index_pilot.%s', _res.tbl),
      exists (
        select 1 from information_schema.tables 
        where table_schema = 'index_pilot' and table_name = _res.tbl
      ),
      '';
  end loop;

  -- Core routines presence
  return query 
  select 
    'Function: index_pilot.version()'::text,
    exists (
      select 1 from pg_proc p join pg_namespace n on p.pronamespace = n.oid
      where n.nspname = 'index_pilot' and p.proname = 'version'
    ),
    '';

  return query 
  select 
    'Procedure: index_pilot.periodic'::text,
    exists (
      select 1 from pg_proc p join pg_namespace n on p.pronamespace = n.oid
      where n.nspname = 'index_pilot' and p.proname = 'periodic'
    ),
    '';

  return query
  select 
    'Procedure: index_pilot.do_reindex'::text,
    exists (
      select 1 from pg_proc p join pg_namespace n on p.pronamespace = n.oid
      where n.nspname = 'index_pilot' and p.proname = 'do_reindex'
    ),
    '';

  return query 
  select 
    'Function: index_pilot.get_index_bloat_estimates'::text,
    exists (
      select 1 from pg_proc p join pg_namespace n on p.pronamespace = n.oid
      where n.nspname = 'index_pilot' and p.proname = 'get_index_bloat_estimates'
    ),
    '';

  return query 
  select 
    'Function: index_pilot.check_permissions'::text,
    exists (
      select 1 from pg_proc p join pg_namespace n on p.pronamespace = n.oid
      where n.nspname = 'index_pilot' and p.proname = 'check_permissions'
    ),
    '';

  -- Permissions summary
  select 
    count(*) into _missing_permissions_count 
  from index_pilot.check_permissions() as p 
  where p.status = false;

  return query 
  select 
    'Permissions summary'::text,
    (_missing_permissions_count = 0),
    format('Missing: %s', _missing_permissions_count);

  -- FDW security status (detailed lines)
  for _res in select * from index_pilot.check_fdw_security_status() loop
    return query 
    select 
      format('FDW: %s', _res.component)::text,
      (lower(_res.status) in ('ok','installed','granted','exists','secure','configured')),
      _res.details::text;
  end loop;

  -- Control DB architecture checks
  return query 
  select 
    'Control DB: table index_pilot.target_databases'::text,
    exists (
      select 1 from information_schema.tables where table_schema = 'index_pilot' and table_name = 'target_databases'
    ),
    'Required for multi-database control mode';

  if exists (
    select 1 
    from information_schema.tables
    where 
      table_schema = 'index_pilot' 
      and table_name = 'target_databases'
  ) then
    return query 
    select 
      'Control DB: registered targets'::text,
      ((select count(*) from index_pilot.target_databases where enabled) > 0),
      (select count(*)::text from index_pilot.target_databases);

    return query 
    select 
      'Safety: current DB not listed as target'::text,
      not exists (
        select 1 
        from index_pilot.target_databases 
        where database_name = current_database()
        ),
      'Do not register the control database as a target';
  end if;

  -- Best-effort FDW connectivity test
  begin
    perform dblink_connect_u('env_test', 'index_pilot_self');
    perform dblink_disconnect('env_test');
    _fdw_self_ok := true;
    exception when others then
    _fdw_self_ok := false;
  end;

  return query 
    select 
    'FDW self-connection test'::text,
    _fdw_self_ok,
    case when _fdw_self_ok then 'Connected via user mapping' else 'Run setup_fdw_self_connection() and setup_user_mapping()' end;

  return;
end;
$BODY$
language plpgsql;


drop function if exists index_pilot.check_pg14_version_bugfixed();
create or replace function index_pilot._check_pg14_version_bugfixed()
returns boolean as
$BODY$
begin
  if (current_setting('server_version_num')::integer >= 140000) and
    (current_setting('server_version_num')::integer < 140004)
  then return false;
  else return true;
  end if;
end;
$BODY$
language plpgsql;


do $$
begin
  if current_setting('server_version_num')<'13'
  then
    raise 'This library works only for PostgreSQL 13 or higher!';
  else
    if not index_pilot._check_pg_version_bugfixed()
    then
       raise warning 'The database version % is affected by PostgreSQL bugs which make using pg_index_pilot potentially unsafe, please update to latest minor release. For additional info please see:
   https://www.postgresql.org/message-id/E1mumI4-0001Zp-PB@gemulon.postgresql.org
   and
   https://www.postgresql.org/message-id/E1n8C7O-00066j-Q5@gemulon.postgresql.org',
       current_setting('server_version');
    end if;
    if not index_pilot._check_pg14_version_bugfixed()
      then
         raise warning 'The database version % is affected by PostgreSQL BUG #17485 which makes using pg_index_pilot unsafe, please update to latest minor release. For additional info please see:
       https://www.postgresql.org/message-id/202205251144.6t4urostzc3s@alvherre.pgsql',
        current_setting('server_version');
    end if;
  end if;
end; 
$$;

create extension if not exists dblink;
-- alter extension dblink update;


-- current version of code
create or replace function index_pilot.version()
returns text as
$BODY$
begin
  return '1.04';
end;
$BODY$
language plpgsql immutable;


-- minimum table structure version required
create or replace function index_pilot._check_structure_version()
returns void as
$BODY$
declare
  _tables_version integer;
  _required_version integer := 1;
begin
    select version into strict _tables_version from index_pilot.tables_version;
    if (_tables_version<_required_version) then
      raise exception 'Current tables version % is less than minimally required % for % code version, please update tables structure', _tables_version, _required_version, index_pilot.version();
    end if;
end;
$BODY$
language plpgsql;


create or replace function index_pilot.check_update_structure_version()
returns void as
$BODY$
declare
   _tables_version integer;
   _required_version integer := 1;
begin
  select version into strict _tables_version from index_pilot.tables_version;

  while (_tables_version<_required_version) loop
    execute format('select index_pilot._structure_version_%s_%s()', _tables_version, _tables_version+1);
    _tables_version := _tables_version+1;
  end loop;

  return;
end;
$BODY$
language plpgsql;


-- set dblink connection for current database using FDW approach
-- Secure connection using ONLY postgres_fdw user mapping (secure approach)
create or replace function index_pilot._connect_securely(_datname name) returns void as
$BODY$
begin
  -- CRITICAL: Prevent deadlocks - never allow reindex in the same database
  -- Control database architecture is REQUIRED
  if _datname = current_database() then
    raise exception 'Cannot connect to current database % - this causes deadlocks. pg_index_pilot must be run from a separate control database.', _datname;
  end if;
    
  -- Disconnect existing connection if any
  if _datname = any(dblink_get_connections()) then
    perform dblink_disconnect(_datname);
  end if;
    
  -- Use ONLY postgres_fdw with user mapping (secure approach)
  -- Password is stored securely in PostgreSQL catalog, not in plain text
  declare
    _fdw_server_name text;
  begin
    -- Control database architecture is REQUIRED - get the FDW server for the target database
    select fdw_server_name into _fdw_server_name
    from index_pilot.target_databases
    where database_name = _datname
    and enabled = true;
        
    if _fdw_server_name is null then
      raise exception 'Target database % not registered or not enabled in index_pilot.target_databases. Control database setup required.', _datname;
    end if;
        
    perform dblink_connect_u(_datname, _fdw_server_name);

  exception when others then
    raise exception 'FDW connection failed for database % using server %: %', _datname, _fdw_server_name, sqlerrm;
  end;
end;
$BODY$
language plpgsql;


create or replace function index_pilot._dblink_connect_if_not(_datname name) returns void as
$BODY$
begin
  -- Use secure FDW connection if not already connected
  -- Handle null case when no connections exist
  if dblink_get_connections() is null or not (_datname = any(dblink_get_connections())) then
    perform index_pilot._connect_securely(_datname);
  end if;
  
  return;
end;
$BODY$
language plpgsql;


create or replace function index_pilot._remote_get_indexes_indexrelid(_datname name)
returns table(
  datname name, 
  schemaname name, 
  relname name, 
  indexrelname name, 
  indexrelid oid
) as
$BODY$
declare
  _use_toast_tables text;
begin
  if index_pilot._check_pg_version_bugfixed() then 
    _use_toast_tables := 'True';
  else 
    _use_toast_tables := 'False';
  end if;
    
  -- Secure FDW connection for querying indexes
  perform index_pilot._connect_securely(_datname);
    
  return query select
    _datname, 
    _res.schemaname,
    _res.relname,
    _res.indexrelname,
    _res.indexrelid
  from
    dblink(
      _datname,
      format(
        $SQL$
          select
            n.nspname as schemaname,
            c.relname,
            i.relname as indexrelname,
            x.indexrelid
          from pg_index x
          join pg_catalog.pg_class c on c.oid = x.indrelid
          join pg_catalog.pg_class i on i.oid = x.indexrelid
          join pg_catalog.pg_namespace n on n.oid = c.relnamespace
          join pg_catalog.pg_am a on a.oid = i.relam
          -- TOAST indexes info
          left join pg_catalog.pg_class c1 on c1.reltoastrelid = c.oid and n.nspname = 'pg_toast'
          left join pg_catalog.pg_namespace n1 on c1.relnamespace = n1.oid
          where 
            true
            -- limit reindex for indexes on tables/mviews/TOAST
            -- and c.relkind = any (ARRAY['r'::"char", 't'::"char", 'm'::"char"])
            -- limit reindex for indexes on tables/mviews (skip TOAST until bugfix of BUG #17268)
            and ((c.relkind = any (ARRAY['r'::"char", 'm'::"char"])) or ((c.relkind = 't'::"char") and %s))
            -- ignore exclusion constraints
            and not exists (select from pg_constraint where pg_constraint.conindid=i.oid and pg_constraint.contype='x')
            -- ignore indexes for system tables and index_pilot own tables
            and n.nspname not in ('pg_catalog', 'information_schema', 'index_pilot')
            -- ignore indexes on TOAST tables of system tables and index_pilot own tables
            and (n1.nspname is null or n1.nspname not in ('pg_catalog', 'information_schema', 'index_pilot'))
            -- skip BRIN indexes... please see BUG #17205 https://www.postgresql.org/message-id/flat/17205-42b1d8f131f0cf97%%40postgresql.org
            and a.amname not in ('brin') and x.indislive
            -- skip indexes on temp relations
            and c.relpersistence<>'t'
            -- debug only
            -- order by 1,2,3
        $SQL$, 
        _use_toast_tables
      )
    )
    as _res(schemaname name, relname name, indexrelname name, indexrelid oid);
end;
$BODY$
language plpgsql;


-- convert patterns from psql format to like format
create or replace function index_pilot._pattern_convert(_var text)
returns text as
$BODY$
begin
  -- replace * with .*
  _var := replace(_var, '*', '.*');
  -- replace ? with .
  _var := replace(_var, '?', '.');

  return  '^('||_var||')$';
end;
$BODY$
language plpgsql strict immutable;


create or replace function index_pilot.get_setting(_datname text, _schemaname text, _relname text, _indexrelname text, _key text)
returns text as
$BODY$
declare
  _value text;
begin
  perform index_pilot._check_structure_version();
  -- raise notice 'debug: |%|%|%|%|', _datname, _schemaname, _relname, _indexrelname;
  select _t.value into _value from (
    -- per index setting
    select 
      1 as priority,
      value from index_pilot.config 
    where
      _key=config.key
	    and (_datname OPERATOR(pg_catalog.~) index_pilot._pattern_convert(config.datname))
	    and (_schemaname OPERATOR(pg_catalog.~) index_pilot._pattern_convert(config.schemaname))
	    and (_relname OPERATOR(pg_catalog.~) index_pilot._pattern_convert(config.relname))
	    and (_indexrelname OPERATOR(pg_catalog.~) index_pilot._pattern_convert(config.indexrelname))
	    and config.indexrelname is not null
	    and true
    union all
    -- per table setting
    select 
      2 as priority,
      value from index_pilot.config 
    where
      _key=config.key
      and (_datname OPERATOR(pg_catalog.~) index_pilot._pattern_convert(config.datname))
      and (_schemaname OPERATOR(pg_catalog.~) index_pilot._pattern_convert(config.schemaname))
      and (_relname OPERATOR(pg_catalog.~) index_pilot._pattern_convert(config.relname))
      and config.relname is not null
      and config.indexrelname is null
    union all
    -- per schema setting
    select 
      3 as priority,
      value from index_pilot.config 
    where
      _key=config.key
      and (_datname OPERATOR(pg_catalog.~) index_pilot._pattern_convert(config.datname))
      and (_schemaname OPERATOR(pg_catalog.~) index_pilot._pattern_convert(config.schemaname))
      and config.schemaname is not null
      and config.relname is null
    union all
    -- per database setting
    select 
      4 as priority,
      value from index_pilot.config 
    where
      _key=config.key
      and (_datname      OPERATOR(pg_catalog.~) index_pilot._pattern_convert(config.datname))
      and config.datname is not null
      and config.schemaname is null
    union all
    -- global setting
    select 
      5 as priority,
      value from index_pilot.config 
    where
      _key=config.key
      and config.datname is null
    ) as _t
    where value is not null
    order by priority
    limit 1;
  
  return _value;
end;
$BODY$
language plpgsql stable;


create or replace function index_pilot.set_or_replace_setting(_datname text, _schemaname text, _relname text, _indexrelname text, _key text, _value text, _comment text)
returns void as
$BODY$
begin
    perform index_pilot._check_structure_version();
    if _datname is null then
      insert into index_pilot.config (datname, schemaname, relname, indexrelname, key, value, comment)
      values (_datname, _schemaname, _relname, _indexrelname, _key, _value, _comment)
      on conflict (key) 
      where datname is null 
      do update set 
        value=excluded.value, 
        comment=excluded.comment;
    elsif _schemaname is null then
      insert into index_pilot.config (datname, schemaname, relname, indexrelname, key, value, comment)
      values (_datname, _schemaname, _relname, _indexrelname, _key, _value, _comment)
      on conflict (key, datname) 
      where schemaname is null 
      do update set 
        value=excluded.value, 
        comment=excluded.comment;
    elsif _relname is null    then
      insert into index_pilot.config (datname, schemaname, relname, indexrelname, key, value, comment)
      values (_datname, _schemaname, _relname, _indexrelname, _key, _value, _comment)
      on conflict (key, datname, schemaname)
      where relname is null 
      do update set 
        value=excluded.value, 
        comment=excluded.comment;
    ELSIF _indexrelname is null then
      insert into index_pilot.config (datname, schemaname, relname, indexrelname, key, value, comment)
      values (_datname, _schemaname, _relname, _indexrelname, _key, _value, _comment)
      on conflict (key, datname, schemaname, relname) 
      where indexrelname is null 
      do update set 
        value=excluded.value, 
        comment=excluded.comment;
    else
      insert into index_pilot.config (datname, schemaname, relname, indexrelname, key, value, comment)
      values (_datname, _schemaname, _relname, _indexrelname, _key, _value, _comment)
      on conflict (key, datname, schemaname, relname, indexrelname) 
      do update set 
        value=excluded.value, 
        comment=excluded.comment;
    end if;
    return;
end;
$BODY$
language plpgsql;


drop function if exists index_pilot._remote_get_indexes_info(name,name,name,name);
create or replace function index_pilot._remote_get_indexes_info(_datname name, _schemaname name, _relname name, _indexrelname name)
returns table(
  datid oid,
  indexrelid oid,
  datname name,
  schemaname name,
  relname name,
  indexrelname name,
  indisvalid boolean,
  indexsize bigint,
  estimated_tuples bigint
) as
$BODY$
declare
  _use_toast_tables text;
begin
  if index_pilot._check_pg_version_bugfixed() then 
    _use_toast_tables := 'True';
  else 
    _use_toast_tables := 'False';
  end if;
    
  -- Secure FDW connection for querying index info
  perform index_pilot._connect_securely(_datname);

  return query 
  select
    d.oid as datid,
    _res.indexrelid,
    _datname,
    _res.schemaname,
    _res.relname,
    _res.indexrelname,
    _res.indisvalid,
    _res.indexsize,
    -- zero tuples clamp up 1 tuple (or bloat estimates will be infinity with all division by zero fun in multiple places)
    greatest(1, indexreltuples)
    -- don't do relsize/relpage correction, that logic found to be way  too smart for his own good
    -- greatest (1, (case when relpages=0 then indexreltuples else relsize*indexreltuples/(relpages*current_setting('block_size')) end as estimated_tuples))
  from
    dblink(_datname,
      format(
        $SQL$
        select
          x.indexrelid,
          n.nspname as schemaname,
          c.relname,
          i.relname as indexrelname,
          x.indisvalid,
          i.reltuples::bigint as indexreltuples,
          pg_catalog.pg_relation_size(i.oid)::bigint as indexsize
          -- debug only
          -- , pg_namespace.nspname
          -- , c3.relname,
          -- , am.amname
        from pg_index x
        join pg_catalog.pg_class c           on c.oid = x.indrelid
        join pg_catalog.pg_class i           on i.oid = x.indexrelid
        join pg_catalog.pg_namespace n       on n.oid = c.relnamespace
        join pg_catalog.pg_am a              on a.oid = i.relam
        -- TOAST indexes info
        left join pg_catalog.pg_class c1     on c1.reltoastrelid = c.oid and n.nspname = 'pg_toast'
        left join pg_catalog.pg_namespace n1 on c1.relnamespace = n1.oid

        where true
        -- limit reindex for indexes on tables/mviews/TOAST
        -- and c.relkind = any (ARRAY['r'::"char", 't'::"char", 'm'::"char"])
        -- limit reindex for indexes on tables/mviews (skip TOAST until bugfix of BUG #17268)
        and ((c.relkind = any (ARRAY['r'::"char", 'm'::"char"])) or ((c.relkind = 't'::"char") and %s))
        -- ignore exclusion constraints
        and not exists (select from pg_constraint where pg_constraint.conindid=i.oid and pg_constraint.contype='x')
        -- ignore indexes for system tables and index_pilot own tables
        and n.nspname not in ('pg_catalog', 'information_schema', 'index_pilot')
        -- ignore indexes on TOAST tables of system tables and index_pilot own tables
        and (n1.nspname is null or n1.nspname not in ('pg_catalog', 'information_schema', 'index_pilot'))
        -- skip BRIN indexes... please see BUG #17205 https://www.postgresql.org/message-id/flat/17205-42b1d8f131f0cf97%%40postgresql.org
        and a.amname not in ('brin') and x.indislive
        -- skip indexes on temp relations
        and c.relpersistence<>'t'
        -- debug only
        -- order by 1,2,3
        $SQL$,
        _use_toast_tables
      )
    )
    as _res(
      indexrelid oid,
      schemaname name,
      relname name,
      indexrelname name,
      indisvalid boolean,
      indexreltuples bigint,
      indexsize bigint
    ),
    pg_database as d
    where
      d.datname=_datname
      and (_schemaname is null or _res.schemaname=_schemaname)
      and (_relname is null or _res.relname=_relname)
      and (_indexrelname is null or _res.indexrelname=_indexrelname);
end;
$BODY$
language plpgsql;


drop function if exists index_pilot._record_indexes_info(name, name, name, name);
create or replace function index_pilot._record_indexes_info(_datname name, _schemaname name, _relname name, _indexrelname name, _force_populate boolean default false)
returns void
as
$BODY$
declare
  index_info record;
begin
  -- Establish dblink connection for managed services mode
  perform index_pilot._dblink_connect_if_not(_datname);
  
  -- merge index data fetched from the database and index_current_state
  -- now keep info about all potentially interesting indexes (even small ones)
  -- we can do it now because we keep exactly one entry in index_current_state per index (without history)
  with _actual_indexes as (
    select datid, indexrelid, datname, schemaname, relname, indexrelname, indisvalid, indexsize, estimated_tuples
    from index_pilot._remote_get_indexes_info(_datname, _schemaname, _relname, _indexrelname)
  ),
  _old_indexes as (
    delete from index_pilot.index_current_state as i
    where not exists (
      select from _actual_indexes
      where
        i.datid=_actual_indexes.datid
	      and i.indexrelid=_actual_indexes.indexrelid
    )
    and i.datname=_datname
    and (_schemaname is null or i.schemaname=_schemaname)
    and (_relname is null or i.relname=_relname)
    and (_indexrelname is null or i.indexrelname=_indexrelname)
  )
  -- todo: do something with ugly code duplication in index_pilot._reindex_index and index_pilot._record_indexes_info
  insert into index_pilot.index_current_state as i
  (datid, indexrelid, datname, schemaname, relname, indexrelname, indisvalid, indexsize, estimated_tuples, best_ratio)
  select 
    datid, 
    indexrelid, 
    datname, 
    schemaname, 
    relname, 
    indexrelname, 
    indisvalid, 
    indexsize, 
    estimated_tuples,
  case
  -- _force_populate=true set (or write) best ratio to current ratio (except the case when index too small to be reliably estimated)
  when (_force_populate and indexsize > pg_size_bytes(index_pilot.get_setting(datname, schemaname, relname, indexrelname, 'minimum_reliable_index_size'))) then 
    indexsize::real/estimated_tuples::real
  -- best_ratio estimation are null for the new index entries because we don't have any bloat information for it (default behavior)
  else
      null
  end
  as best_ratio
  from _actual_indexes
  on conflict (datid,indexrelid)
  do update set
    mtime=now(),
    datname=excluded.datname,
    schemaname=excluded.schemaname,
    relname=excluded.relname,
    indexrelname=excluded.indexrelname,
    indisvalid=excluded.indisvalid,
    indexsize=excluded.indexsize,
    estimated_tuples=excluded.estimated_tuples,
    best_ratio=
      case
      -- _force_populate=true set (or write) best ratio to current ratio (except the case when index too small to be reliably estimated)
      when (_force_populate and excluded.indexsize > pg_size_bytes(index_pilot.get_setting(excluded.datname, excluded.schemaname, excluded.relname, excluded.indexrelname, 'minimum_reliable_index_size')))
        then excluded.indexsize::real/excluded.estimated_tuples::real
      -- if the new index size less than minimum_reliable_index_size - we cannot use it's size and tuples as reliable gauge for the best_ratio
      -- so keep old best_ratio value instead as best guess
      when (excluded.indexsize < pg_size_bytes(index_pilot.get_setting(excluded.datname, excluded.schemaname, excluded.relname, excluded.indexrelname, 'minimum_reliable_index_size')))
        then i.best_ratio
      -- do not overrrid null best ratio (we don't have any reliable ratio info at this stage)
      when (i.best_ratio is null)
        then null
      -- set best_value as least from current value and new one
      else
  least(i.best_ratio, excluded.indexsize::real/excluded.estimated_tuples::real)
      end;

  -- tell about not valid indexes
  for index_info in
    select indexrelname, relname, schemaname, datname from index_pilot.index_current_state
      where not indisvalid
      and datname=_datname
      and (_schemaname is null or schemaname=_schemaname)
      and (_relname is null or relname=_relname)
      and (_indexrelname is null or indexrelname=_indexrelname)
    loop
      raise warning 'Not valid index % on %.% found in %.',
      index_info.indexrelname, index_info.schemaname, index_info.relname, index_info.datname;
    end loop;
end;
$BODY$
language plpgsql;


create or replace function index_pilot._cleanup_old_records() returns void as
$BODY$
begin
  -- TODO replace with fast distinct implementation
  with
    rels as materialized (select distinct datname, schemaname, relname, indexrelname from index_pilot.reindex_history),
    age_limit as materialized (select *, now()-index_pilot.get_setting(datname,schemaname,relname,indexrelname,  'reindex_history_retention_period')::interval as max_age from rels)
  delete from index_pilot.reindex_history
    using age_limit
    where
      reindex_history.datname=age_limit.datname
      and reindex_history.schemaname=age_limit.schemaname
      and reindex_history.relname=age_limit.relname
      and reindex_history.indexrelname=age_limit.indexrelname
      and reindex_history.entry_timestamp<age_limit.max_age;
    -- clean index_current_state for not existing databases
  delete from index_pilot.index_current_state where datid not in (
    select oid from pg_database
    where
      not datistemplate
      and datallowconn
      and index_pilot.get_setting(datname, null, null, null, 'skip')::boolean is distinct from true
  );

  return;
end;
$BODY$
language plpgsql;


create or replace function index_pilot.get_index_bloat_estimates(_datname name)
returns table(
  datname name, 
  schemaname name, 
  relname name, 
  indexrelname name, 
  indexsize bigint, 
  estimated_bloat real
) as
$BODY$
declare
  _datid oid;
begin
  perform index_pilot._check_structure_version();
  select oid from pg_database d where d.datname = _datname into _datid;
  -- compare current size to tuples ratio with the the best value
  return query
  select 
    _datname, 
    i.schemaname, 
    i.relname, 
    i.indexrelname, 
    i.indexsize,
    (i.indexsize::real/(i.best_ratio*estimated_tuples::real)) as estimated_bloat
  from index_pilot.index_current_state as i
  where i.datid = _datid
  -- and indisvalid is true
  -- NULLS FIRST because indexes listed with null in estimated bloat going to be reindexed on next cron run
  -- start from maximum bloated indexes
  order by estimated_bloat DESC NULLS FIRST;
end;
$BODY$
language plpgsql strict;


create or replace function index_pilot._reindex_index(_datname name, _schemaname name, _relname name, _indexrelname name)
returns void
as
$BODY$
declare
  _indexsize_before bigint;
  _indexsize_after  bigint;
  _timestamp        timestamp;
  _reindex_duration interval;
  _analyze_duration interval :='0s';
  _estimated_tuples bigint;
  _indexrelid oid;
  _datid oid;
  _indisvalid boolean;
begin
  -- Establish dblink connection using FDW for secure password management
  -- Use the database name as connection name (not unique per index)
  if dblink_get_connections() is null or not (_datname = any(dblink_get_connections())) then
    -- Connect using the secure connection function which handles control database mode
    perform index_pilot._connect_securely(_datname);
    raise notice 'Created dblink connection: %', _datname;
  end if;

  -- raise notice 'working with %.%.% %', _datname, _schemaname, _relname, _indexrelname;

  -- get initial actual index size and verify that the index indeed exists in the target database
  select indexsize, estimated_tuples into _indexsize_before, _estimated_tuples
  from index_pilot._remote_get_indexes_info(_datname, _schemaname, _relname, _indexrelname)
  where indisvalid;
  -- index doesn't exist anymore
  if not found then
    return;
  end if;

  -- perform reindex index using synchronous dblink
  _timestamp := pg_catalog.clock_timestamp ();
  
  -- Perform REINDEX CONCURRENTLY synchronously (like the original pg_index_watch)
  -- This will wait for completion before returning
  begin
    perform dblink(_datname, 'reindex index concurrently '||pg_catalog.quote_ident(_schemaname)||'.'||pg_catalog.quote_ident(_indexrelname));
    raise notice 'reindex concurrently %.% completed successfully', _schemaname, _indexrelname;
  exception when others then
    raise notice 'reindex failed for %.%: %', _schemaname, _indexrelname, SQLERRM;
    -- Continue anyway, the index might have issues
  end;
  
  -- Don't disconnect - keep connection for reuse (like original)

  _reindex_duration := pg_catalog.clock_timestamp ()-_timestamp;

  -- Get the new index size after reindex
  select indexsize into _indexsize_after
  from index_pilot._remote_get_indexes_info(_datname, _schemaname, _relname, _indexrelname)
  where indisvalid;
  
  -- If index doesn't exist anymore or is invalid, use the original size
  if _indexsize_after is null then
    _indexsize_after := _indexsize_before;
  end if;

  -- Log the completed reindex operation
  insert into index_pilot.reindex_history (
    datname, 
    schemaname,
    relname,
    indexrelname,
    indexsize_before,
    indexsize_after, 
    estimated_tuples, 
    reindex_duration, 
    analyze_duration,
    entry_timestamp
  ) values (
    _datname, 
    _schemaname, 
    _relname, 
    _indexrelname,
    _indexsize_before,
    _indexsize_after, 
    _estimated_tuples, 
    _reindex_duration, 
    '0'::interval,
    now()
  );
  
  raise notice 'reindex COMPLETED: %.% - size before: %, size after: %, duration: %', 
    _schemaname, _indexrelname, 
    pg_size_pretty(_indexsize_before), 
    pg_size_pretty(_indexsize_after),
    _reindex_duration;
end;
$BODY$
language plpgsql strict;


create or replace procedure index_pilot.do_reindex(_datname name, _schemaname name, _relname name, _indexrelname name, _force boolean default false)
as
$BODY$
declare
  _index record;
begin
  perform index_pilot._check_structure_version();

  -- CRITICAL: Prevent running in the same database to avoid deadlocks
  if _datname = current_database() then
    raise exception 'Cannot REINDEX in current database % - this causes deadlocks. Use separate control database.', _datname;
  end if;

  -- Establish dblink connection before any transaction
  if dblink_get_connections() is null or not (_datname = any(dblink_get_connections())) then
    perform index_pilot._dblink_connect_if_not(_datname);
    commit; -- Commit after establishing connection to avoid lock issues
  end if;
  for _index in
    select datname, schemaname, relname, indexrelname, indexsize, estimated_bloat
    -- index_size_threshold check logic moved to get_index_bloat_estimates
    -- force switch mean ignore index_rebuild_scale_factor and reindex all suitable indexes
    -- indexes too small (less than index_size_threshold) or manually set to skip in config will be ignored even with force switch
    -- todo: think about it someday
    from index_pilot.get_index_bloat_estimates(_datname)
    where
      (_schemaname is null or schemaname=_schemaname)
      and
      (_relname is null or relname=_relname)
      and
      (_indexrelname is null or indexrelname=_indexrelname)
      and
      (_force or
          (
            -- skip too small indexes to have any interest
            indexsize >= pg_size_bytes(index_pilot.get_setting(datname, schemaname, relname, indexrelname, 'index_size_threshold'))
            -- skip indexes set to skip
            and index_pilot.get_setting(datname, schemaname, relname, indexrelname, 'skip')::boolean is distinct from true
            -- and index_pilot.get_setting (for future configurability)
            and (
                  estimated_bloat is null
                  or estimated_bloat >= index_pilot.get_setting(datname, schemaname, relname, indexrelname, 'index_rebuild_scale_factor')::float
            )
          )
      )
    loop
      -- Record what we're working on
      insert into index_pilot.current_processed_index(
        datname,
          schemaname,
          relname,
          indexrelname
      )
      values (
        _index.datname,
        _index.schemaname,
        _index.relname,
        _index.indexrelname
      );

      -- Log the reindex start with in_progress status
      -- Use cached data from index_current_state instead of remote call
      insert into index_pilot.reindex_history (
        database_name, datname, schemaname, relname, indexrelname,
        indexsize_before, indexsize_after, estimated_tuples, 
        reindex_duration, analyze_duration, entry_timestamp, status
      ) 
      select 
        database_name, 
        datname, 
        schemaname, 
        relname, 
        indexrelname,
        indexsize, 
        null, 
        estimated_tuples,  -- null until completion
        null, 
        null, 
        now(), 
        'in_progress'
      from index_pilot.index_current_state
      where datname = _index.datname
        and schemaname = _index.schemaname
        and relname = _index.relname
        and indexrelname = _index.indexrelname
        and indisvalid;
      
      -- commit to release all locks before starting synchronous reindex
      commit;
      
      -- Use synchronous REINDEX for reliability
      -- Synchronous approach provides immediate completion tracking and avoids async complexity
      begin
        -- Run REINDEX CONCURRENTLY synchronously
        perform dblink_exec(
          _index.datname,
          format('reindex index concurrently %I.%I', _index.schemaname, _index.indexrelname)
        );
           
        raise notice 'REINDEX CONCURRENTLY completed for %.%', _index.schemaname, _index.indexrelname;
           
        -- Get the final index size after reindex
        declare
          _final_size bigint;
        begin
          select indexsize into _final_size
          from index_pilot._remote_get_indexes_info(_index.datname, _index.schemaname, _index.relname, _index.indexrelname)
          where indisvalid;

          -- Update completion time, status, and final size in history
          update index_pilot.reindex_history
          set reindex_duration = clock_timestamp() - entry_timestamp,
              status = 'completed',
              indexsize_after = _final_size
          where datname = _index.datname
            and schemaname = _index.schemaname
            and relname = _index.relname
            and indexrelname = _index.indexrelname
            and status = 'in_progress';
        end;
             
      exception when others then
        raise warning 'REINDEX failed for %.%: %', _index.schemaname, _index.indexrelname, sqlerrm;
           
        -- Mark failed entry in history with error details
        update index_pilot.reindex_history
        set status = 'failed',
          error_message = sqlerrm,
          reindex_duration = clock_timestamp() - entry_timestamp
        where datname = _index.datname
          and schemaname = _index.schemaname
          and relname = _index.relname
          and indexrelname = _index.indexrelname
          and status = 'in_progress';
      end;
       
      -- Clean up tracking record
      delete from index_pilot.current_processed_index
      where datname=_index.datname 
        and schemaname=_index.schemaname 
        and relname=_index.relname 
        and indexrelname=_index.indexrelname;
      
      -- commit the cleanup
      commit;
       
      -- Completion tracking is handled synchronously above
    end loop;
  return;
end;
$BODY$
language plpgsql;


-- user callable shell over index_pilot._record_indexes_info(... _force_populate=>true)
-- use to populate index bloat info from current state without reindexing
create or replace function index_pilot.do_force_populate_index_stats(_datname name, _schemaname name, _relname name, _indexrelname name)
returns void
as
$BODY$
begin
  perform index_pilot._check_structure_version();
  perform index_pilot._dblink_connect_if_not(_datname);
  perform index_pilot._record_indexes_info(_datname, _schemaname, _relname, _indexrelname, _force_populate=>true);
  return;
end;
$BODY$
language plpgsql;


create or replace function index_pilot._check_lock()
returns bigint as
$BODY$
declare
  _id bigint;
  _is_not_running boolean;
begin
  select oid from pg_namespace where nspname='index_pilot' into _id;
  select pg_try_advisory_lock(_id) into _is_not_running;
  if not _is_not_running then
    raise 'The previous launch of the index_pilot.periodic is still running.';
  end if;
  return _id;
end;
$BODY$
language plpgsql;


create or replace procedure index_pilot._cleanup_our_not_valid_indexes() as
$BODY$
declare
  _index record;
begin
  for _index in
    select datname, schemaname, relname, indexrelname from
    index_pilot.current_processed_index
  loop
    -- Ensure we have a connection to the target database
    if dblink_get_connections() is null or not (_index.datname = any(dblink_get_connections())) then
        perform index_pilot._connect_securely(_index.datname);
    end if;
    
    if exists (
      select from dblink(_index.datname,
        format(
          $SQL$
            select x.indexrelid
            from pg_index x
            join pg_catalog.pg_class c on c.oid = x.indrelid
            join pg_catalog.pg_class i on i.oid = x.indexrelid
            join pg_catalog.pg_namespace n on n.oid = c.relnamespace

            where
              n.nspname = '%1$s'
              and c.relname = '%2$s'
              and i.relname = '%3$s_ccnew'
              and not x.indisvalid
          $SQL$, 
          _index.schemaname, 
          _index.relname, 
          _index.indexrelname
        )
      ) as _res(indexrelid oid))
    then
      if not exists (
        select from dblink(_index.datname,
          format(
            $SQL$
              select x.indexrelid
              from pg_index x
              join pg_catalog.pg_class c on c.oid = x.indrelid
              join pg_catalog.pg_class i on i.oid = x.indexrelid
              join pg_catalog.pg_namespace n on n.oid = c.relnamespace
            where
              n.nspname = '%1$s'
              and c.relname = '%2$s'
              and i.relname = '%3$s'
            $SQL$, 
            _index.schemaname, 
            _index.relname, 
            _index.indexrelname
          )
        ) as _res(indexrelid oid))
      then
        raise warning 'The invalid index %.%_ccnew exists, but no original index %.% was found in database %', _index.schemaname, _index.indexrelname, _index.schemaname, _index.indexrelname, _index.datname;
      end if;
      perform dblink(_index.datname, format('drop index concurrently %I.%I_ccnew', _index.schemaname, _index.indexrelname));
      raise warning 'The invalid index %.%_ccnew was dropped in database %', _index.schemaname, _index.indexrelname, _index.datname;
    end if;
    delete from index_pilot.current_processed_index
    where
      datname=_index.datname and
      schemaname=_index.schemaname and
      relname=_index.relname and
      indexrelname=_index.indexrelname;

  end loop;
end;
$BODY$
language plpgsql;


drop procedure if exists index_pilot.periodic(boolean);
create or replace procedure index_pilot.periodic(real_run boolean default false, force boolean default false) as
$BODY$
declare
  _datname name;
  _schemaname name;
  _relname name;
  _indexrelname name;
  _id bigint;
begin
  if not index_pilot._check_pg14_version_bugfixed()
  then
    raise 'The database version % is affected by PostgreSQL BUG #17485 which makes using pg_index_pilot unsafe, please update to latest minor release. For additional info please see:
    https://www.postgresql.org/message-id/202205251144.6t4urostzc3s@alvherre.pgsql',
    current_setting('server_version');
  end if;

  if not index_pilot._check_pg_version_bugfixed()
  then
    raise warning 'The database version % is affected by PostgreSQL bugs which make using pg_index_pilot potentially unsafe, please update to latest minor release. For additional info please see:
    https://www.postgresql.org/message-id/E1mumI4-0001Zp-PB@gemulon.postgresql.org
    and
    https://www.postgresql.org/message-id/E1n8C7O-00066j-Q5@gemulon.postgresql.org',
    current_setting('server_version');
  end if;

  select index_pilot._check_lock() into _id;
  perform index_pilot.check_update_structure_version();

  -- Check if we're in control database mode
  if exists (select 1 from pg_tables where schemaname = 'index_pilot' and tablename = 'target_databases') then
    -- Control database mode: process all enabled target databases
    for _datname in 
      select database_name from index_pilot.target_databases where enabled = true
      loop
      -- Clean old history for this database
        delete from index_pilot.reindex_history
        where datname = _datname
          and entry_timestamp < now() - coalesce(
            index_pilot.get_setting(datname, schemaname, relname, indexrelname, 'reindex_history_retention_period')::interval,
            '10 years'::interval
          );
            
        -- Record indexes for this database
        perform index_pilot._record_indexes_info(_datname, null, null, null);
            
        if real_run then
          call index_pilot.do_reindex(_datname, null, null, null, force);
        end if;
      end loop;
        
    -- Note: No need to update completed reindexes - all tracking is synchronous now
        
    -- Clean up any invalid _ccnew indexes from failed reindexes
    call index_pilot._cleanup_our_not_valid_indexes();
  else
    -- Standalone mode (shouldn't happen with our fixes, but keep for safety)
    raise exception 'Control database architecture required. Cannot run periodic in standalone mode.';
  end if;

  -- Update best_ratio for successfully completed reindexes
  -- All reindexes are synchronous so this updates recent completions
  update index_pilot.index_current_state as ics
  set best_ratio = rh.indexsize_after::real / greatest(1, rh.estimated_tuples)::real
  from index_pilot.reindex_history rh
  where ics.datname = rh.datname
    and ics.schemaname = rh.schemaname
    and ics.relname = rh.relname
    and ics.indexrelname = rh.indexrelname
    and rh.entry_timestamp > now() - interval '1 hour'
    and rh.indexsize_after > pg_size_bytes(
      index_pilot.get_setting(rh.datname, rh.schemaname, rh.relname, rh.indexrelname, 'minimum_reliable_index_size')
    )
    and (ics.best_ratio is null or rh.indexsize_after::real / greatest(1, rh.estimated_tuples)::real < ics.best_ratio);

  perform pg_advisory_unlock(_id);
end;
$BODY$
language plpgsql;


-- Permission check function for managed services mode
create or replace function index_pilot.check_permissions()
returns table(
  permission text, 
  status boolean
) as
$BODY$
begin
    return query
    select 
      'Can create indexes'::text, 
      has_database_privilege(current_database(), 'create'
    );

    return query
    select 
      'Can read pg_stat_user_indexes'::text,
      has_table_privilege('pg_stat_user_indexes', 'select'
    );

    return query
    select 
      'Has dblink extension'::text,
      exists (select 1 from pg_extension where extname = 'dblink'
    );

    return query
    select 
      'Has postgres_fdw extension'::text,
      exists (select 1 from pg_extension where extname = 'postgres_fdw');

    return query
    select 
      'Has index_pilot_self server'::text,
      exists (select 1 from pg_foreign_server where srvname = 'index_pilot_self');

    return query
    select 
      'Has user mapping for dblink'::text,
      exists (
        select 1 from pg_user_mappings 
        where srvname = 'index_pilot_self' 
          and usename = current_user
      );

    -- Check if we can reindex by trying to find at least one index we own
    return query
    select 
      'Can reindex (owns indexes)'::text,
      exists (
        select 1 from pg_index i
        join pg_class c on i.indexrelid = c.oid
        join pg_namespace n on c.relnamespace = n.oid
        where n.nspname not in ('pg_catalog', 'information_schema')
          and pg_has_role(c.relowner, 'usage')
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
    execute format(
      'create server index_pilot_self foreign data wrapper postgres_fdw options (host %L, port %L, dbname %L)', 
      _host, 
      _actual_port::text, 
      _actual_dbname
    );

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
      execute format(
        'alter user mapping for %I server index_pilot_self options (set password %L)', 
        _actual_username, 
        _password
      );

      _result := format('Updated user mapping for %s', _actual_username);
    else
      _result := format('User mapping for %s already exists', _actual_username);
    end if;

  else
    if _password is null then
      raise exception 'Password is required for new user mapping';
    end if;
        
    execute format(
      'create user mapping for %I server index_pilot_self options (user %L, password %L)', 
      _actual_username, 
      _actual_username, 
      _password
    );
      _result := format('Created user mapping for %s', _actual_username);
  end if;
    
  return _result;
end;
$BODY$
language plpgsql;


-- Check postgres_fdw setup status and permissions  
create or replace function index_pilot.check_fdw_security_status() 
returns table(
  component text,
  status text,
  details text
) as
$BODY$
begin
  -- Check postgres_fdw extension
  return query 
  select 
    'postgres_fdw extension'::text,
    case when exists (select 1 from pg_extension where extname = 'postgres_fdw') 
      then 'INSTALLED' else 'MISSING' end::text,
    case when exists (select 1 from pg_extension where extname = 'postgres_fdw')
      then 'postgres_fdw extension is available'
      else 'Run: create extension postgres_fdw;' end::text;

    -- Check FDW usage privilege
    return query 
    select 
      'FDW usage privilege'::text,
      case when has_foreign_data_wrapper_privilege(current_user, 'postgres_fdw', 'usage')
        then 'GRANTED' else 'DENIED' end::text,
      case when has_foreign_data_wrapper_privilege(current_user, 'postgres_fdw', 'usage')
        then format('User %s can use postgres_fdw', current_user)
        else format('REQUIRED: grant usage on foreign DATA WRAPPER postgres_fdw to %s;', current_user) end::text;
             
    -- Check foreign server
    return query 
    select 
      'Foreign server'::text,
      case when exists (select 1 from pg_foreign_server where srvname = 'index_pilot_self')
        then 'exists' else 'MISSING' end::text,
      case when exists (select 1 from pg_foreign_server where srvname = 'index_pilot_self')
        then 'index_pilot_self server configured'
        else 'Run setup_fdw_self_connection() to create' end::text;
             
    -- Check user mapping
    return query 
    select 
      'User mapping'::text,
      case when exists (select 1 from pg_user_mappings where srvname = 'index_pilot_self' and usename = current_user)
        then 'exists' else 'MISSING' end::text,
      case when exists (select 1 from pg_user_mappings where srvname = 'index_pilot_self' and usename = current_user)
        then format('Secure password mapping exists for %s', current_user)
        else 'Run setup_fdw_self_connection() to create' end::text;
             
    -- Overall security status
    return query 
    select 
      'Security compliance'::text,
      case when has_foreign_data_wrapper_privilege(current_user, 'postgres_fdw', 'usage')
          and exists (select 1 from pg_foreign_server where srvname = 'index_pilot_self')
          and exists (select 1 from pg_user_mappings where srvname = 'index_pilot_self' and usename = current_user)
        then 'SECURE' else 'SETUP_REQUIRED' end::text,
      case when has_foreign_data_wrapper_privilege(current_user, 'postgres_fdw', 'usage')
          and exists (select 1 from pg_foreign_server where srvname = 'index_pilot_self')
          and exists (select 1 from pg_user_mappings where srvname = 'index_pilot_self' and usename = current_user)
        then 'Secure implementation: ONLY postgres_fdw user mapping (no plain text passwords)'
        else 'Complete setup with setup_fdw_self_connection() and setup_user_mapping() for secure operation' end::text;
end;
$BODY$
language plpgsql;


-- Setup secure connection using postgres_fdw user mapping ONLY
-- Secure approach: password provided once via create user mapping
-- Works with any PostgreSQL instance (RDS, Cloud SQL, self-hosted, etc.)
create or replace function index_pilot.setup_connection(_host text, _port integer default 5432, _username text default 'index_pilot', _password text default null)
returns text
as
$BODY$
declare
  _setup_result text;
  _has_fdw_usage boolean;
begin
  -- Check if user has usage privilege on postgres_fdw
  select has_foreign_data_wrapper_privilege(current_user, 'postgres_fdw', 'usage') into _has_fdw_usage;
    
  if not _has_fdw_usage then
    raise exception 'ERROR: User % does not have usage privilege on postgres_fdw.

REQUIRED SETUP:
1. Connect as database owner or admin user:
   psql -h % -U <admin_user> -d %

2. Grant FDW usage to index_pilot:
   grant usage on foreign DATA WRAPPER postgres_fdw to %;

3. Then retry this function.

NOTE: This follows security best practices to use ONLY postgres_fdw user mapping (no plain text passwords).', 
      current_user, 
      _host, 
      current_database(), 
      current_user;
  end if;
    
  -- Password is required for secure user mapping
  if _password is null then
    raise exception 'Password is required for secure postgres_fdw user mapping setup';
  end if;
    
  -- Setup FDW foreign server
  select index_pilot.setup_fdw_self_connection(_host, _port, null) into _setup_result;
    
  -- Setup user mapping with password (stored securely in PostgreSQL catalog)
  select index_pilot.setup_user_mapping(_username, _password) into _setup_result;
    
  -- Test the secure FDW connection
  begin
    perform dblink_connect_u('test_fdw', 'index_pilot_self');
    perform dblink_disconnect('test_fdw');
    return format('SUCCESS: Secure postgres_fdw user mapping configured for %s@%s:%s (password stored in PostgreSQL catalog)', _username, _host, _port);

  exception when others then
    raise exception 'FDW connection test failed: %', SQLERRM;
  end;
end;
$BODY$
language plpgsql;


-- Convenience function to setup complete FDW configuration
create or replace function index_pilot.setup_fdw_complete(
  _password text,
  _host text default 'localhost',
  _port integer default null,
  _username text default null
) returns table(
  step text,
  result text
) as
$BODY$
declare
  _setup_result text;
begin
  -- Step 1: Setup foreign server
  select index_pilot.setup_fdw_self_connection(_host, _port, null) into _setup_result;
  return query 
  select 
    'Foreign Server'::text, 
    _setup_result;
    
  -- Step 2: Setup user mapping
  select index_pilot.setup_user_mapping(_username, _password) into _setup_result;
  return query 
  select 
    'User Mapping'::text, 
    _setup_result;
    
  -- Step 3: Setup connection parameters
  select index_pilot.setup_connection(_host, _port, coalesce(_username, 'index_pilot'), _password) into _setup_result;
  return query 
  select 
    'Connection Setup'::text, 
    _setup_result;
    
  -- Step 4: Test connection
  begin
    perform dblink_connect_u('test_connection', 'index_pilot_self');
    perform dblink_disconnect('test_connection');
    return query 
    select 
      'Connection Test'::text, 
      'SUCCESS - dblink can connect via FDW'::text;
    exception when others then
      return query 
      select 
        'Connection Test'::text, 
        format('FAILED - %s', sqlerrm)::text;
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
  select 
    'postgres_fdw extension'::text,
    case when exists (select 1 from pg_extension where extname = 'postgres_fdw') 
      then 'OK' else 'MISSING' end::text,
    case when exists (select 1 from pg_extension where extname = 'postgres_fdw') 
      then 'Extension is installed' 
      else 'Run: create extension postgres_fdw;' end::text;
    
    -- Check foreign server
    return query
    select 
      'Foreign server'::text,
      case when exists (select 1 from pg_foreign_server where srvname = 'index_pilot_self') 
        then 'OK' else 'MISSING' end::text,
      case when exists (select 1 from pg_foreign_server where srvname = 'index_pilot_self') 
        then 'Server index_pilot_self exists'
        else 'Run: select index_pilot.setup_fdw_self_connection();' end::text;
    
    -- Check user mapping
    return query
    select 
      'User mapping'::text,
      case when exists (
        select 1 from pg_user_mappings 
        where srvname = 'index_pilot_self' and usename = current_user
      ) 
        then 'OK' else 'MISSING' end::text,
      case when exists (
        select 1 from pg_user_mappings 
        where srvname = 'index_pilot_self' and usename = current_user
      ) 
        then format('Mapping exists for user %s', current_user)
        else format('Run: select index_pilot.setup_user_mapping(''%s'', ''your_password'');', current_user) end::text;
end;
$BODY$
language plpgsql;
