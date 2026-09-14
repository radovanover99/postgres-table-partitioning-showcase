#!/usr/bin/env bash
#
# run_all.sh — run the whole showcase from a clean slate.
#
#     PGDATABASE=ledgerdb ./scripts/run_all.sh
#     PGDATABASE=ledgerdb ./scripts/run_all.sh 2>&1 | tee showcase.log
#
# Each script is independent and re-runnable; this just runs them in
# order. For a live walkthrough, run them one at a time instead and talk
# through the output.

set -euo pipefail
cd "$(dirname "$0")/.."

for f in sql/0*.sql sql/10_*.sql; do
    printf '\n\n=================================================================\n'
    printf '>>> %s\n' "$f"
    printf '=================================================================\n'
    psql -X -q -P pager=off -v ON_ERROR_STOP=1 -f "$f"
done

printf '\n\nDone. Run sql/99_teardown.sql to clean up.\n'
