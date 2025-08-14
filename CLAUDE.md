# CLAUDE.md - AI Assistant Guidelines for pg_index_pilot

## Overview
This document provides context and guidelines for AI assistants working on the pg_index_pilot codebase.

## Project Context
pg_index_pilot is an autonomous index lifecycle management tool for PostgreSQL that:
- Automatically detects and fixes index bloat using REINDEX CONCURRENTLY
- Uses Maxim Boguk's bloat estimation formula (works with any index type)
- Operates in a fire-and-forget manner using dblink/postgres_fdw
- Supports managed PostgreSQL services (RDS, Cloud SQL, etc.)
- Requires PostgreSQL 13+ and postgres_fdw for secure operation

## Important Rules
Please honor the rules defined in `.cursor/rules/` directory when working on this codebase, especially:
- `.cursor/rules/index-pilot-rules.md` - Project-specific guidelines
- `.cursor/rules/sql-style-guide.mdc` - SQL coding standards

## Key Technical Decisions

### Security
- **ALWAYS use postgres_fdw** for connections (no plaintext passwords in connection strings)
- **ALWAYS use format()** with %I and %L for dynamic SQL (never string concatenation)
- **NEVER store passwords** in code or configuration files
- **ALWAYS validate input** in all user-facing functions

### Code Style
- **NO unnecessary comments** in code - code should be self-documenting
- **Use RAISE DEBUG** instead of RAISE NOTICE for verbose/debug output
- **Keep responses concise** - avoid lengthy explanations unless requested
- **Prefer editing existing files** over creating new ones

### Testing
- **Tests MUST test real functionality** - no "graceful skipping"
- **FDW is REQUIRED** - tests should fail if FDW doesn't work
- **Test on PostgreSQL 13-17** to ensure compatibility
- **Run lint and typecheck** after making changes

### Naming Conventions
- Schema name: `index_pilot` (not index_watch)
- Main functions are in `index_pilot` schema
- Internal functions use underscore prefix (e.g., `_connect_securely`)
- Configuration keys use snake_case

## Core Components

### Files
- `index_pilot_tables.sql` - Schema and table definitions
- `index_pilot_functions.sql` - Core PL/pgSQL functions
- `test/` - Comprehensive test suite
- `.gitlab-ci.yml` - CI/CD pipeline configuration

### Key Functions
- `periodic()` - Main function that scans for bloated indexes
- `setup_connection()` - Configure FDW connection (not setup_rds_connection)
- `do_reindex()` - Performs REINDEX CONCURRENTLY operations
- `get_index_bloat_estimates()` - Returns bloat information

### Critical Tables
- `index_current_state` - Current state of all indexes
- `reindex_history` - History of reindex operations
- `config` - Configuration parameters
- `current_processed_index` - Tracks in-progress operations

## Development Workflow

### Before Making Changes
1. Read this file and `.cursorrules`
2. Understand the fire-and-forget architecture
3. Check existing patterns in the codebase

### When Making Changes
1. Follow existing code patterns
2. Ensure FDW connections work properly
3. Test with actual PostgreSQL instances
4. Verify changes work on managed services (RDS, etc.)

### Testing Changes
```bash
# Run tests locally
./test/run_tests.sh -h localhost -u postgres -w password -d test_db

# Test on RDS
./test/run_tests.sh -h your-instance.rds.amazonaws.com -u postgres -w password -d test_db
```

### Commit Messages
- Be concise and specific
- Include emoji only if fixing the build: 🤖
- Reference issue numbers when applicable

## Common Issues and Solutions

### FDW Connection Issues
- In Docker/CI: Try localhost, 127.0.0.1, or container IP
- On RDS: Ensure rds_superuser has proper user mapping
- Always test connection with `_connect_securely()` before operations

### Test Failures
- Check FDW is properly configured
- Verify postgres_fdw extension is installed
- Ensure user mappings exist for both regular user and rds_superuser

### Performance Considerations
- Bloat checking is resource-intensive - runs periodically
- REINDEX CONCURRENTLY takes time but doesn't block
- Consider load patterns when scheduling operations

## Contact and Support
- GitLab Issues: https://gitlab.com/postgres-ai/pg_index_pilot/-/issues
- Follow PostgreSQL best practices
- Consult PostgreSQL documentation for version-specific features