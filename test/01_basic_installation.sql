-- Test 01: Basic Installation Verification
-- Exit on first error for CI
\set ON_ERROR_STOP on
\set QUIET on

-- Test output formatting
\echo '======================================'
\echo 'TEST 01: Basic Installation'
\echo '======================================'

-- 1. Verify schema exists
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'index_pilot') THEN
        RAISE EXCEPTION 'FAIL: index_pilot schema not found';
    END IF;
    RAISE NOTICE 'PASS: Schema index_pilot exists';
END $$;

-- 2. Verify version function
DO $$
DECLARE
    _version TEXT;
BEGIN
    SELECT index_pilot.version() INTO _version;
    IF _version IS NULL OR _version = '' THEN
        RAISE EXCEPTION 'FAIL: Version function returned empty';
    END IF;
    RAISE NOTICE 'PASS: Version function works (%))', _version;
END $$;

-- 3. Verify required tables exist
DO $$
DECLARE
    _table_count INTEGER;
    _expected_tables TEXT[] := ARRAY[
        'config',
        'index_current_state', 
        'reindex_history',
        'current_processed_index',
        'tables_version'
    ];
    _table TEXT;
BEGIN
    FOREACH _table IN ARRAY _expected_tables LOOP
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.tables 
            WHERE table_schema = 'index_pilot' 
            AND table_name = _table
        ) THEN
            RAISE EXCEPTION 'FAIL: Required table index_pilot.% not found', _table;
        END IF;
    END LOOP;
    RAISE NOTICE 'PASS: All required tables exist';
END $$;

-- 4. Verify core functions exist
DO $$
DECLARE
    _functions TEXT[] := ARRAY[
        'periodic',
        'do_reindex',
        'get_index_bloat_estimates',
        'check_permissions'
    ];
    _func TEXT;
BEGIN
    FOREACH _func IN ARRAY _functions LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_proc p
            JOIN pg_namespace n ON p.pronamespace = n.oid
            WHERE n.nspname = 'index_pilot' 
            AND p.proname = _func
        ) THEN
            RAISE EXCEPTION 'FAIL: Required function index_pilot.% not found', _func;
        END IF;
    END LOOP;
    RAISE NOTICE 'PASS: All core functions exist';
END $$;

-- 5. Verify permissions check runs
DO $$
DECLARE
    _count INTEGER;
BEGIN
    SELECT COUNT(*) INTO _count FROM index_pilot.check_permissions();
    IF _count < 1 THEN
        RAISE EXCEPTION 'FAIL: check_permissions returned no results';
    END IF;
    RAISE NOTICE 'PASS: Permissions check returns % items', _count;
END $$;

-- 6. Verify default configuration
DO $$
DECLARE
    _config_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO _config_count FROM index_pilot.config;
    IF _config_count < 4 THEN
        RAISE EXCEPTION 'FAIL: Missing default configuration (found % entries)', _config_count;
    END IF;
    RAISE NOTICE 'PASS: Default configuration present (% entries)', _config_count;
END $$;

\echo 'TEST 01: PASSED'
\echo ''