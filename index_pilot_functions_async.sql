-- Alternative approach: Use async dblink with proper connection management
-- The key is to establish the connection in the PROCEDURE (not function)
-- and keep it alive across transactions

create or replace procedure index_pilot.do_reindex(_datname name, _schemaname name, _relname name, _indexrelname name, _force boolean default false)
as
$BODY$
declare
  _index record;
  _conn_exists boolean;
begin
  perform index_pilot._check_structure_version();

  -- Check if connection exists
  _conn_exists := _datname = any(dblink_get_connections());
  
  -- Establish connection if needed (this will persist across COMMITs)
  if not _conn_exists then
    perform dblink_connect_u(_datname, 'index_pilot_self');
    -- COMMIT immediately after establishing connection
    COMMIT;
  end if;
  
  for _index in
    select datname, schemaname, relname, indexrelname, indexsize, estimated_bloat
    from index_pilot.get_index_bloat_estimates(_datname)
    where
      (_schemaname is null or schemaname=_schemaname)
      and (_relname is null or relname=_relname)
      and (_indexrelname is null or indexrelname=_indexrelname)
      and (_force or
          (
            indexsize >= pg_size_bytes(index_pilot.get_setting(datname, schemaname, relname, indexrelname, 'index_size_threshold'))
            and index_pilot.get_setting(datname, schemaname, relname, indexrelname, 'skip')::boolean is distinct from true
            and (estimated_bloat is null or estimated_bloat >= index_pilot.get_setting(datname, schemaname, relname, indexrelname, 'index_rebuild_scale_factor')::float)
          )
      )
    loop
       -- Record what we're working on
       insert into index_pilot.current_processed_index(datname, schemaname, relname, indexrelname)
       values (_index.datname, _index.schemaname, _index.relname, _index.indexrelname);
       
       -- Log the reindex start with NULL values for in-progress tracking
       insert into index_pilot.reindex_history (
         datname, schemaname, relname, indexrelname,
         indexsize_before, indexsize_after, estimated_tuples, 
         reindex_duration, analyze_duration, entry_timestamp
       ) 
       select 
         _index.datname, _index.schemaname, _index.relname, _index.indexrelname,
         indexsize, NULL, estimated_tuples,  -- NULL for in-progress
         NULL, NULL, now()
       from index_pilot._remote_get_indexes_info(_index.datname, _index.schemaname, _index.relname, _index.indexrelname)
       where indisvalid is true;
       
       -- COMMIT to release all locks before starting async REINDEX
       COMMIT;
       
       -- Start async REINDEX CONCURRENTLY
       -- This returns 1 if successful, 0 if failed
       if dblink_send_query(
           _index.datname, 
           format('REINDEX INDEX CONCURRENTLY %I.%I', _index.schemaname, _index.indexrelname)
       ) = 1 then
           raise notice 'Started async REINDEX CONCURRENTLY for %.%', _index.schemaname, _index.indexrelname;
           
           -- IMMEDIATELY COMMIT to ensure connection stays alive
           -- This is crucial - without this, the connection might close
           COMMIT;
           
           -- Optional: Check if reindex is actually running
           perform pg_sleep(0.5); -- Brief pause to let it start
           
           -- We could check pg_stat_activity here to confirm it's running
           perform 1 from pg_stat_activity 
           where query ilike '%reindex%concurrently%' || _index.indexrelname || '%'
           and pid != pg_backend_pid();
           
           if found then
               raise notice 'Confirmed: REINDEX is running for %.%', _index.schemaname, _index.indexrelname;
           else
               raise warning 'Warning: REINDEX may not be running for %.%', _index.schemaname, _index.indexrelname;
           end if;
       else
           raise warning 'Failed to start async REINDEX for %.%', _index.schemaname, _index.indexrelname;
       end if;
       
       -- Clean up tracking record
       delete from index_pilot.current_processed_index
       where datname=_index.datname 
         and schemaname=_index.schemaname 
         and relname=_index.relname 
         and indexrelname=_index.indexrelname;
       
       -- COMMIT the cleanup
       COMMIT;
       
       -- Note: The completion will be detected and recorded by periodic() 
       -- when it finds the index without _ccnew suffix and updates the NULL values
    end loop;
    
  -- DO NOT disconnect - keep connection alive for future operations
  -- The connection will persist and can be reused
  
  return;
end;
$BODY$
language plpgsql;

-- Simplified _reindex_index function for recording only
-- (No longer performs the actual reindex)
create or replace function index_pilot._reindex_index_record_only(_datname name, _schemaname name, _relname name, _indexrelname name)
returns void
as
$BODY$
declare
  _indexsize_before bigint;
  _estimated_tuples bigint;
begin
  -- Just record the operation, don't perform reindex
  -- The actual reindex is done async in do_reindex procedure
  
  select indexsize, estimated_tuples into _indexsize_before, _estimated_tuples
  from index_pilot._remote_get_indexes_info(_datname, _schemaname, _relname, _indexrelname)
  where indisvalid is true;
  
  if not found then
    return; -- Index doesn't exist
  end if;

  -- Insert with NULL values for in-progress operation
  insert into index_pilot.reindex_history (
    datname, schemaname, relname, indexrelname,
    indexsize_before, indexsize_after, estimated_tuples, 
    reindex_duration, analyze_duration, entry_timestamp
  ) values (
    _datname, _schemaname, _relname, _indexrelname,
    _indexsize_before, NULL, _estimated_tuples,
    NULL, NULL, now()
  );
  
  raise notice 'Recorded reindex start for %.% (size: %)', 
    _schemaname, _indexrelname, pg_size_pretty(_indexsize_before);
end;
$BODY$
language plpgsql strict;

-- Update periodic to detect completed reindexes and update NULL values
create or replace function index_pilot.update_completed_reindexes()
returns void as
$BODY$
declare
  _rec record;
  _new_size bigint;
  _duration interval;
begin
  -- Find reindex_history records with NULL values (in-progress)
  for _rec in 
    select id, datname, schemaname, relname, indexrelname, 
           indexsize_before, entry_timestamp
    from index_pilot.reindex_history
    where indexsize_after is null  -- Still in progress
      and entry_timestamp > now() - interval '24 hours'  -- Don't check ancient records
  loop
    -- Check if any _ccnew index exists (still reindexing)
    perform 1 
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = _rec.schemaname
      and c.relname ~ ('^' || _rec.indexrelname || '_ccnew[0-9]*$');
    
    if not found then
      -- No _ccnew index, reindex is complete (or failed)
      -- Get the current size
      select pg_relation_size((quote_ident(_rec.schemaname)||'.'||quote_ident(_rec.indexrelname))::regclass)
      into _new_size;
      
      if _new_size is not null then
        -- Calculate duration
        _duration := now() - _rec.entry_timestamp;
        
        -- Update the record
        update index_pilot.reindex_history
        set indexsize_after = _new_size,
            reindex_duration = _duration
        where id = _rec.id;
        
        raise notice 'Updated completed reindex: %.% - size %->%, duration %',
          _rec.schemaname, _rec.indexrelname,
          pg_size_pretty(_rec.indexsize_before),
          pg_size_pretty(_new_size),
          _duration;
      end if;
    end if;
  end loop;
end;
$BODY$
language plpgsql;