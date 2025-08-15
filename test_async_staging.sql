-- Test async REINDEX on staging
-- Run this with: cat test_async_staging.sql | pgais

-- Clear previous test data
DELETE FROM index_pilot.reindex_history WHERE entry_timestamp > now() - interval '1 hour';
DELETE FROM index_pilot.current_processed_index;

-- Show what we're testing
SELECT 'Testing with bot.i_documents_published_at' as status;
SELECT pg_size_pretty(pg_relation_size('bot.i_documents_published_at'::regclass)) as current_size;

-- Call the async reindex procedure
CALL index_pilot.do_reindex(
    current_database(),
    'bot',
    'documents', 
    'i_documents_published_at',
    true  -- force
);

-- Check if it's running
SELECT pid, state, left(query, 80) as query
FROM pg_stat_activity 
WHERE query ILIKE '%reindex%' 
    AND pid != pg_backend_pid();

-- Wait a bit
SELECT pg_sleep(2);

-- Check history
SELECT 
    schemaname,
    indexrelname,
    pg_size_pretty(indexsize_before::bigint) as size_before,
    pg_size_pretty(indexsize_after::bigint) as size_after,
    CASE 
        WHEN indexsize_after IS NULL THEN 'IN PROGRESS'
        ELSE round((indexsize_before::numeric / indexsize_after), 2)::text
    END as ratio,
    coalesce(reindex_duration::text, 'IN PROGRESS') as duration
FROM index_pilot.reindex_history 
WHERE entry_timestamp > now() - interval '10 minutes'
ORDER BY entry_timestamp DESC;

-- Check for _ccnew indexes
SELECT 
    n.nspname as schema,
    c.relname as index_name,
    i.indisvalid as is_valid
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_index i ON i.indexrelid = c.oid
WHERE c.relname ~ 'i_documents_published_at_ccnew';