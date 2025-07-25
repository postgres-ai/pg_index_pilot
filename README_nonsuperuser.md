# Non-Superuser Mode Documentation

Starting with version 1.04, pg_index_pilot supports running without superuser privileges. This mode is particularly useful for:

- Cloud database services (AWS RDS, Google Cloud SQL, Azure Database for PostgreSQL)
- Environments with strict security policies
- Single-database monitoring scenarios

## How It Works

The system automatically detects whether it's running with superuser privileges and adjusts its behavior accordingly:

- **Superuser mode**: Monitors and maintains indexes across all databases (traditional behavior)
- **Non-superuser mode**: Monitors and maintains indexes only in the current database

## Requirements for Non-Superuser Mode

1. PostgreSQL 12.0 or higher
2. `dblink` extension installed
3. User must have:
   - `CREATE` privilege on the database
   - Ownership of indexes to be reindexed (or appropriate permissions)
   - `SELECT` privilege on `pg_stat_user_indexes`

## Installation for Non-Superuser Mode

```sql
-- Connect to your target database
\c your_database

-- Install dblink extension if not already present
CREATE EXTENSION IF NOT EXISTS dblink;

-- Install pg_index_pilot
\i index_watch_tables.sql
\i index_watch_functions.sql
```

## Checking Permissions

After installation, you can verify your permissions:

```sql
SELECT * FROM index_watch.check_permissions();
```

This will show:
- Can create indexes
- Can read pg_stat_user_indexes
- Has dblink extension
- Can REINDEX (owns indexes)

## Usage

The usage is identical to superuser mode:

```sql
-- Run without actual reindexing (dry run)
CALL index_watch.periodic(false);

-- Run with actual reindexing
CALL index_watch.periodic(true);

-- Force reindex specific index
CALL index_watch.do_reindex(
    current_database(),
    'public',
    'your_table',
    'your_index',
    true  -- force
);
```

## Testing on AWS RDS

```bash
# Set SSL mode
export PGSSLMODE=require

# Connect and run test
psql -h your-rds-instance.region.rds.amazonaws.com -U postgres -X -f test_nonsuperuser.sql
```

## Limitations in Non-Superuser Mode

1. Can only monitor and maintain the current database
2. Cannot access other databases in the cluster
3. Requires dblink loopback connection (may need password configuration)
4. Limited to indexes owned by the user or accessible via role membership

## Automatic Mode Detection

The system will inform you which mode it's running in during installation:

- Superuser: "pg_index_pilot is running in SUPERUSER mode - all databases will be monitored"
- Non-superuser: "pg_index_pilot is running in NON-SUPERUSER mode - only current database will be monitored"