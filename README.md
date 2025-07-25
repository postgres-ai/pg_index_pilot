# pg_index_pilot – autonomous index lifecycle management for Postgres

The purpose of `pg_index_pilot` is to provide all tools needed to manage indexes in Postgres in most automated fashion.

This project is in its very early stage. We start with most boring yet extremely important task task: automatic reindexing ("AR") to mitigate index bloat, supporting any types of indexes, and then expand to other areas of index health. And then expand to two other big areas – automated index removal ("AIR") and, finally, automated index creation and optimization ("AIC&O").

## ROADMAP

The Roadmap covers three big areas:

1. [ ] **"AR":** Automated Reindexing
    1. [x] Maxim Boguk's bloat estimation formula – works with *any* type of index, not only btree
        1. [x] original implementation (`pg_index_watch`) – requires initial full reindex
        2. [ ] superuser-less mode
        2. [ ] flexible connection management for dblink
        4. [ ] API for stats obtained on a clone (to avoid full reindex on prod primary)
    2. [ ] Traditional bloat estimatation (ioguix; btree only)
    3. [ ] Exact bloat analysis (pgstattuple; analysis on clones)
    4. [x] Tested on managed services
        - [ ] RDS and Aurora (see [RDS Setup](#rds-setup) below)
        - [ ] CloudSQL
        - [ ] Supabase
        - [ ] Crunchy Bridge
        - [ ] Azure
    5. [ ] Integration with postgres_ai monitoring
    6. [ ] Schedule recommendations
    7. [ ] Parallelization and throttling (adaptive)
2. [ ] **"AIR":** Automated Index Removal
    1. [ ] Unused indexes
    2. [ ] Redundant indexes
    3. [ ] Invalid indexes (or, per configuration, rebuilding them)
    4. [ ] Suboptimal / rarely used indexes cleanup/reorg
3. [ ] **"AIC&O":** Automated Index Creation & Optimization
    1. [ ] Index recommendations (including multi-column, expression, partial, hybrid, and covering indexes)
    2. [ ] Index optimization according to configured goals (latency, size, WAL, write/HOT overhead, read overhead)
    3. [ ] Experimentation (hypothetical with HypoPG, real with DBLab)

## Automated reindexing

The framework of reindexing is implemented entirely inside Postgres, using:
- PL/pgSQL functions and stored procedures with transaction control (PG11+)
- [dblink](https://www.postgresql.org/docs/current/contrib-dblink-function.html) to execute `REINDEX CONCURRENTLY` (PG12+) – because it cannot be inside a transaction block)
- widely available [pg_cron](https://github.com/citusdata/pg_cron) for scheduling

## Supported Postgres versions

Postgres 12 or newer.

### Maxim Boguk's formula

Traditional index bloat estimation ([ioguix](https://github.com//pgsql-bloat-estimation/tree/master/btree)) is widely used but has certain limitations:
- only btree indexes are supported (GIN, GiST, hash, HNSW and others are not supported at all)
- it can be quite off in certain cases
- [the non-superuser version](https://github.com/ioguix/pgsql-bloat-estimation/blob/master/btree/btree_bloat.sql) inspects "only index on tables you are granted to read" (requires additional permissions), and in this case it is slow (~1000x slower than [the superuser version](https://github.com/ioguix/pgsql-bloat-estimation/blob/master/btree/btree_bloat-superuser.sql))
- due to its speed, can be challenging to use in database with huge number of indexes.

An alternative approach was deveoped by Maxim Boguk. It relies on the ratio between index size and `pg_class.reltuples` – Boguk's formula:
```
bloat indicator = index size / pg_class.reltuples
```

This method is extremely lightweight:
- Index size is always easily available via `pg_indexes_size(indexrelid)`
- `pg_class.reltuples` is also immedialy available and maintained up-to-date by autovacuum/autoanalyze

Boguk's bloat indicator is not measured in bytes or per cents. It is to be used in relative scenario: first, we measure the "ideal" value – the value of freshly built index. And then, we observe how the value changes over time – if it significantly bigger than the "ideal" one, it is time to reindex.

This defines pros and cons of this method.

Pros:
- any type of index is supported
- very lightweight analysis
- better precision than the traditional bloat estimate method for static-width columns (e.g., indexes on `bigint` or `timestamptz` columns), without the need to involve expensive `pgstattuple` scans

Cons:
- initial rebuild is required (TODO: implement import of baseline values from a fully reindexed clone)
- for VARLENA data types (`text`, `jsonb`, etc), the method's accuracy might be affected by a "avg size drift" – in case of significant change of avg. size of indexed values, the baseline can silently shift, leading to false positive or false negative results in decision to reindex; however for large tables/indexes, the chances of this are very low

---

=== pg_index_watch original README (polished) ===


## Requirements
- PostgreSQL version 12.0 or higher
- Superuser access to the database
- Passwordless or `~/.pgpass` access for the superuser to all local databases
- `pg_cron` extension for scheduling (optional and recommended)

## Recommendations 
- If server resources allow set non-zero `max_parallel_maintenance_workers` (exact amount depends on server parameters).
- To set `wal_keep_segments` to at least `5000`, unless the WAL archive is used to support streaming replication.

## Installation (as PostgreSQL user)

```bash
# Clone the repository
git clone https://github.com/dataegret/pg_index_pilot
cd pg_index_pilot

# Create schema and tables
psql -1 -d postgres -f index_pilot_tables.sql

# Load stored procedures
psql -1 -d postgres -f index_pilot_functions.sql
```

## Initial launch

**⚠️ IMPORTANT:** During the first run, all indexes larger than index_size_threshold (default: 10MB) will be analyzed and potentially rebuilt. This process may take hours or days on large databases.

For manual initial run:
```bash
nohup psql -d postgres -qXt -c "call index_watch.periodic(true)" >> index_watch.log 2>&1
```

## Scheduling automated maintenance

Configure automated reindexing through cron. The example below runs daily at midnight:
```cron
# Runs reindexing only on primary
00 00 * * *   psql -d postgres -AtqXc "select not pg_is_in_recovery()" | grep -qx t || exit; psql -d postgres -qt -c "call index_watch.periodic(true);"
```

**💡 Best Practices:**
- Schedule during low-traffic periods
- Avoid overlapping with backup or other IO-intensive operations
- Consider hourly runs for high-write workloads
- Monitor resource usage during initial runs (first of all, both disk IO and CPU usage)

## Updating pg_index_pilot

To update to the latest version:
```bash
cd pg_index_pilot
git pull

# Reload the updated functions
psql -1 -d postgres -f index_pilot_functions.sql
```

The table structure updates automatically during the next index_watch.periodic() run. To manually update the structure (normally, this is not required):
```sql
select index_watch.check_update_structure_version();
```

## Monitoring and Analysis

### View Reindexing History
```sql
-- Show recent reindexing operations
select * from index_watch.history 
order by created_at desc 
limit 20;
```

### Check Current Bloat Status
```sql
-- Replace 'mydb' with your database name
select * 
from index_watch.get_index_bloat_estimates('mydb') 
order by estimated_bloat desc nulls last 
limit 40;
```

## Function Reference

### Core Functions

#### `index_watch.version()`
Returns the installed pg_index_watch version.
```sql
select index_watch.version();
```

#### `index_watch.check_update_structure_version()`
Updates the index_watch table structure to the current version.
```sql
select index_watch.check_update_structure_version();
```

### Configuration Management

#### `index_watch.get_setting()`
Retrieves configuration values for specific database objects.
```sql
function index_watch.get_setting(
    _datname text,      -- Database name
    _schemaname text,   -- Schema name
    _relname text,      -- Table name
    _indexrelname text, -- Index name
    _key text          -- Setting key
) returns text
```

#### `index_watch.set_or_replace_setting()`
Sets or updates configuration values.
```sql
function index_watch.set_or_replace_setting(
    _datname text,      -- Database name
    _schemaname text,   -- Schema name
    _relname text,      -- Table name
    _indexrelname text, -- Index name
    _key text,         -- Setting key
    _value text,       -- Setting value
    _comment text      -- Optional comment
) returns void
```

### Bloat Analysis

#### `index_watch.get_index_bloat_estimates()`
Returns current bloat estimates for all indexes in a database.
```sql
function index_watch.get_index_bloat_estimates(_datname name) 
returns table(
    datname name, 
    schemaname name, 
    relname name, 
    indexrelname name, 
    indexsize bigint, 
    estimated_bloat real
)
```

### Manual Operations

#### `index_watch.do_force_populate_index_stats()`
Forcefully populates the baseline ratio for a specific index without reindexing. Useful after:
- Creating new indexes
- Restoring from backups
- Bulk data operations
```sql
function index_watch.do_force_populate_index_stats(
    _datname name, 
    _schemaname name, 
    _relname name, 
    _indexrelname name
) returns void
```

#### `index_watch.do_reindex()`
Manually triggers reindexing for specific objects.
```sql
procedure index_watch.do_reindex(
    _datname name, 
    _schemaname name, 
    _relname name, 
    _indexrelname name, 
    _force boolean default false  -- Force reindex regardless of bloat
)
```

### Automated Maintenance

#### `index_watch.periodic()`
Main procedure for automated bloat detection and reindexing across all databases.
```sql
procedure index_watch.periodic(
    real_run boolean default false,  -- Execute actual reindexing
    force boolean default false,     -- Force all eligible indexes
    single_db boolean default null   -- Force single database mode (for RDS)
)
```

## RDS Setup

pg_index_pilot now supports AWS RDS with some limitations due to RDS's managed environment. RDS mode automatically handles the differences in permissions and access.

### Prerequisites for RDS

1. RDS PostgreSQL 12.0 or higher
2. `dblink` extension installed
3. `pg_cron` extension (optional, for scheduling)
4. User with index ownership or appropriate permissions

### Installation on RDS

```bash
# 1. Create the extension structures
psql -d your_database -f index_watch_tables.sql
psql -d your_database -f index_watch_functions.sql
psql -d your_database -f index_watch_rds.sql

# 2. Configure for RDS mode
psql -d your_database -c "SELECT index_watch.install_rds_mode();"
```

### Single Database Operation (Recommended for RDS)

For most RDS use cases, monitoring a single database is sufficient:

```sql
-- Manual run for current database only
CALL index_watch.periodic(true, false, true);

-- Schedule with pg_cron (if available)
SELECT index_watch.setup_rds_cron('0 2 * * *', true);
```

### Multi-Database Operation on RDS

If you need to monitor multiple databases on the same RDS instance:

```sql
-- Configure additional databases
SELECT index_watch.setup_rds_dblink(
    'database2',
    'your-instance.region.rds.amazonaws.com',
    5432,
    'your_username',
    'your_password'
);

-- Check status
SELECT * FROM index_watch.monitored_databases;

-- Run across all configured databases
CALL index_watch.periodic(true, false, false);
```

### RDS-Specific Functions

#### Check RDS Status
```sql
SELECT * FROM index_watch.rds_status();
```

#### Verify Permissions
```sql
SELECT * FROM index_watch.check_rds_permissions();
```

### RDS Limitations and Differences

1. **No Cross-Database Discovery**: You must explicitly configure databases to monitor
2. **No Toast Table Processing**: Limited access to pg_toast schema
3. **Single Database Mode Default**: Recommended mode for RDS
4. **Connection Management**: Uses explicit connection strings instead of local connections
5. **No Superuser Access**: Works within RDS permission model

### Monitoring on RDS

```sql
-- View recent reindexing operations
SELECT * FROM index_watch.history 
ORDER BY ts DESC 
LIMIT 20;

-- Check bloat estimates for current database
SELECT * FROM index_watch.get_index_bloat_estimates(current_database()) 
ORDER BY estimated_bloat DESC NULLS LAST 
LIMIT 20;

-- Check monitored databases status (multi-db mode)
SELECT datname, enabled, last_check, last_error 
FROM index_watch.monitored_databases;
```