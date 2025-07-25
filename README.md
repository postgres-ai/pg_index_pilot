# pg_index_pilot – autonomous index lifecycle management for Postgres

The purpose of `pg_index_pilot` is to provide all tools needed to manage indexes in Postgres in most automated fashion.

This project is in its very early stage. We start with most boring yet extremely important task task: automatic reindexing ("AR") to mitigate index bloat, supporting any types of indexes, and then expand to other areas of index health. And then expand to two other big areas – automated index removal ("AIR") and, finally, automated index creation and optimization ("AIC&O").

## ROADMAP

The Roadmap covers three big areas:

1. [ ] **"AR":** Automated reindexing
    1. [x] Maxim Boguk's bloat estimation formula – works with *any* type of index, not only btree
        1. [x] original implementation (pg_index_watch) – requires initial full reindex
        2. [ ] superuser-less mode
        3. [ ] API for stats obtained on a clone (to avoid full reindex on prod primary)
    2. [ ] Traditional bloat estimatation (ioguix; btree only)
    3. [ ] Exact bloat analysis (pgstattuple; analysis on clones)
    4. [ ] Tested on managed services
        - [ ] RDS and Aurora
        - [ ] CloudSQL
        - [ ] Supabase
        - [ ] Crunchy Bridge
        - [ ] Azure
    5. [ ] Integration with postgres_ai monitoring
    6. [ ] Schedule recommendations
    7. [ ] Parallelization and throttling (adaptive)
2. [ ] **"AIR":** Automated index removal
    1. [ ] Unused indexes
    2. [ ] Redundant indexes
    3. [ ] Invalid indexes (or, per configuration, rebuilding them)
    4. [ ] Suboptimal / rarely used indexes cleanup/reorg
3. [ ] **"AIC&O":** Automated index creation and optimization
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

=== pg_index_watch README ===


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

**IMPORTANT:** During the first run, all indexes larger than index_size_threshold (default: 10MB) will be analyzed and potentially rebuilt. This process may take hours or days on large databases.

For manual initial run:
```bash
nohup psql -d postgres -qXt -c "call index_watch.periodic(true)" >> index_watch.log 2>&1
```

## Automated work following the installation
Set up the cron daily, for example at midnight (from superuser of the database -- normally, `postgres`) or hourly if there is a high number of writes to a database. 

**RECOMMENDATION:** It’s highly recommended to make sure that reindexing doesn't overlap with IO-intensive, long-running maintenance jobs like `pg_dump`.

Schedule via cron (adjust timing to avoid conflicts with backups and maintenance):


```cron
# runs reindexing only on primary
00 00 * * *   psql -d postgres -AtqXc "select not pg_is_in_recovery()" | grep -qx t || exit; psql -d postgres -qt -c "call index_watch.periodic(true);"
```

## UPDATE to new versions (from a postgres user)
```bash
cd pg_index_watch
git pull
#load updated codebase
psql -1 -d postgres -f index_watch_functions.sql
index_watch table structure update will be performed AUTOMATICALLY (if needed) with the next index_watch.periodic command.
```

However, you can manually update tables structure to the current version (normally, this is not required):

```
psql -1 -d postgres -c "SELECT index_watch.check_update_structure_version()"
```

## Viewing reindexing history (it is renewed during the initial launch and with launch from crons): 
```
psql -1 -d postgres -c "SELECT * FROM index_watch.history LIMIT 20"
```

## review of current bloat status in  
specific database DB_NAME:
Assumes that cron index_watch.periodic WORKS, otherwise data will not be updated.

```
psql -1 -d postgres -c "select * from index_watch.get_index_bloat_estimates('DB_NAME') order by estimated_bloat desc nulls last limit 40;"
```

## list of user callable functions and arguments

### index_watch.version()
FUNCTION index_watch.version() RETURNS TEXT
returns installed pg_index_watch version

### index_watch.check_update_structure_version()
FUNCTION index_watch.check_update_structure_version() RETURNS VOID
update index watch table structure to the current version

### index_watch.get_setting
FUNCTION index_watch.get_setting(_datname text, _schemaname text, _relname text, _indexrelname text, _key TEXT) RETURNS TEXT
returns configuration value for given database, schema, table, index and setting name 

### index_watch.set_or_replace_setting
FUNCTION index_watch.set_or_replace_setting(_datname text, _schemaname text, _relname text, _indexrelname text, _key TEXT, _value text, _comment text) RETURNS VOID
set or replace setting value for given database, schema, table, index and setting name

### index_watch.get_index_bloat_estimates
FUNCTION index_watch.get_index_bloat_estimates(_datname name) RETURNS TABLE(datname name, schemaname name, relname name, indexrelname name, indexsize bigint, estimated_bloat real) 
returns table of current estimated index bloat for given database

### index_watch.do_force_populate_index_stats
FUNCTION index_watch.do_force_populate_index_stats(_datname name, _schemaname name, _relname name, _indexrelname name) RETURNS VOID
forced populate of best index ratio for given database, schema, table, index without mandatory reindexing (useful if new huge index just created and definitely don't have any bloat or after pg_restore and similar cases

### index_watch.do_reindex
PROCEDURE index_watch.do_reindex(_datname name, _schemaname name, _relname name, _indexrelname name, _force BOOLEAN DEFAULT FALSE) 
perform reindex of bloated indexes in given database, schema, table, index (or every suitable indexes with _force=>true)

### index_watch.periodic
PROCEDURE index_watch.periodic(real_run BOOLEAN DEFAULT FALSE, force BOOLEAN DEFAULT FALSE) AS
perform bloat based reindex of every accessible database in cluster


## todo
Add docmentation/howto about working with advanced settings and custom configuration of utility.
Add support of watching remote databases.
Add better commentaries to code.

## future plans
 - implement reindex strategy based on bloat estimation query https://github.com/ioguix/pgsql-bloat-estimation
 - implement reindex strategy based on bloat calculation made by pgstattuple

