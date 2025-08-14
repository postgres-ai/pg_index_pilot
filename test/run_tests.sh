#!/bin/bash
# Test runner for pg_index_pilot
# Can be used locally or in CI/CD pipelines

set -e  # Exit on error

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

# Connection string
PSQL="psql -h $DB_HOST -p $DB_PORT -U $DB_USER -X"

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
    if $PSQL -d "$DB_NAME" -f "$file" > /tmp/test_output.log 2>&1; then
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
PG_VERSION=$($PSQL -d postgres -tAc "SELECT current_setting('server_version_num')::int")
if [ "$PG_VERSION" -lt 120000 ]; then
    echo -e "${RED}Error: PostgreSQL 12 or higher required (found: $PG_VERSION)${NC}"
    exit 1
fi
echo -e "${GREEN}✓ PostgreSQL version OK${NC}"
echo ""

# Create test database
if [ "$SKIP_INSTALL" != "true" ]; then
    echo "Setting up test database..."
    $PSQL -d postgres -c "DROP DATABASE IF EXISTS $DB_NAME" 2>/dev/null || true
    $PSQL -d postgres -c "CREATE DATABASE $DB_NAME"
    echo -e "${GREEN}✓ Database created${NC}"
    echo ""
    
    # Install pg_index_pilot
    echo "Installing pg_index_pilot..."
    
    # Create extensions
    $PSQL -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS dblink"
    $PSQL -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS postgres_fdw"
    
    # Install schema and functions
    if [ -f "index_pilot_tables.sql" ]; then
        run_sql "index_pilot_tables.sql" "Schema installation"
        run_sql "index_pilot_functions.sql" "Functions installation"
    elif [ -f "../index_pilot_tables.sql" ]; then
        run_sql "../index_pilot_tables.sql" "Schema installation"
        run_sql "../index_pilot_functions.sql" "Functions installation"
    else
        echo -e "${RED}Error: Cannot find installation files${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ Installation complete${NC}"
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
    exit 1
fi

# Initialize JUnit XML output
JUNIT_FILE="test-results.xml"
echo '<?xml version="1.0" encoding="UTF-8"?>' > "$JUNIT_FILE"
echo '<testsuites name="pg_index_pilot" tests="0" failures="0" time="0">' >> "$JUNIT_FILE"
echo '  <testsuite name="index_pilot_tests">' >> "$JUNIT_FILE"

# Run each test
START_TIME=$(date +%s)
for test_file in "$TEST_DIR"/[0-9]*.sql; do
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
    fi
done

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
    $PSQL -d postgres -c "DROP DATABASE IF EXISTS $DB_NAME" 2>/dev/null || true
    echo -e "${GREEN}✓ Cleanup complete${NC}"
fi

# Exit with appropriate code
if [ $TESTS_FAILED -gt 0 ]; then
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi