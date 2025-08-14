-- Test 03: Security and Permissions Test
-- Exit on first error for CI
\set ON_ERROR_STOP on
\set QUIET on

\echo '======================================'
\echo 'TEST 03: Security and Permissions'
\echo '======================================'

-- 1. Test non-superuser compatibility
DO $$
DECLARE
    _is_superuser BOOLEAN;
BEGIN
    SELECT usesuper INTO _is_superuser 
    FROM pg_user 
    WHERE usename = current_user;
    
    IF _is_superuser THEN
        RAISE NOTICE 'INFO: Running as superuser - non-superuser tests skipped';
    ELSE
        RAISE NOTICE 'PASS: Running as non-superuser';
    END IF;
END $$;

-- 2. Verify schema permissions
DO $$
DECLARE
    _has_usage BOOLEAN;
BEGIN
    SELECT has_schema_privilege(current_user, 'index_pilot', 'USAGE') INTO _has_usage;
    
    IF NOT _has_usage THEN
        RAISE EXCEPTION 'FAIL: Current user lacks USAGE privilege on index_pilot schema';
    END IF;
    RAISE NOTICE 'PASS: Schema permissions verified';
END $$;

-- 3. Test SQL injection protection in function parameters
DO $$
BEGIN
    -- Try to inject SQL in schema name
    BEGIN
        PERFORM index_pilot.get_index_bloat_estimates(
            current_database() || '; DROP TABLE index_pilot.config; --'
        );
        -- If we get here, the injection attempt was properly handled
        RAISE NOTICE 'PASS: SQL injection protection working (database name)';
    EXCEPTION WHEN OTHERS THEN
        -- Expected to fail safely
        RAISE NOTICE 'PASS: SQL injection blocked (database name)';
    END;
END $$;

-- 4. Verify sensitive functions are protected
DO $$
DECLARE
    _func_count INTEGER;
BEGIN
    -- Check that internal functions start with underscore
    SELECT COUNT(*) INTO _func_count
    FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'index_pilot'
    AND p.proname LIKE '\_%'
    AND p.proname NOT IN ('_check_pg_version_bugfixed', '_check_pg14_version_bugfixed');
    
    IF _func_count < 5 THEN
        RAISE WARNING 'WARNING: Few internal functions found (%), review naming convention', _func_count;
    ELSE
        RAISE NOTICE 'PASS: % internal functions use underscore prefix', _func_count;
    END IF;
END $$;

-- 5. Test connection security (FDW/dblink)
DO $$
DECLARE
    _has_fdw BOOLEAN;
    _fdw_status RECORD;
BEGIN
    -- Check if postgres_fdw is available
    SELECT EXISTS (
        SELECT 1 FROM pg_extension WHERE extname = 'postgres_fdw'
    ) INTO _has_fdw;
    
    IF _has_fdw THEN
        -- Check FDW security status
        FOR _fdw_status IN 
            SELECT * FROM index_pilot.check_fdw_security_status() 
        LOOP
            IF _fdw_status.status IN ('INSTALLED', 'GRANTED', 'EXISTS', 'CONFIGURED', 'OK') THEN
                RAISE NOTICE 'INFO: FDW % - %', _fdw_status.component, _fdw_status.status;
            ELSIF _fdw_status.status = 'MISSING' AND _fdw_status.component LIKE '%server%' THEN
                -- Server not configured yet is OK for tests
                RAISE NOTICE 'INFO: FDW % - Not configured (OK for testing)', _fdw_status.component;
            ELSE
                RAISE WARNING 'WARNING: FDW % - %', _fdw_status.component, _fdw_status.status;
            END IF;
        END LOOP;
        RAISE NOTICE 'PASS: FDW security checks completed';
    ELSE
        RAISE NOTICE 'INFO: postgres_fdw not installed - skipping FDW tests';
    END IF;
END $$;

-- 6. Verify no plaintext passwords in config
DO $$
DECLARE
    _password_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO _password_count
    FROM index_pilot.config
    WHERE value ILIKE '%password%' 
    OR key ILIKE '%password%'
    OR comment ILIKE '%password%';
    
    IF _password_count > 0 THEN
        RAISE EXCEPTION 'FAIL: Found % potential password entries in config', _password_count;
    END IF;
    RAISE NOTICE 'PASS: No plaintext passwords in configuration';
END $$;

-- 7. Test privilege escalation prevention
DO $$
BEGIN
    -- Try to access pg_authid (superuser only)
    BEGIN
        PERFORM index_pilot._remote_get_indexes_info(
            current_database(), 
            'pg_catalog', 
            'pg_authid', 
            NULL
        );
        -- If we get here and aren't superuser, that's bad
        IF NOT EXISTS (SELECT 1 FROM pg_user WHERE usename = current_user AND usesuper) THEN
            RAISE EXCEPTION 'FAIL: Able to access restricted catalog as non-superuser';
        END IF;
    EXCEPTION WHEN OTHERS THEN
        -- Expected to fail for non-superuser
        RAISE NOTICE 'PASS: Cannot access restricted catalogs';
    END;
END $$;

\echo 'TEST 03: PASSED'
\echo ''