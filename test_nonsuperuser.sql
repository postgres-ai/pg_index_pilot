-- Test non-superuser version on RDS

-- 1. Clean install
\echo 'Installing pg_index_pilot...'
DROP SCHEMA IF EXISTS index_watch CASCADE;

\i index_watch_tables.sql
\i index_watch_functions.sql

-- 2. Check permissions
\echo ''
\echo 'Permission check:'
SELECT * FROM index_watch.check_permissions();

-- 3. Create test table
\echo ''
\echo 'Creating test data...'
DROP TABLE IF EXISTS test_nonsuperuser CASCADE;
CREATE TABLE test_nonsuperuser (
    id serial PRIMARY KEY,
    data text,
    created_at timestamp DEFAULT now()
);

CREATE INDEX idx_test_created ON test_nonsuperuser(created_at);
CREATE INDEX idx_test_data ON test_nonsuperuser(data);

-- Insert data
INSERT INTO test_nonsuperuser (data)
SELECT 'Test data ' || i
FROM generate_series(1, 10000) i;

ANALYZE test_nonsuperuser;

-- 4. Run initial scan (no reindex)
\echo ''
\echo 'Running initial scan...'
CALL index_watch.periodic(false);

-- 5. Check current state
\echo ''
\echo 'Current index state:'
SELECT
    relname as table_name,
    indexrelname as index_name,
    pg_size_pretty(indexsize) as size,
    estimated_tuples
FROM index_watch.index_current_state
WHERE relname = 'test_nonsuperuser'
ORDER BY indexrelname;

-- 6. Force populate baseline
\echo ''
\echo 'Force populating baseline...'
SELECT index_watch.do_force_populate_index_stats(
    current_database(),
    'public',
    'test_nonsuperuser',
    NULL
);

-- 7. Create some bloat
\echo ''
\echo 'Creating bloat...'
DELETE FROM test_nonsuperuser WHERE id % 3 = 0;
UPDATE test_nonsuperuser SET data = data || ' updated' WHERE id % 5 = 0;
VACUUM test_nonsuperuser;
ANALYZE test_nonsuperuser;

-- 8. Check bloat estimates
\echo ''
\echo 'Bloat estimates:'
SELECT
    relname as table_name,
    indexrelname as index_name,
    pg_size_pretty(indexsize) as size,
    round(estimated_bloat::numeric, 2) as bloat_factor
FROM index_watch.get_index_bloat_estimates(current_database())
WHERE relname = 'test_nonsuperuser'
ORDER BY indexrelname;

-- 9. Test reindex (force on one index)
\echo ''
\echo 'Testing REINDEX on idx_test_created...'
CALL index_watch.do_reindex(
    current_database(),
    'public',
    'test_nonsuperuser',
    'idx_test_created',
    true  -- force
);

-- 10. Check history
\echo ''
\echo 'Reindex history:'
SELECT * FROM index_watch.history
WHERE "table" = 'test_nonsuperuser'
ORDER BY ts DESC;

\echo ''
\echo 'Test completed!'