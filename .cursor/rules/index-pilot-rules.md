# .cursorrules - AI Assistant Rules for pg_index_pilot

## Response Style
- Be concise and direct
- Provide code examples without lengthy explanations
- One-word answers are fine when appropriate
- Avoid preambles like "Here's how..." or "Let me explain..."

## Code Guidelines

### PostgreSQL/SQL
- ALWAYS use format() for dynamic SQL, never string concatenation
- Use %I for identifiers, %L for literals in format()
- Prefer PL/pgSQL for complex logic
- Use RAISE DEBUG for debug output, not RAISE NOTICE
- No unnecessary comments in SQL code

### Security
- Never store passwords in code
- Always use postgres_fdw for connections
- Validate all user inputs
- Use quote_ident() and quote_literal() when format() isn't available

### Testing
- Tests must actually test functionality
- No "graceful skipping" - fail if requirements aren't met
- FDW is required - tests should fail without it
- Always test on real PostgreSQL instances

### Git Commits
- Follow simplified Conventional Commits for the subject line
- Keep first line under 72 characters
- Use present tense ("Add feature" not "Added feature")
- Supported types drive release notes:
  - `feat:` new functionality (MINOR)
  - `fix:` bug fix (PATCH)
  - `perf:` performance improvement (PATCH)
  - `docs:` documentation only (no release)
  - `chore:` infra, CI, dependencies (no release)
  - `test:` tests only (no release)
  - `refactor:` refactor without API changes (no release)
- Breaking changes: append `!` after the type, e.g. `feat!: drop support for Postgres 13`
- MR/PR titles should match the main commit subject
- No emojis except 🤖 for automated fixes
- Reference issues when applicable (e.g., `Closes #123`)

Examples:
- `feat: add dry-run mode for automatic reindex`
- `fix: avoid deadlock on REINDEX CONCURRENTLY`
- `perf: reduce lock time by 20%`
- `docs: update PG 13–17 support matrix`
- `refactor!: remove legacy flag`

## Project-Specific Rules

### Naming
- Use `index_pilot` not `index_watch`
- Use `setup_connection()` not `setup_rds_connection()`
- Internal functions start with underscore

### Architecture
- Respect fire-and-forget design using dblink
- Maintain compatibility with managed PostgreSQL services
- Support PostgreSQL 13+ only
- Require postgres_fdw for all operations

### File Modifications
- Prefer editing existing files over creating new ones
- Don't create README files unless explicitly requested
- Don't create documentation unless asked
- Keep changes minimal and focused

## What NOT to Do
- Don't add verbose comments to code
- Don't explain what you're doing unless asked
- Don't create test files that skip tests
- Don't use plain text passwords in connection strings
- Don't assume libraries are available without checking
- Don't break backward compatibility without discussion

## Testing Commands
```bash
# Always run tests after changes
./test/run_tests.sh -h <host> -u <user> -w <password> -d <database>

# Check for SQL injection
grep -E "EXECUTE.*\|\|" *.sql

# Verify FDW setup
psql -c "SELECT * FROM pg_foreign_server WHERE srvname LIKE 'target_%'"
```

## Priority Order
1. Security (no SQL injection, no plaintext passwords)
2. Functionality (must actually work)
3. Testing (must be testable and tested)
4. Performance (efficient queries)
5. Documentation (only when requested)