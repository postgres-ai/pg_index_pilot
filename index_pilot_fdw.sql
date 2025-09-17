begin;

-- Turn off useless (in this particular case) NOTICE noise
set client_min_messages to warning;

-- FDW and connection management functions for pg_index_pilot
-- This file contains all functions related to Foreign Data Wrapper (FDW) setup,
-- secure database connections, and connection management.

/*
 * Establish secure dblink connection to target database via postgres_fdw
 * Uses FDW user mapping for secure credentials, prevents deadlocks, auto-reconnects
 */
create function index_pilot._connect_securely(
  _datname name
) returns void as
$body$
begin
  -- CRITICAL: Prevent deadlocks - never allow reindex in the same database
  -- Control database architecture is REQUIRED
  if _datname = current_database() then
    raise exception using
      message = format(
        'Cannot connect to current database %s - this causes deadlocks.',
        _datname
      ),
      hint = 'pg_index_pilot must be run from separate control database.';
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
      raise exception using
        message = format(
          'Target database %s not registered or not enabled in index_pilot.target_databases.',
          _datname
        ),
        hint = 'Control database setup required.';
    end if;
        
    perform dblink_connect_u(_datname, _fdw_server_name);

  exception when others then
    raise exception using
      message = format(
        'FDW connection failed for database %s using server %s: %s',
        _datname,
        _fdw_server_name,
        sqlerrm
      );
  end;
end;
$body$
language plpgsql;


/*
 * Establish secure dblink connection if not already connected
 * Creates secure FDW connection only if needed, handles null connections case
 */
create function index_pilot._dblink_connect_if_not(
  _datname name
) returns void as
$body$
begin
  -- Use secure FDW connection if not already connected
  -- Handle null case when no connections exist
  if dblink_get_connections() is null or not (_datname = any(dblink_get_connections())) then
    perform index_pilot._connect_securely(_datname);
  end if;
  
  return;
end;
$body$
language plpgsql;


-- Setup functions for FDW + dblink configuration (managed services mode)

/*
 * Setup postgres_fdw server for secure self-connection
 * Creates 'index_pilot_self' foreign server for secure FDW connections, idempotent
 */
create function index_pilot.setup_fdw_self_connection(
  _host text default 'localhost',
  _port integer default null,
  _dbname text default null
) returns text as
$body$
declare
  _current_port text;
  _current_dbname text;
begin
  -- Use current connection's port and database if not specified
  _current_port := coalesce(_port::text, current_setting('port'));
  _current_dbname := coalesce(_dbname, current_database());
  
  -- Drop existing server if it exists (for reconfiguration)
  if exists (select from pg_foreign_server where srvname = 'index_pilot_self') then
    drop server index_pilot_self cascade;
  end if;
  
  -- Create the foreign server for self-connection
  execute format(
    'create server index_pilot_self foreign data wrapper postgres_fdw options (host %L, port %L, dbname %L)',
    _host, _current_port, _current_dbname
  );
  
  return format('FDW server created with host: %s, port: %s, dbname: %s', _host, _current_port, _current_dbname);
end;
$body$
language plpgsql;


/*
 * Setup user mapping for secure postgres_fdw authentication
 * Creates/updates user mapping for secure authentication without plain-text passwords
 */
create function index_pilot.setup_user_mapping(
  _username text default null,
  _password text default null
) returns text as
$body$
declare
  _current_user text;
  _result text;
begin
  -- Use current user if not specified
  _current_user := coalesce(_username, current_user);
  
  -- Validate that the foreign server exists
  if not exists (select from pg_foreign_server where srvname = 'index_pilot_self') then
    raise exception 'Foreign server index_pilot_self does not exist. Run setup_fdw_self_connection() first.';
  end if;
  
  -- Drop existing user mapping if it exists
  if exists (
    select from pg_user_mappings 
    where srvname = 'index_pilot_self' and usename = _current_user
  ) then
    execute format('drop user mapping for %I server index_pilot_self', _current_user);
  end if;
  
  -- Create new user mapping
  if _password is not null then
    execute format(
      'create user mapping for %I server index_pilot_self options (user %L, password %L)',
      _current_user, _current_user, _password
    );
    _result := format('User mapping created for %s with password', _current_user);
  else
    execute format(
      'create user mapping for %I server index_pilot_self options (user %L)',
      _current_user, _current_user
    );
    _result := format('User mapping created for %s without password (trust auth)', _current_user);
  end if;

  -- Additionally, when running on AWS RDS/Aurora, ensure mapping exists for the administrative role rds_superuser
  -- This role often becomes the effective executor for dblink_connect_u on RDS
  if exists (select 1 from pg_roles where rolname = 'rds_superuser') then
    -- Drop old mapping if present to avoid conflicts on older PostgreSQL versions without IF NOT EXISTS
    if exists (
      select 1 from pg_user_mappings
      where srvname = 'index_pilot_self' and usename = 'rds_superuser'
    ) then
      execute 'drop user mapping for rds_superuser server index_pilot_self';
    end if;
    -- Create mapping for rds_superuser that authenticates remotely as _current_user
    if _password is not null then
      execute format(
        'create user mapping for %I server index_pilot_self options (user %L, password %L)',
        'rds_superuser', _current_user, _password
      );
    else
      execute format(
        'create user mapping for %I server index_pilot_self options (user %L)',
        'rds_superuser', _current_user
      );
    end if;
  end if;
  return _result;
end;
$body$
language plpgsql;


/*
 * Comprehensive postgres_fdw security setup validation
 * Validates FDW configuration components with detailed status and guidance
 */
create function index_pilot.check_fdw_security_status() returns table(
  component text,
  status text,
  details text
) as
$body$
begin
  -- Check postgres_fdw extension
  return query select 
    'postgres_fdw extension'::text,
    case when exists (select from pg_extension where extname = 'postgres_fdw') 
      then 'INSTALLED' else 'MISSING' end::text,
    case when exists (select from pg_extension where extname = 'postgres_fdw') 
      then 'Extension is available for use' 
      else 'Run: create extension postgres_fdw;' end::text;
      
  -- Check FDW usage privilege
  return query select 
    'FDW usage privilege'::text,
    case when has_foreign_data_wrapper_privilege(current_user, 'postgres_fdw', 'usage') 
      then 'GRANTED' else 'DENIED' end::text,
    case when has_foreign_data_wrapper_privilege(current_user, 'postgres_fdw', 'usage') 
      then format('User %s can use postgres_fdw', current_user)
      else format('Run: grant usage on foreign data wrapper postgres_fdw to %s;', current_user) end::text;
      
  -- Check foreign server
  return query select 
    'Foreign server'::text,
    case when exists (select from pg_foreign_server where srvname = 'index_pilot_self') 
      then 'exists' else 'MISSING' end::text,
    case when exists (select from pg_foreign_server where srvname = 'index_pilot_self') 
      then 'Server index_pilot_self is configured'
      else 'Run: select index_pilot.setup_fdw_self_connection();' end::text;
      
  -- Check user mapping
  return query select 
    'User mapping'::text,
    case when exists (
      select from pg_user_mappings 
      where srvname = 'index_pilot_self' and usename = current_user
    ) 
      then 'exists' else 'MISSING' end::text,
    case when exists (
      select from pg_user_mappings 
      where srvname = 'index_pilot_self' and usename = current_user
    ) 
      then format('Mapping exists for user %s', current_user)
      else format('Run: select index_pilot.setup_user_mapping(''%s'', ''your_password'');', current_user) end::text;
      
  -- Overall security status
  return query select 
    'Overall security status'::text,
    case when (
      exists (select from pg_extension where extname = 'postgres_fdw') and
      has_foreign_data_wrapper_privilege(current_user, 'postgres_fdw', 'usage') and
      exists (select from pg_foreign_server where srvname = 'index_pilot_self') and
      exists (
        select from pg_user_mappings 
        where srvname = 'index_pilot_self' and usename = current_user
      )
    ) then 'SECURE' else 'SETUP_REQUIRED' end::text,
    case when (
      exists (select from pg_extension where extname = 'postgres_fdw') and
      has_foreign_data_wrapper_privilege(current_user, 'postgres_fdw', 'usage') and
      exists (select from pg_foreign_server where srvname = 'index_pilot_self') and
      exists (
        select from pg_user_mappings 
        where srvname = 'index_pilot_self' and usename = current_user
      )
    ) then 'All FDW components are properly configured'
      else 'Complete the missing setup steps above' end::text;
end;
$body$
language plpgsql;


/*
 * Complete secure FDW connection setup for pg_index_pilot
 * Orchestrates secure postgres_fdw setup with user mappings, no plain-text passwords
 */
create function index_pilot.setup_connection(
  _host text,
  _port integer default 5432,
  _username text default 'index_pilot',
  _password text default null
) returns text as
$body$
declare
  _setup_result text;
begin
  -- Validate required parameters
  if _host is null then
    raise exception 'Host parameter is required for FDW connection setup';
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
    raise exception using
      message = format(
        'FDW connection test failed for %s@%s:%s',
        _username, _host, _port
      ),
      hint = 'Verify network connectivity and credentials.';
  end;
end;
$body$
language plpgsql;


/*
 * Complete FDW setup with step-by-step progress reporting
 * Orchestrates full secure FDW configuration with detailed progress feedback
 */
create function index_pilot.setup_fdw_complete(
  _password text,
  _host text default 'localhost',
  _port integer default null,
  _username text default null
) returns table(
  step text,
  result text
) as
$body$
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
    
  -- Step 3: Test connection
  begin
    perform dblink_connect_u('test_setup', 'index_pilot_self');
    perform dblink_disconnect('test_setup');
    return query 
    select 
      'Connection Test'::text, 
      'SUCCESS: FDW connection working'::text;
  exception when others then
    return query 
    select 
      'Connection Test'::text, 
      format('FAILED: %s', SQLERRM)::text;
  end;
    
  -- Step 4: Security validation
  return query 
  select 
    'Security Check'::text,
    case when (
      exists (select from pg_extension where extname = 'postgres_fdw') and
      has_foreign_data_wrapper_privilege(current_user, 'postgres_fdw', 'usage') and
      exists (select from pg_foreign_server where srvname = 'index_pilot_self') and
      exists (
        select from pg_user_mappings 
        where srvname = 'index_pilot_self' and usename = current_user
      )
    ) then 'SECURE: All components configured correctly'
      else 'WARNING: Some security components may be missing' end::text;
end;
$body$
language plpgsql;


/*
 * Quick FDW configuration status check
 * Simplified status check of core FDW components with setup commands
 */
create or replace function index_pilot.check_fdw_status() returns table(
  component text,
  status text,
  details text
) as
$body$
begin
  -- Check postgres_fdw extension
  return query select 
    'postgres_fdw extension'::text,
    case when exists (select from pg_extension where extname = 'postgres_fdw') 
      then 'OK' else 'MISSING' end::text,
    case when exists (select from pg_extension where extname = 'postgres_fdw') 
      then 'Extension is installed' 
      else 'Run: create extension postgres_fdw;' end::text;
    
  -- Check foreign server
  return query select 
    'Foreign server'::text,
    case when exists (select from pg_foreign_server where srvname = 'index_pilot_self') 
      then 'OK' else 'MISSING' end::text,
    case when exists (select from pg_foreign_server where srvname = 'index_pilot_self') 
      then 'Server index_pilot_self exists'
      else 'Run: select index_pilot.setup_fdw_self_connection();' end::text;
    
  -- Check user mapping
  return query select 
    'User mapping'::text,
    case when exists (
      select from pg_user_mappings 
      where srvname = 'index_pilot_self' and usename = current_user
    ) 
      then 'OK' else 'MISSING' end::text,
    case when exists (
      select from pg_user_mappings 
      where srvname = 'index_pilot_self' and usename = current_user
    ) 
      then format('Mapping exists for user %s', current_user)
      else format('Run: select index_pilot.setup_user_mapping(''%s'', ''your_password'');', current_user) end::text;
end;
$body$
language plpgsql;

commit;
