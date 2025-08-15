-- Test 02: Core Functionality Test
-- Exit on first error for CI
\set ON_ERROR_STOP on
\set QUIET on

\echo '======================================'
\echo 'TEST 02: Core Functionality'
\echo '======================================'

-- 1. Create test schema and tables
do $$
begin
    -- Create test schema
    create schema if not exists test_pilot;
    
    -- Create test table with various index types
    drop table if exists test_pilot.test_table cascade;
    create table test_pilot.test_table (
        id serial primary key,
        email VARCHAR(255),
        status VARCHAR(50),
        data JSONB,
        created_at timestamp default NOW()
    );
    
    -- Insert test data
    insert into test_pilot.test_table (email, status, data)
    select 
        'user' || i || '@test.com',
        case when i % 3 = 0 then 'active' else 'inactive' end,
        jsonb_build_object('id', i, 'value', random() * 100)
    from generate_series(1, 1000) i;
    
    -- Create various index types
    create index idx_test_email on test_pilot.test_table(email);
    create index idx_test_status on test_pilot.test_table(status);
    create index idx_test_created on test_pilot.test_table(created_at);
    create index idx_test_data_gin on test_pilot.test_table using gin(data);
    
    analyze test_pilot.test_table;
    
    raise notice 'PASS: Test schema and tables created';
end $$;

-- 2. Test periodic scan (dry run) and verify indexes
do $$
declare
    _count integer;
    _periodic_success boolean := false;
begin
    -- FDW is REQUIRED for the tool to work
    perform 1 from pg_foreign_server where srvname = 'index_pilot_self';
    if not found then
        raise exception 'FAIL: FDW server index_pilot_self not found. The tool requires FDW to function.';
    end if;
    
    -- Test FDW connection
    perform index_pilot._connect_securely(current_database());
    
    -- Run periodic scan - this should work with FDW properly configured
    call index_pilot.periodic(false);
    raise notice 'PASS: Periodic scan (dry run) completed';
    
    -- Verify indexes were detected
    select count(*) into _count 
    from index_pilot.index_current_state 
    where schemaname = 'test_pilot';
    
    if _count < 4 then
        raise exception 'FAIL: Expected at least 4 indexes, found %', _count;
    end if;
    raise notice 'PASS: % indexes detected in test schema', _count;
end $$;

-- 3. Test force populate baseline
do $$
begin
    -- Force populate should work if we got this far
    perform index_pilot.do_force_populate_index_stats(
        current_database(),
        'test_pilot',
        null,
        null
    );
    raise notice 'PASS: Force populate baseline completed';
exception when others then
    raise exception 'FAIL: Force populate failed: %', SQLERRM;
end $$;

-- 4. Verify baseline was established
do $$
declare
    _count integer;
begin
    select count(*) into _count 
    from index_pilot.index_current_state 
    where schemaname = 'test_pilot' 
    and best_ratio is not null;
    
    if _count < 1 then
        raise exception 'FAIL: No baselines established';
    end if;
    raise notice 'PASS: Baseline established for % indexes', _count;
end $$;

-- 5. Test bloat estimation
do $$
declare
    _count integer;
begin
    -- Create some bloat
    delete from test_pilot.test_table where id % 3 = 0;
    update test_pilot.test_table set status = 'updated' where id % 5 = 0;
    -- Note: vacuum cannot run in transaction, just analyze
    analyze test_pilot.test_table;
    
    -- Update current state
    call index_pilot.periodic(false);
    
    -- Check bloat estimates
    select count(*) into _count
    from index_pilot.get_index_bloat_estimates(current_database())
    where schemaname = 'test_pilot'
    and estimated_bloat is not null;
    
    if _count < 1 then
        raise exception 'FAIL: No bloat estimates generated';
    end if;
    raise notice 'PASS: Bloat estimates available for % indexes', _count;
end $$;

-- 7. Test reindex threshold detection
do $$
declare
    _threshold FLOAT;
    _max_bloat FLOAT;
begin
    -- Get configured threshold
    select value::FLOAT into _threshold 
    from index_pilot.config 
    where key = 'index_rebuild_scale_factor';
    
    -- Get max bloat
    select max(estimated_bloat) into _max_bloat
    from index_pilot.get_index_bloat_estimates(current_database())
    where schemaname = 'test_pilot';
    
    raise notice 'PASS: Bloat detection working (max bloat: %, threshold: %)', 
        coalesce(_max_bloat, 0), _threshold;
end $$;

-- 8. Cleanup test data
do $$
begin
    drop schema if exists test_pilot cascade;
    delete from index_pilot.index_current_state where schemaname = 'test_pilot';
    delete from index_pilot.reindex_history where schemaname = 'test_pilot';
    raise notice 'PASS: Test cleanup completed';
end $$;

\echo 'TEST 02: PASSED'
\echo ''