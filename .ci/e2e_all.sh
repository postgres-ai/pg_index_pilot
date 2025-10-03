#!/bin/bash

set -euo pipefail

# Always cleanup on exit (both success and failure)
cleanup_on_exit() {
  echo "[all] Cleanup on exit"
  ./.ci/e2e_cleanup.sh || true
}
trap cleanup_on_exit EXIT

# Orchestrates full e2e run: cleanup -> windows test -> cleanup -> bloat test -> cleanup

echo "[all] Step 0: setup (bootstrap Postgres and install pg_index_pilot)"
./.ci/e2e_setup.sh

echo "[all] Step 1: maintenance windows test"
./.ci/e2e_maintenance_windows.sh

echo "[all] Step 2: cleanup"
./.ci/e2e_cleanup.sh

echo "[all] Step 3: setup"
./.ci/e2e_setup.sh

echo "[all] Step 4: bloat reduction test"
./.ci/e2e_bloat_reduction.sh

echo "[all] Step 5: final cleanup"
./.ci/e2e_cleanup.sh

echo "[all] E2E suite completed"
