#!/bin/bash
# Test runner for pg_index_pilot
# Can be used locally or in CI/CD pipelines

# Don't use set -e as we need to handle test failures gracefully
set -o pipefail  # Still fail on pipe errors

# Default values
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-test_index_pilot}"
DB_USER="${DB_USER:-postgres}"
DB_PASS="${DB_PASS:-}"
INSTALL_ONLY="${INSTALL_ONLY:-false}"
SKIP_INSTALL="${SKIP_INSTALL:-false}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -h HOST       Database host (default: localhost)"
    echo "  -p PORT       Database port (default: 5432)"
    echo "  -d DATABASE   Database name (default: test_index_pilot)"
    echo "  -u USER       Database user (default: postgres)"
    echo "  -w PASSWORD   Database password"
    echo "  -i            Install only, don't run tests"
    echo "  -s            Skip installation, run tests only"
    echo "  -?            Show this help"
    echo ""
    echo "Environment variables:"
    echo "  DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS"
    exit 1
}

# Parse arguments
while getopts "h:p:d:u:w:is?" opt; do
    case $opt in
        h) DB_HOST="$OPTARG" ;;
        p) DB_PORT="$OPTARG" ;;
        d) DB_NAME="$OPTARG" ;;
        u) DB_USER="$OPTARG" ;;
        w) DB_PASS="$OPTARG" ;;
        i) INSTALL_ONLY="true" ;;
        s) SKIP_INSTALL="true" ;;
        ?) usage ;;
        *) usage ;;
    esac
done

# Set PGPASSWORD if provided
if [ -n "$DB_PASS" ]; then
    export PGPASSWORD="$DB_PASS"
fi

# Connection parameters are used directly in commands

echo "========================================"
echo "pg_index_pilot Test Suite"
echo "========================================"
echo "Host: $DB_HOST:$DB_PORT"
echo "Database: $DB_NAME"
echo "User: $DB_USER"
echo ""

# Function to run a SQL file
run_sql() {
    local file=$1
    local description=$2
    echo -e "${YELLOW}Running: $description${NC}"
    if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -X -d "$DB_NAME" -f "$file" > /tmp/test_output.log 2>&1; then
        echo -e "${GREEN}✓ $description passed${NC}"
        return 0
    else
        echo -e "${RED}✗ $description failed${NC}"
        echo "Error output:"
        cat /tmp/test_output.log
        return 1
    fi
}

# Check PostgreSQL version
echo "Checking PostgreSQL version..."
PG_VERSION=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -X -d postgres -tAc "SELECT current_setting('server_version_num')::int" || echo "0")
if [ "$PG_VERSION" -lt 130000 ]; then
    echo -e "${RED}Error: PostgreSQL 13 or higher required (found: $PG_VERSION)${NC}"
    exit 1
fi
echo -e "${GREEN}✓ PostgreSQL version OK${NC}"
echo ""

# Create test database
if [ "$SKIP_INSTALL" != "true" ]; then
    echo "Setting up test database..."
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -X -d postgres -c "DROP DATABASE IF EXISTS $DB_NAME" 2>/dev/null || true
    if ! psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -X -d postgres -c "CREATE DATABASE $DB_NAME"; then
        echo -e "${RED}Error: Failed to create database $DB_NAME${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Database created${NC}"
    echo ""
    
    # Install pg_index_pilot
    echo "Installing pg_index_pilot..."
    
    # Create extensions
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -X -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS dblink"
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -X -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS postgres_fdw"
    
    # Install schema and functions
    if [ -f "index_pilot_tables.sql" ]; then
        if ! run_sql "index_pilot_tables.sql" "Schema installation"; then
            echo -e "${RED}Error: Schema installation failed${NC}"
            exit 1
        fi
        if ! run_sql "index_pilot_functions.sql" "Functions installation"; then
            echo -e "${RED}Error: Functions installation failed${NC}"
            exit 1
        fi
    elif [ -f "../index_pilot_tables.sql" ]; then
        if ! run_sql "../index_pilot_tables.sql" "Schema installation"; then
            echo -e "${RED}Error: Schema installation failed${NC}"
            exit 1
        fi
        if ! run_sql "../index_pilot_functions.sql" "Functions installation"; then
            echo -e "${RED}Error: Functions installation failed${NC}"
            exit 1
        fi
    else
        echo -e "${RED}Error: Cannot find installation files${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ Installation complete${NC}"
    
    # Setup FDW for testing - using proper connection functions (after schema is installed)
    echo "Setting up FDW connection for testing..."
    
    # Try different hostnames for FDW connection
    # In CI/Docker, we need to find the right hostname for FDW to connect back
    FDW_SETUP_SUCCESS=false
    
    # In GitLab CI, the postgres service is accessible via 'postgres' hostname
    # But FDW needs to connect from within the database, so we need the right internal hostname
    if [ "$DB_HOST" = "postgres" ]; then
        # In CI, try postgres first (service name), then localhost for loopback
        FDW_HOSTS="postgres localhost 127.0.0.1"
    else
        # For external hosts (like RDS), use the actual hostname
        FDW_HOSTS="$DB_HOST"
    fi
    
    for FDW_HOST in $FDW_HOSTS; do
        echo "Trying FDW setup with host: $FDW_HOST"
        
        # Drop existing server if any
        psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -X -d "$DB_NAME" -c "
            DROP SERVER IF EXISTS index_pilot_self CASCADE;
        " 2>/dev/null || true
        
        # Try to setup FDW with this host
        if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -X -d "$DB_NAME" -c "
            SELECT index_pilot.setup_fdw_self_connection('$FDW_HOST', $DB_PORT, '$DB_NAME');
        " 2>/dev/null; then
            echo "FDW server created with host: $FDW_HOST"
            FDW_SETUP_SUCCESS=true
            break
        fi
    done
    
    if [ "$FDW_SETUP_SUCCESS" = "false" ]; then
        echo -e "${RED}ERROR: Failed to setup FDW server with any hostname${NC}"
        echo "Tried: $DB_HOST, localhost, 127.0.0.1"
        exit 1
    fi
    
    # Setup user mapping with password if provided
    if [ -n "$DB_PASS" ]; then
        psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -X -d "$DB_NAME" -c "
            SELECT index_pilot.setup_user_mapping('$DB_USER', '$DB_PASS');
        " || echo "Warning: Could not setup user mapping"
        
        # For RDS, also setup mapping for rds_superuser with PROPER credentials
        # Note: rds_superuser needs to connect as the actual postgres user
        psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -X -d "$DB_NAME" -c "
            DO \$\$
            BEGIN
                IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rds_superuser') THEN
                    -- Drop existing mapping if any
                    DROP USER MAPPING IF EXISTS FOR rds_superuser SERVER index_pilot_self;
                    -- Create mapping with postgres user credentials
                    CREATE USER MAPPING FOR rds_superuser SERVER index_pilot_self OPTIONS (user '$DB_USER', password '$DB_PASS');
                END IF;
            END \$\$;
        " 2>/dev/null || true
    else
        psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -X -d "$DB_NAME" -c "
            SELECT index_pilot.setup_user_mapping('$DB_USER', '');
        " || echo "Warning: Could not setup user mapping"
    fi
    
    # Test FDW connection actually works - REQUIRED
    echo "Testing FDW connection..."
    if ! psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -X -d "$DB_NAME" -c "
        SELECT index_pilot._connect_securely('$DB_NAME');
    "; then
        echo -e "${RED}ERROR: FDW connection test failed${NC}"
        echo "The tool requires FDW to function. Please check:"
        echo "1. postgres_fdw extension is installed"
        echo "2. FDW server is properly configured" 
        echo "3. User mappings are correct"
        exit 1
    fi
    echo -e "${GREEN}✓ FDW connection test successful${NC}"
    
    echo -e "${GREEN}✓ FDW setup complete${NC}"
    echo ""
fi

if [ "$INSTALL_ONLY" == "true" ]; then
    echo "Installation complete (install-only mode)"
    exit 0
fi

# Run tests
echo "Running test suite..."
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

# Find test directory
if [ -d "test" ]; then
    TEST_DIR="test"
elif [ -d "." ] && [ -f "01_basic_installation.sql" ]; then
    TEST_DIR="."
else
    echo -e "${RED}Error: Cannot find test files${NC}"
    echo "Current directory: $(pwd)"
    echo "Files in current directory:"
    ls -la
    if [ -d "test" ]; then
        echo "Files in test directory:"
        ls -la test/
    fi
    exit 1
fi

echo "Using test directory: $TEST_DIR"
echo "Test files found:"
ls -la "$TEST_DIR"/*.sql 2>/dev/null || echo "No .sql files found in $TEST_DIR"

# Initialize JUnit XML output
# Always create in test/ directory for CI artifact collection
if [ -d "test" ] && [ "$TEST_DIR" = "test" ]; then
    JUNIT_FILE="test/test-results.xml"
else
    JUNIT_FILE="test-results.xml"
fi
echo '<?xml version="1.0" encoding="UTF-8"?>' > "$JUNIT_FILE"
echo '<testsuites name="pg_index_pilot" tests="0" failures="0" time="0">' >> "$JUNIT_FILE"
echo '  <testsuite name="index_pilot_tests">' >> "$JUNIT_FILE"

# Run each test
START_TIME=$(date +%s)
# Use find to get test files to avoid glob issues
TEST_FILES=$(find "$TEST_DIR" -name "[0-9]*.sql" -type f | sort)

if [ -z "$TEST_FILES" ]; then
    echo -e "${RED}Error: No test files found in $TEST_DIR${NC}"
    exit 1
fi

echo "Running $(echo "$TEST_FILES" | wc -l) test files..."

IFS=$'\n'  # Set Internal Field Separator to newline for the loop
for test_file in $TEST_FILES; do
    echo "Processing: $test_file"
    if [ -f "$test_file" ]; then
        test_name=$(basename "$test_file" .sql)
        TEST_START=$(date +%s)
        
        if run_sql "$test_file" "$test_name"; then
            ((TESTS_PASSED++))
            TEST_END=$(date +%s)
            TEST_TIME=$((TEST_END - TEST_START))
            echo "    <testcase name=\"$test_name\" classname=\"index_pilot\" time=\"$TEST_TIME\"/>" >> "$JUNIT_FILE"
        else
            ((TESTS_FAILED++))
            TEST_END=$(date +%s)
            TEST_TIME=$((TEST_END - TEST_START))
            ERROR_MSG=$(cat /tmp/test_output.log | head -50 | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
            echo "    <testcase name=\"$test_name\" classname=\"index_pilot\" time=\"$TEST_TIME\">" >> "$JUNIT_FILE"
            echo "      <failure message=\"Test failed\">$ERROR_MSG</failure>" >> "$JUNIT_FILE"
            echo "    </testcase>" >> "$JUNIT_FILE"
        fi
    else
        echo "Warning: File not found: $test_file"
    fi
done
unset IFS  # Reset IFS

END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))

# Close JUnit XML
echo '  </testsuite>' >> "$JUNIT_FILE"
echo '</testsuites>' >> "$JUNIT_FILE"

# Update test counts in XML
sed -i.bak "s/tests=\"0\"/tests=\"$((TESTS_PASSED + TESTS_FAILED))\"/" "$JUNIT_FILE"
sed -i.bak "s/failures=\"0\"/failures=\"$TESTS_FAILED\"/" "$JUNIT_FILE"
sed -i.bak "s/time=\"0\"/time=\"$TOTAL_TIME\"/" "$JUNIT_FILE"
rm -f "$JUNIT_FILE.bak"

echo ""
echo "========================================"
echo "Test Summary"
echo "========================================"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
if [ $TESTS_FAILED -gt 0 ]; then
    echo -e "${RED}Failed: $TESTS_FAILED${NC}"
else
    echo -e "${GREEN}Failed: 0${NC}"
fi
echo ""

# Cleanup
if [ "$SKIP_INSTALL" != "true" ]; then
    echo "Cleaning up..."
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -X -d postgres -c "DROP DATABASE IF EXISTS $DB_NAME" 2>/dev/null || true
    echo -e "${GREEN}✓ Cleanup complete${NC}"
fi

# Exit with appropriate code
if [ $TESTS_FAILED -gt 0 ]; then
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi