# pg_index_pilot – autonomous index lifecycle management for Postgres

The purpose of pg_index_pilot is to provide all tools needed to manage indexes in Postgres in most automated fashion.

ROADMAP: Areas of index management (checkboxes show what's already implemented):
1. [ ] Automated reindexing
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
2. [ ] Index cleanup
    1. [ ] Unused indexes
    2. [ ] Redundant indexes
    3. [ ] Invalid indexes (or, per configuration, rebuilding them)
    4. [ ] Suboptimal / rarely used indexes cleanup/reorg
3. [ ] Automated index management
    1. [ ] Index recommendations (missing, )
    2. [ ] Index optimization according to configured goals (latency / WAL / size)
    3. [ ] Experimentation (hypothetical with HypoPG, real with DBLab)

## Automated reindexing

The framework of reindexing is implemented entirely inside Postgres, using:
- PL/pgSQL functions and stored procedures with transaction control (PG11+)
- [dblink](https://www.postgresql.org/docs/current/contrib-dblink-function.html) to execute `REINDEX CONCURRENTLY` (PG12+) – because it cannot be inside a transaction block)
- widely available [pg_cron](https://github.com/citusdata/pg_cron) for scheduling

## Supported Postgres versions

PG13+ – all current Postgres versions are supported.

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

Cons:
- initial rebuild is required (TODO: implement import of baseline values from a fully reindexed clone)
- method accuracy might be affected by a "size drift" – in case of significant change of avg. size of indexed values

---

pg_index_watch

Utility for automatical rebuild of bloated indexes (a-la smart autovacuum to deal with index bloat) in PostgreSQL.

## Program purpose
Uncontrollable index bloat on frequently updated tables is a known issue in PostgreSQL.
The built-in autovacuum doesn’t deal well with bloat regardless of its settings. 
pg_index_watch resolves this issue by automatically rebuilding indexes when needed. 

## Where to get support
create github issue
or email maxim.boguk@dataegret.com
or write in telegram channel https://t.me/pg_index_watch_support


## Concept
With the introduction of REINDEX CONCURRENTLY in PostgreSQL 12 there is now a safe and (almost) lock-free way to rebuild bloated indexes.
Despite that, the question remaines - based on which criteria do we determine a bloat and whether there is a need to rebuild the index.
The pg_index_watch utilizes the ratio between index size and pg_class.reltuples (which is kept up-to-date with help of autovacuum/autoanalyze) to determine the extent of index bloat relative to the ideal situation of the newly built index.
It also allows rebuilding bloated indexes of any type without dependency on pgstattuple for estimating index bloat.

pg_index_watch offers following approach to this problem:

PostgreSQL allows you to access (and almost free of charge):
1) number of rows in the index (in pg_class.reltuples for the index) and 2) index size.

Further on, assuming that the ratio of index size to the number of entries is constant (this is correct in 99.9% of cases), we can speculate that if, compared to its regular state, the ratio has doubled is is most certainly that the index have bloated 2x.

Next, we receive a similar to autovacuum system that automatically tracks level of index bloat and rebuilds (via REINDEX CONCURRENTLY) them as needed.


## Basic requirements for installation and usage:
    • PostgreSQL version 12.0 or higher
    • Superuser access to the database with the possibility writing cron from the current user 
        ◦ psql access is sufficient
        ◦ Root or sudo to PostgreSQL isn’t required
    • Possibility of passwordless or ~/.pgpass access on behalf of superuser to all local databases
    (i.e. you should be able to run psql -U postgres -d datname without entering the password.)

## Recommendations 
    • If server resources allow set non-zero max_parallel_maintenance_workers (exact amount depends on server parameters).
    • To set wal_keep_segments to at least 5000, unless the wal archive is used to support streaming replication.

## Installation (as PostgreSQL user)

# get the code git clone
```
git clone https://github.com/dataegret/pg_index_watch
cd pg_index_watch
#create tables’ structure
psql -1 -d postgres -f index_watch_tables.sql
#importing the code (stored procedures)
psql -1 -d postgres -f index_watch_functions.sql
```

## The initial launch

IMPORTANT!!! During the FIRST (and ONLY FIRST) launch ALL!! the indexes that are bigger than 10MB (default setting) will be rebuilt.  
This process might take several hours (or even days).
On the large databases (sized several TB) I suggest performing the FIRST launch manually. 
After that, only bloated indexes will be processed.

```
nohup psql -d postgres -qt -c "CALL index_watch.periodic(TRUE);" >> index_watch.log
```


## Automated work following the installation
Set up the cron daily, for example at midnight (from superuser of the database = normally postgres) or hourly if there is a high number of writes to a database. 

IMPORTANT!!! It’s highly advisable to make sure that the time doesn’t coincide with pg_dump and other long maintenance tasks.

```
00 00 * * *   psql -d postgres -AtqXc "select not pg_is_in_recovery();" | grep -qx t || exit; psql -d postgres -qt -c "CALL index_watch.periodic(TRUE);"
```

## UPDATE to new versions (from a postgres user)
```
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

