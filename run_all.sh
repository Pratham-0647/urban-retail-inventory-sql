#!/usr/bin/env bash
# Rebuilds the whole project from the raw CSV.
# Usage:  ./run_all.sh            (database name defaults to urban_retail)
#         DB=mydb ./run_all.sh
set -euo pipefail
cd "$(dirname "$0")"
DB="${DB:-urban_retail}"

createdb "$DB" 2>/dev/null || true
mkdir -p outputs/dashboard_data

run () { echo ">> $1"; psql -d "$DB" -v ON_ERROR_STOP=1 -q -f "sql/$1" > "outputs/${1%.sql}.txt" 2>&1; }

run 00_load_raw.sql
run 01_data_profiling.sql
run 02_schema_normalized.sql
run 03_core_inventory_queries.sql
run 04_analytical_insights.sql
run 05_performance_optimization.sql
run 06_dashboard_exports.sql

echo "Done. Query results are in outputs/, dashboard CSVs in outputs/dashboard_data/."
