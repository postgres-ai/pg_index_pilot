-- Test 04: In-Progress Reindex Handling
-- Verifies that reindexes in progress show NULL values, not premature completion
-- Exit on first error for CI
\set ON_ERROR_STOP on
\set QUIET on

\echo '======================================'
\echo 'TEST 04: In-Progress Reindex Handling'
\echo '======================================'

-- 1. Create test schema and table with substantial data
do $$
begin
    -- Clean up from any previous test runs
    drop schema if exists test_reindex cascade;
    delete from index_pilot.reindex_history where schemaname = 'test_reindex';
    delete from index_pilot.index_current_state where schemaname = 'test_reindex';
    
    -- Create test schema
    create schema test_reindex;
    
    -- Create table with indexes
    create table test_reindex.test_table (
        id serial primary key,
        data text,
        created_at timestamp default now()
    );
    
    -- Insert data to make indexes non-trivial
    insert into test_reindex.test_table (data)
    select 'test data ' || i 
    from generate_series(1, 10000) i;
    
    -- Create additional indexes
    create index idx_test_data on test_reindex.test_table(data);
    create index idx_test_created on test_reindex.test_table(created_at);
    
    analyze test_reindex.test_table;
    
    raise notice 'PASS: Test schema and data created';
end $$;

-- 2. Manually insert a reindex history record as if reindex just started
do $$
declare
    _indexsize bigint;
begin
    -- Get current index size
    select pg_relation_size('test_reindex.idx_test_data'::regclass) into _indexsize;
    
    -- Insert record with NULL values (as fire-and-forget reindex would)
    insert into index_pilot.reindex_history (
        datname, schemaname, relname, indexrelname,
        indexsize_before, indexsize_after, estimated_tuples, 
        reindex_duration, analyze_duration, entry_timestamp
    ) values (
        current_database(), 'test_reindex', 'test_table', 'idx_test_data',
        _indexsize, NULL, 10000,  -- NULL for in-progress
        NULL, NULL, now()
    );
    
    raise notice 'PASS: In-progress reindex record created with NULL values';
end $$;

-- 3. Verify the history view shows NULL ratio and duration for in-progress
do $$
declare
    _ratio numeric;
    _duration interval;
    _size_after text;
begin
    select ratio, duration, size_after into _ratio, _duration, _size_after
    from index_pilot.history
    where schema = 'test_reindex'
    and index = 'idx_test_data'
    limit 1;
    
    if _ratio is not null then
        raise exception 'FAIL: Ratio should be NULL for in-progress reindex, got %', _ratio;
    end if;
    
    if _duration is not null then
        raise exception 'FAIL: Duration should be NULL for in-progress reindex, got %', _duration;
    end if;
    
    if _size_after is not null then
        raise exception 'FAIL: Size_after should be NULL for in-progress reindex, got %', _size_after;
    end if;
    
    raise notice 'PASS: History view correctly shows NULL values for in-progress reindex';
end $$;

-- 4. Create a _ccnew index to simulate in-progress REINDEX CONCURRENTLY
do $$
begin
    -- Create a fake _ccnew index to simulate in-progress reindex
    create index idx_test_data_ccnew on test_reindex.test_table(data);
    raise notice 'PASS: Created _ccnew index to simulate in-progress REINDEX CONCURRENTLY';
end $$;

-- 5. Run periodic to check it doesn't prematurely update the record
do $$
begin
    -- Run periodic (should NOT update our record since _ccnew index exists)
    call index_pilot.periodic(true);
    raise notice 'PASS: Periodic scan completed';
end $$;

-- 6. Verify record still has NULL values (not prematurely marked complete)
do $$
declare
    _indexsize_after bigint;
    _duration interval;
begin
    select indexsize_after, reindex_duration into _indexsize_after, _duration
    from index_pilot.reindex_history
    where schemaname = 'test_reindex'
    and indexrelname = 'idx_test_data';
    
    if _indexsize_after is not null then
        raise exception 'FAIL: indexsize_after should still be NULL, but was updated to %', _indexsize_after;
    end if;
    
    if _duration is not null then
        raise exception 'FAIL: reindex_duration should still be NULL, but was updated to %', _duration;
    end if;
    
    raise notice 'PASS: Record correctly remains NULL after periodic (no premature completion)';
end $$;

-- 7. Simulate reindex completion by updating the record
do $$
declare
    _new_size bigint;
begin
    -- Get current size (simulating completed reindex)
    select pg_relation_size('test_reindex.idx_test_data'::regclass) into _new_size;
    
    -- Manually complete the record
    update index_pilot.reindex_history
    set indexsize_after = _new_size * 0.8,  -- Simulate 20% size reduction
        reindex_duration = interval '5 minutes'
    where schemaname = 'test_reindex'
    and indexrelname = 'idx_test_data';
    
    raise notice 'PASS: Simulated reindex completion';
end $$;

-- 8. Verify history now shows proper ratio
do $$
declare
    _ratio numeric;
    _duration interval;
begin
    select ratio, duration into _ratio, _duration
    from index_pilot.history
    where schema = 'test_reindex'
    and index = 'idx_test_data';
    
    if _ratio is null then
        raise exception 'FAIL: Ratio should not be NULL after completion';
    end if;
    
    if _ratio < 1.0 then
        raise exception 'FAIL: Ratio should be > 1.0 for size reduction, got %', _ratio;
    end if;
    
    if _duration is null then
        raise exception 'FAIL: Duration should not be NULL after completion';
    end if;
    
    raise notice 'PASS: History correctly shows ratio % and duration % after completion', _ratio, _duration;
end $$;


-- 9. Cleanup
do $$
begin
    drop schema if exists test_reindex cascade;
    delete from index_pilot.reindex_history where schemaname = 'test_reindex';
    delete from index_pilot.index_current_state where schemaname = 'test_reindex';
    raise notice 'PASS: Test cleanup completed';
end $$;

\echo 'TEST 04: PASSED'
\echo ''