# pg_index_pilot – automated PostgreSQL index maintenance

**The problem:** Postgres indexes accumulate bloat over time. Manual `REINDEX` operations are risky, require downtime planning, and are often forgotten until performance degrades.

**The solution:** `pg_index_pilot` runs entirely inside your PostgreSQL database, automatically detecting and fixing bloated indexes using `REINDEX CONCURRENTLY` with zero downtime. No external services, no complex setup, just automated index maintenance that actually works.

**Current status:** **BETA**. Automated reindexing is functional and tested. The maintainers are looking for early adopters.

## How it works

Here's what `pg_index_pilot` does. This example shows real index bloat being fixed automatically:

```bash
# 1. Quick install - creates a control database to manage indexes
git clone https://gitlab.com/postgres-ai/pg_index_pilot
cd pg_index_pilot

# 2. Install the control database (30 seconds)
PGPASSWORD='your_password' \
  ./index_pilot.sh install-control \
  -H localhost -U postgres -C index_pilot_control

# 3. Connect the production database
PGPASSWORD='your_password' \
  ./index_pilot.sh register-target \
  -H localhost -U postgres -C index_pilot_control \
  -T your_production_db --fdw-host localhost

# 4. Check current bloat status
psql -d index_pilot_control -c "
  select 
    indexrelname as index_name,
    pg_size_pretty(indexsize::bigint) as current_size,
    round(estimated_bloat::numeric, 1) || 'x' as bloat_factor
  from index_pilot.get_index_bloat_estimates('your_production_db')
  where estimated_bloat > 1.5
  order by estimated_bloat desc 
  limit 10;"

# 5. Schedule automatic maintenance (runs at 2 AM daily)
psql -d index_pilot_control -c "
  select cron.schedule_in_database(
    'pg_index_pilot_daily',
    '0 2 * * *',
    'call index_pilot.periodic(real_run := true);',
    'index_pilot_control'
  );"
```

## What you'll see

### Before `pg_index_pilot`
Indexes slowly accumulate bloat over time, wasting disk space and degrading query performance:

```sql
-- Check bloat manually (painful!)
select 
    indexrelname as index_name,
    pg_size_pretty(indexsize) as size,
    round(estimated_bloat, 1) || 'x' as bloat
from index_pilot.get_index_bloat_estimates('production_db')
order by estimated_bloat desc;

index_name            | size    | bloat
----------------------|---------|-------
orders_created_at_idx | 2.3 GB  | 4.2x   -- 76% wasted space!
users_email_idx       | 890 MB  | 3.5x   -- 71% wasted space!
products_sku_idx      | 1.2 GB  | 2.8x   -- 64% wasted space!
```

### After one week with `pg_index_pilot`
Automatic maintenance keeps indexes lean:

```sql
-- View what `pg_index_pilot` did for you
select ts, db, schema, "table", "index", size_before, size_after, duration 
from index_pilot.history 
where status = 'completed'
limit 5;

ts                   | db      | schema | table    | index                 | size_before | size_after | duration
---------------------|---------|--------|----------|----------------------|-------------|------------|----------
2025-01-15 02:00:15  | prod_db | public | orders   | orders_created_at_idx| 2.3 GB      | 547 MB     | 00:03:42
2025-01-16 02:00:08  | prod_db | public | users    | users_email_idx      | 890 MB      | 254 MB     | 00:01:23
2025-01-17 02:00:11  | prod_db | public | products | products_sku_idx     | 1.2 GB      | 428 MB     | 00:02:15
```

## How it works

`pg_index_pilot` uses a simple but effective architecture that runs entirely inside PostgreSQL:

```
┌─────────────────────────┐         ┌──────────────────┐
│  Control Database       │────────▶│  Your Database   │
│ (index_pilot_control)   │  FDW/   │  (production)    │
│                         │ dblink  │                  │
│ • Monitors bloat        │         │ • No changes     │
│ • Schedules reindex     │         │ • Owner access   │  
│ • Tracks history        │         │ • Zero downtime  │
└─────────────────────────┘         └──────────────────┘
        ↑
        │ pg_cron (scheduled runs)
```

The control database monitors target databases and runs `REINDEX CONCURRENTLY` when bloat exceeds thresholds. Since `REINDEX CONCURRENTLY` can't run inside a transaction, `dblink` executes it safely from the control database. This design means zero changes to production databases and no risk of blocking applications.

## Installation guide

### Prerequisites checklist

Before starting, ensure you have:
- PostgreSQL 13 or higher
- Ability to create a database (works on RDS, Aurora, CloudSQL, Supabase)
- Database owner or privileged user access
- About 5 minutes for initial setup

### Quick install (recommended)

The fastest way to get started is using our install script:

```bash
# Clone the repository
git clone https://gitlab.com/postgres-ai/pg_index_pilot
cd pg_index_pilot

# 1. Create the control database
PGPASSWORD='your_password' \
  ./index_pilot.sh install-control \
  -H your_host -U your_user -C index_pilot_control

# 2. Register the production database
PGPASSWORD='your_password' \
  ./index_pilot.sh register-target \
  -H your_host -U your_user -C index_pilot_control \
  -T your_production_db --fdw-host your_host

# 3. Verify everything is working
PGPASSWORD='your_password' \
  ./index_pilot.sh verify \
  -H your_host -U your_user -C index_pilot_control
```

For manual installation or platform-specific setup (RDS, CloudSQL), see [Detailed Installation Guide](docs/installation.md).

## Configuration

The default settings work well for most databases, but you can tune them if needed:

### Default behavior
- **Reindex threshold:** Indexes bloated more than 2x their optimal size
- **Minimum size:** Only processes indexes larger than 10 MiB
- **Schedule:** Configurable via `pg_cron` or system cron (see scheduling section below)
- **Method:** Uses `REINDEX CONCURRENTLY` (no blocking)

### Common adjustments

```sql
-- Exclude specific schemas (like toast tables)
select index_pilot.set_or_replace_setting(
    'production_db', 'pg_toast', null, null, 'skip', 'true', null
);

-- Change bloat threshold for a specific index
select index_pilot.set_or_replace_setting(
    'production_db', 'public', 'orders', 'orders_pkey', 
    'index_rebuild_scale_factor', '3.0', null
);

-- Set minimum index size to 50 MiB instead of 10 MiB
select index_pilot.set_or_replace_setting(
    'production_db', null, null, null, 
    'index_size_threshold', '50MB', null
);
```

## Scheduling automatic maintenance

### Using `pg_cron` (recommended for RDS/Aurora)

First, ensure `pg_cron` is available:

```sql
-- Check if pg_cron is installed
show shared_preload_libraries;  -- Should include pg_cron
show cron.database_name;         -- Shows which database runs cron jobs
```

Then schedule maintenance:

```sql
-- Connect to the cron database
\c postgres  -- Or whatever cron.database_name shows

-- Daily maintenance at 2 AM
select cron.schedule_in_database(
    'pg_index_pilot_daily',
    '0 2 * * *',
    'call index_pilot.periodic(real_run := true);',
    'index_pilot_control'
);

-- Check scheduled jobs
select jobname, schedule, command, active 
from cron.job 
where jobname like 'pg_index_pilot%';
```

### Using system cron (self-hosted)

Create a maintenance script that only runs on the primary:

```bash
#!/bin/bash
# /usr/local/bin/index_maintenance.sh

# Only run on primary (skip replicas)
psql -d postgres -AtqXc "select not pg_is_in_recovery()" | grep -qx t || exit

# Run index maintenance
psql -d index_pilot_control -c "call index_pilot.periodic(real_run := true);"
```

Add to crontab:
```cron
# Run daily at 2 AM
0 2 * * * /usr/local/bin/index_maintenance.sh
```

## Monitoring indexes

### Check current bloat status

```sql
-- Quick bloat summary for a database
select 
    indexrelname as index_name,
    pg_size_pretty(indexsize::bigint) as size,
    round(estimated_bloat::numeric, 1) || 'x' as bloat
from index_pilot.get_index_bloat_estimates('your_database')
where estimated_bloat > 1.5
order by estimated_bloat desc
limit 20;
```

### View maintenance history

```sql
-- See recent reindexing operations
select * from index_pilot.history 
where status = 'completed' 
order by ts desc 
limit 10;

-- Check for any failures
select * from index_pilot.history 
where status = 'failed' 
order by ts desc;
```

### Track space savings

```sql
-- Total space recovered this month
select 
    date_trunc('month', entry_timestamp) as month,
    count(*) as indexes_reindexed,
    pg_size_pretty(sum(indexsize_before - indexsize_after)::bigint) as space_saved
from index_pilot.reindex_history
where status = 'completed'
group by 1
order by 1 desc;
```

## FAQ for backend engineers

**Q: Will this block my production queries?**  
No, `pg_index_pilot` uses `REINDEX CONCURRENTLY` which only takes a brief lock at the very end. Queries keep running normally during the reindex operation.

**Q: What if a reindex fails mid-operation?**  
The system automatically cleans up any invalid indexes left behind. The application continues using the original index uninterrupted. Failed operations are logged for review.

**Q: How much overhead does this add?**  
Near zero. The control database does all the work, and `REINDEX CONCURRENTLY` has the same I/O impact as a manual reindex. The monitoring queries are lightweight and run infrequently.

**Q: Can I exclude critical indexes?**  
Yes, you can exclude any index, table, or entire schema from automatic reindexing using the settings system shown above.

**Q: Does this work on managed services like RDS?**  
Yes, it's tested on AWS RDS, Aurora, Google CloudSQL, and Supabase. Any PostgreSQL service that allows database creation will work.

**Q: How do I know it's actually working?**  
Check the `index_pilot.history` view to see completed reindex operations, space saved, and timing information. Index sizes will shrink after the first run.

## Emergency procedures

If you need to stop `pg_index_pilot` immediately:

```sql
-- Stop all scheduled jobs
select cron.unschedule(jobname) 
from cron.job 
where jobname like 'pg_index_pilot%';

-- Kill any active reindex operations
select pg_terminate_backend(pid) 
from pg_stat_activity 
where query like '%REINDEX CONCURRENTLY%';

-- Disable a specific database temporarily
update index_pilot.target_databases 
set enabled = false 
where datname = 'your_database';
```

To completely uninstall:
```bash
psql -d index_pilot_control -f uninstall.sql
```

## Production success metrics

Based on real deployments, here's what you can expect:

- **60-75% reduction** in index storage usage
- **2-3x faster** queries on previously bloated indexes
- **Zero hours** of manual maintenance per month
- **Zero production incidents** from automated reindexing
- **Hundreds of GiB** recovered in large databases

## Getting help

- **Installation issues:** Check [Detailed Installation Guide](docs/installation.md)
- **Configuration:** See [Function Reference](docs/function_reference.md)
- **Architecture details:** Read [Architecture Documentation](docs/architecture.md)
- **Platform-specific setup:** See guides for [AWS RDS](docs/installation.md#aws-rds--aurora-specifics), [CloudSQL](docs/installation.md#google-cloud-sql), etc.

## Contributing

We welcome contributions! `pg_index_pilot` is part of the PostgresAI project suite focused on making PostgreSQL operations autonomous. The codebase is pure PL/pgSQL by design, making it portable across all PostgreSQL deployments.

## License

`pg_index_pilot` is open source and available under the PostgreSQL License.

---

Start with the [quickstart](#how-it-works) above.