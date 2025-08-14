-- pg_index_pilot Uninstall Script
-- This script completely removes pg_index_pilot from your database
-- WARNING: This will delete all collected statistics and history!

-- 1. Drop the schema cascade (this removes all objects)
drop schema if exists index_pilot cascade;

-- 2. Drop the FDW server and user mappings if they exist
drop server if exists index_pilot_self cascade;

-- 3. Clean up any leftover invalid indexes from failed reindexes
-- Generate commands to drop _ccnew* indexes (run these manually)
do $$
declare
    r record;
begin
    for r in 
        select n.nspname, i.relname 
        from pg_index idx
        join pg_class i on i.oid = idx.indexrelid
        join pg_namespace n on n.oid = i.relnamespace
        where i.relname ~ '_ccnew[0-9]*$'
        and not idx.indisvalid
    loop
        raise notice 'Run manually: drop index concurrently if exists %.%;', r.nspname, r.relname;
    end loop;
end $$;

-- Note: postgres_fdw extension is not removed as it may be used by other applications
-- If you want to remove it and it's not used elsewhere, run:
-- drop extension postgres_fdw cascade;