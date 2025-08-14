-- Setup script for creating index_pilot user
-- This script should be run by a database administrator or user with appropriate privileges
\set ON_ERROR_STOP

-- Check PostgreSQL version
do $$
begin
  if (select setting from pg_settings where name='server_version_num') < '12'
  then
    raise 'This library works only for PostgreSQL 12 or higher!';
  end if;
end; $$;

-- Create dedicated user for index_pilot system
-- Note: On managed services, the master user should run this script
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'index_pilot') then
    create role index_pilot with login;
    raise notice 'Created role index_pilot';
  else
    raise notice 'Role index_pilot already exists';
  end if;
end $$;

-- Set a random password for the index_pilot user
-- In production, you should set a secure password
alter role index_pilot password 'changeme_secure_password_here';

-- Grant necessary permissions for index_pilot user
-- Database-level permissions
do $$
begin
  execute format('grant connect on database %I to index_pilot', current_database());
  execute format('grant create on database %I to index_pilot', current_database());
end $$;

-- Schema permissions - grant usage on existing schemas
do $$
declare
  _schema_name text;
begin
  for _schema_name in 
    select schema_name 
    from information_schema.schemata 
    where schema_name not in ('information_schema', 'pg_catalog', 'pg_toast')
  loop
    execute format('grant usage on schema %I to index_pilot', _schema_name);
    execute format('grant create on schema %I to index_pilot', _schema_name);
    raise notice 'Granted permissions on schema %', _schema_name;
  end loop;
end $$;

-- Grant permissions on existing tables to allow reindexing
do $$
declare
  _table_record record;
begin
  for _table_record in 
    select schemaname, tablename 
    from pg_tables 
    where schemaname not in ('information_schema', 'pg_catalog')
  loop
    execute format('grant select, insert, update, delete, references, trigger on %I.%I to index_pilot', 
                   _table_record.schemaname, _table_record.tablename);
    
    -- Grant permission to reindex
    execute format('alter table %I.%I owner to index_pilot', 
                   _table_record.schemaname, _table_record.tablename);
  end loop;
  
  raise notice 'Granted table permissions and ownership to index_pilot';
end $$;

-- Grant permissions to read system catalogs and statistics
grant select on pg_stat_user_indexes to index_pilot;
grant select on pg_stat_user_tables to index_pilot;
grant select on pg_statio_user_indexes to index_pilot;
grant select on pg_statio_user_tables to index_pilot;

-- Grant permissions needed for dblink and reindexing
do $$
begin
  -- Try to grant pg_stat_file permissions (available on self-hosted, not on managed services)
  begin
    execute 'grant execute on function pg_stat_file(text) to index_pilot';
    execute 'grant execute on function pg_stat_file(text, boolean) to index_pilot';
    raise notice 'Granted pg_stat_file permissions (self-hosted PostgreSQL)';
  exception
    when insufficient_privilege or undefined_function then
      raise notice 'Skipped pg_stat_file permissions (managed service)';
  end;
end $$;

grant execute on function pg_indexes_size(regclass) to index_pilot;
grant execute on function pg_total_relation_size(regclass) to index_pilot;
grant execute on function pg_relation_size(regclass) to index_pilot;
grant execute on function pg_relation_size(regclass, text) to index_pilot;

-- Create extensions needed for index_pilot
create extension if not exists dblink;
create extension if not exists postgres_fdw;

-- Grant usage on extensions
grant usage on foreign data wrapper postgres_fdw to index_pilot;

-- Grant execute permissions for dblink functions
do $$
begin
  -- Try to grant dblink_connect_u permissions (may need explicit grant on some managed services)
  begin
    execute 'grant execute on function dblink_connect_u(text,text) to index_pilot';
    raise notice 'Granted dblink_connect_u permissions';
  exception
    when insufficient_privilege or undefined_function then
      raise notice 'Could not grant dblink_connect_u permissions - may need manual grant';
  end;
end $$;

-- Summary
do $$
begin
  raise notice '';
  raise notice '=== index_pilot User Setup Complete ===';
  raise notice '';
  raise notice 'Next steps:';
  raise notice '1. Update the password for index_pilot user:';
  raise notice '   ALTER ROLE index_pilot PASSWORD ''your_secure_password'';';
  raise notice '';
  raise notice '2. Connect as index_pilot user and install pg_index_pilot:';
  raise notice '   psql -U index_pilot -d % -f install_as_index_pilot.psql', current_database();
  raise notice '';
  raise notice '3. Setup secure FDW connection:';
  raise notice '   psql -U index_pilot -d % -c "SELECT index_watch.setup_fdw_self_connection(''hostname'', 5432, ''%'');"', current_database(), current_database();
  raise notice '   psql -U index_pilot -d % -c "SELECT index_watch.setup_user_mapping(''index_pilot'', ''your_secure_password'');"', current_database();
  raise notice '';
  raise notice '4. Create USER MAPPING for admin (managed services only):';
  raise notice '   psql -U postgres -d % -c "CREATE USER MAPPING FOR postgres SERVER index_pilot_self OPTIONS (user ''index_pilot'', password ''your_secure_password'');"', current_database();
  raise notice '   psql -U postgres -d % -c "CREATE USER MAPPING FOR rds_superuser SERVER index_pilot_self OPTIONS (user ''index_pilot'', password ''your_secure_password'');"', current_database();
  raise notice '';
  raise notice '5. Test the installation:';
  raise notice '   psql -U index_pilot -d % -c "SELECT * FROM index_watch.check_permissions();"', current_database();
  raise notice '';
end $$;