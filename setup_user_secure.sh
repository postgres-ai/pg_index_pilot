#!/bin/bash
# Secure setup script for index_pilot user
# Generates a random password and sets up the user securely

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Secure index_pilot User Setup ===${NC}"
echo

# Generate secure random password
echo -e "${YELLOW}Generating secure random password...${NC}"
RANDOM_PWD=$(openssl rand -base64 32)

if [ -z "$RANDOM_PWD" ]; then
  echo "Error: Failed to generate random password"
  exit 1
fi

# Get database connection parameters
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-postgres}"
DB_USER="${DB_USER:-postgres}"

echo "Database connection:"
echo "  Host: $DB_HOST"
echo "  Port: $DB_PORT"
echo "  Database: $DB_NAME"
echo "  Admin User: $DB_USER"
echo

# Run setup with secure password
echo -e "${YELLOW}Running setup_01_user.psql with secure password...${NC}"
PGPASSWORD="${PGPASSWORD}" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
  -f setup_01_user.psql \
  -v index_pilot_password="$RANDOM_PWD"

echo
echo -e "${GREEN}Setup complete!${NC}"
echo
echo -e "${YELLOW}IMPORTANT: Save this password securely!${NC}"
echo "Generated password for index_pilot user:"
echo "$RANDOM_PWD"
echo
echo "Next steps:"
echo "1. Connect as index_pilot user:"
echo "   PGPASSWORD='$RANDOM_PWD' psql -h $DB_HOST -p $DB_PORT -U index_pilot -d $DB_NAME"
echo
echo "2. Install pg_index_pilot:"
echo "   psql -U index_pilot -d $DB_NAME -f setup_02_tooling.psql"
echo
