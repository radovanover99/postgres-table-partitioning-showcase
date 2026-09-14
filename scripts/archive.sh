#!/usr/bin/env bash
#
# archive.sh — the cron-able driver for the partition lifecycle.
#
# Why a shell script and not a pg_cron job: ALTER TABLE ... DETACH
# PARTITION ... CONCURRENTLY and VACUUM both refuse to run inside a
# transaction block, and pg_cron runs its jobs inside one. This script
# fetches the generated DDL and runs each statement in autocommit.
#
# Usage:
#     ./scripts/archive.sh                 # ensure partitions + archive
#     DRY_RUN=1 ./scripts/archive.sh       # print the plan, change nothing
#     PURGE=1 ./scripts/archive.sh         # also dump + drop expired cold data
#
# Environment:
#     PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE   standard libpq vars
#     PARENT     partitioned table          (default core.wallet_ledger)
#     DUMP_DIR   where purge dumps land     (default ./archive-dumps)
#     LOCK_TIMEOUT  per-statement lock wait (default 5s)
#
# Exit codes: 0 ok, 1 failure. Safe to re-run: every step reads the
# catalog, so a half-finished run simply continues where it stopped.

set -euo pipefail

PARENT="${PARENT:-core.wallet_ledger}"
DUMP_DIR="${DUMP_DIR:-./archive-dumps}"
LOCK_TIMEOUT="${LOCK_TIMEOUT:-5s}"
DRY_RUN="${DRY_RUN:-0}"
PURGE="${PURGE:-0}"

PSQL=(psql -X -q -v ON_ERROR_STOP=1)
PSQL_T=(psql -X -q -A -t -v ON_ERROR_STOP=1)

log() { printf '%s  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

run_sql() {
    # One statement, its own transaction, with a lock timeout so a busy
    # ledger makes maintenance fail fast instead of blocking writers.
    "${PSQL[@]}" -c "SET lock_timeout = '${LOCK_TIMEOUT}'; $1"
}

# ---------------------------------------------------------------------
# 1. Partition runway — create anything missing. Cheap, usually a no-op.
# ---------------------------------------------------------------------
log "ensuring future partitions for ${PARENT}"
if [[ "$DRY_RUN" == "1" ]]; then
    "${PSQL[@]}" -c "SELECT max(u) AS covered_until, max(u) - now() AS runway
                       FROM (SELECT (ops.partition_bounds(i.inhrelid)).upper_bound AS u
                               FROM pg_inherits i
                              WHERE i.inhparent = '${PARENT}'::regclass) s;"
else
    created=$("${PSQL_T[@]}" -c "SELECT coalesce(string_agg(x, ', '), '(none)') FROM ops.ensure_partitions('${PARENT}'::regclass) x;")
    log "created: ${created}"
fi

# ---------------------------------------------------------------------
# 2. Archive whatever has fallen out of the hot window.
# ---------------------------------------------------------------------
log "building archive plan"
mapfile -t STATEMENTS < <("${PSQL_T[@]}" \
    -c "SELECT statement FROM ops.archive_plan('${PARENT}'::regclass) ORDER BY seq;")

if [[ ${#STATEMENTS[@]} -eq 0 ]]; then
    log "nothing to archive"
else
    log "${#STATEMENTS[@]} statements to run"
    for stmt in "${STATEMENTS[@]}"; do
        [[ -z "$stmt" ]] && continue
        if [[ "$DRY_RUN" == "1" ]]; then
            printf '    %s\n' "$stmt"
        else
            log "-> ${stmt}"
            # DETACH CONCURRENTLY must not carry a lock_timeout that is
            # shorter than the wait for old snapshots; run it bare.
            if [[ "$stmt" == *"DETACH PARTITION"*"CONCURRENTLY"* || "$stmt" == VACUUM* ]]; then
                "${PSQL[@]}" -c "$stmt"
            else
                run_sql "$stmt"
            fi
        fi
    done
fi

# ---------------------------------------------------------------------
# 3. Cold retention. Dump first, always. DROP is the only step in this
#    whole design you cannot undo.
# ---------------------------------------------------------------------
if [[ "$PURGE" == "1" ]]; then
    mkdir -p "$DUMP_DIR"
    log "checking cold retention"
    mapfile -t DUE < <("${PSQL_T[@]}" \
        -c "SELECT partition FROM ops.purge_plan('${PARENT}'::regclass);")

    for part in "${DUE[@]}"; do
        [[ -z "$part" ]] && continue
        file="${DUMP_DIR}/${part//./_}.dump"
        if [[ "$DRY_RUN" == "1" ]]; then
            printf '    would dump %s -> %s then DROP\n' "$part" "$file"
            continue
        fi
        log "dumping ${part} -> ${file}"
        pg_dump -Fc -t "$part" -f "$file"
        # Trust, then verify: a dump you never listed is not a backup.
        pg_restore -l "$file" > /dev/null
        log "dropping ${part}"
        run_sql "DROP TABLE ${part};"
    done
fi

log "done"
