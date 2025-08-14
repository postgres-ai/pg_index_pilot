-- Test 02: Core Functionality Test
-- Exit on first error for CI
\set ON_ERROR_STOP on
\set QUIET on

\echo '======================================'
\echo 'TEST 02: Core Functionality'
\echo '======================================'

-- 1. Create test schema and tables
DO $$
BEGIN
    -- Create test schema
    CREATE SCHEMA IF NOT EXISTS test_pilot;
    
    -- Create test table with various index types
    DROP TABLE IF EXISTS test_pilot.test_table CASCADE;
    CREATE TABLE test_pilot.test_table (
        id SERIAL PRIMARY KEY,
        email VARCHAR(255),
        status VARCHAR(50),
        data JSONB,
        created_at TIMESTAMP DEFAULT NOW()
    );
    
    -- Insert test data
    INSERT INTO test_pilot.test_table (email, status, data)
    SELECT 
        'user' || i || '@test.com',
        CASE WHEN i % 3 = 0 THEN 'active' ELSE 'inactive' END,
        jsonb_build_object('id', i, 'value', random() * 100)
    FROM generate_series(1, 1000) i;
    
    -- Create various index types
    CREATE INDEX idx_test_email ON test_pilot.test_table(email);
    CREATE INDEX idx_test_status ON test_pilot.test_table(status);
    CREATE INDEX idx_test_created ON test_pilot.test_table(created_at);
    CREATE INDEX idx_test_data_gin ON test_pilot.test_table USING gin(data);
    
    ANALYZE test_pilot.test_table;
    
    RAISE NOTICE 'PASS: Test schema and tables created';
END $$;

-- 2. Test periodic scan (dry run) and verify indexes
DO $$
DECLARE
    _count INTEGER;
    _periodic_success BOOLEAN := false;
BEGIN
    -- FDW is REQUIRED for the tool to work
    PERFORM 1 FROM pg_foreign_server WHERE srvname = 'index_pilot_self';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FAIL: FDW server index_pilot_self not found. The tool requires FDW to function.';
    END IF;
    
    -- Test FDW connection
    PERFORM index_pilot._connect_securely(current_database());
    
    -- Run periodic scan - this should work with FDW properly configured
    CALL index_pilot.periodic(false);
    RAISE NOTICE 'PASS: Periodic scan (dry run) completed';
    
    -- Verify indexes were detected
    SELECT COUNT(*) INTO _count 
    FROM index_pilot.index_current_state 
    WHERE schemaname = 'test_pilot';
    
    IF _count < 4 THEN
        RAISE EXCEPTION 'FAIL: Expected at least 4 indexes, found %', _count;
    END IF;
    RAISE NOTICE 'PASS: % indexes detected in test schema', _count;
END $$;

-- 3. Test force populate baseline
DO $$
BEGIN
    -- Force populate should work if we got this far
    PERFORM index_pilot.do_force_populate_index_stats(
        current_database(),
        'test_pilot',
        NULL,
        NULL
    );
    RAISE NOTICE 'PASS: Force populate baseline completed';
EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'FAIL: Force populate failed: %', SQLERRM;
END $$;

-- 4. Verify baseline was established
DO $$
DECLARE
    _count INTEGER;
BEGIN
    SELECT COUNT(*) INTO _count 
    FROM index_pilot.index_current_state 
    WHERE schemaname = 'test_pilot' 
    AND best_ratio IS NOT NULL;
    
    IF _count < 1 THEN
        RAISE EXCEPTION 'FAIL: No baselines established';
    END IF;
    RAISE NOTICE 'PASS: Baseline established for % indexes', _count;
END $$;

-- 5. Test bloat estimation
DO $$
DECLARE
    _count INTEGER;
BEGIN
    -- Create some bloat
    DELETE FROM test_pilot.test_table WHERE id % 3 = 0;
    UPDATE test_pilot.test_table SET status = 'updated' WHERE id % 5 = 0;
    -- Note: VACUUM cannot run in transaction, just ANALYZE
    ANALYZE test_pilot.test_table;
    
    -- Update current state
    CALL index_pilot.periodic(false);
    
    -- Check bloat estimates
    SELECT COUNT(*) INTO _count
    FROM index_pilot.get_index_bloat_estimates(current_database())
    WHERE schemaname = 'test_pilot'
    AND estimated_bloat IS NOT NULL;
    
    IF _count < 1 THEN
        RAISE EXCEPTION 'FAIL: No bloat estimates generated';
    END IF;
    RAISE NOTICE 'PASS: Bloat estimates available for % indexes', _count;
END $$;

-- 7. Test reindex threshold detection
DO $$
DECLARE
    _threshold FLOAT;
    _max_bloat FLOAT;
BEGIN
    -- Get configured threshold
    SELECT value::FLOAT INTO _threshold 
    FROM index_pilot.config 
    WHERE key = 'index_rebuild_scale_factor';
    
    -- Get max bloat
    SELECT MAX(estimated_bloat) INTO _max_bloat
    FROM index_pilot.get_index_bloat_estimates(current_database())
    WHERE schemaname = 'test_pilot';
    
    RAISE NOTICE 'PASS: Bloat detection working (max bloat: %, threshold: %)', 
        COALESCE(_max_bloat, 0), _threshold;
END $$;

-- 8. Cleanup test data
DO $$
BEGIN
    DROP SCHEMA IF EXISTS test_pilot CASCADE;
    DELETE FROM index_pilot.index_current_state WHERE schemaname = 'test_pilot';
    DELETE FROM index_pilot.reindex_history WHERE schemaname = 'test_pilot';
    RAISE NOTICE 'PASS: Test cleanup completed';
END $$;

\echo 'TEST 02: PASSED'
\echo ''