#!/bin/bash
#
# metadb_cleanup.sh - Reclaim metadb.sqlite space from dead volume-UUID rows.
#
# Background: each SMB remount historically made foobar2000 mint a fresh
# volume UUID, and the plorg metadb migrator (pre-1.5.0) copied cached
# metadata rows to the new UUID without deleting the old ones. The result is
# one full copy of the library's metadata per remount generation (observed:
# 4 copies, 8.7 GB). This tool deletes rows whose mac-volume:// UUID is no
# longer referenced by any playlist and is not live in foobar's registry,
# then VACUUMs to return the space to the filesystem.
#
# Safety:
#   - refuses to run while foobar2000 is running (except --dry-run, read-only)
#   - keep-set = UUIDs referenced by any .fplite playlist, plus live UUIDs
#     from plorg's last registry snapshot (plorg_volume_uuids.json)
#   - full backup (DB + WAL/SHM) before any write, unless --no-backup
#   - all deletes in one transaction with .bail on (all-or-nothing)
#   - integrity verified with PRAGMA quick_check afterwards
#
# Usage: metadb_cleanup.sh [--dry-run] [--yes] [--no-backup]
#   --dry-run    analyze and print the plan only; never writes (safe while
#                foobar2000 is running)
#   --yes        skip the interactive confirmation
#   --no-backup  skip the pre-cleanup backup (use when disk space does not
#                allow a full copy; deletes remain transactional)

set -euo pipefail

# PLORG_FB2K_DIR: test-only override of the foobar2000 data directory. When
# set to a directory other than the real default, the running-foobar2000
# guard is skipped too, because fb2k only ever uses ~/Library/foobar2000-v2 -
# a different directory is never its live DB. An override that resolves to
# the default still enforces the guard.
FB2K_DEFAULT_DIR="$HOME/Library/foobar2000-v2"
FB2K_DIR="${PLORG_FB2K_DIR:-$FB2K_DEFAULT_DIR}"
DB="$FB2K_DIR/metadb.sqlite"
PLAYLISTS_DIR="$FB2K_DIR/playlists-v2.0"
JSON="$FB2K_DIR/plorg_volume_uuids.json"
BK="$DB.plorg-pre-cleanup"

DRY_RUN=0
ASSUME_YES=0
NO_BACKUP=0
for arg in "$@"; do
    case "$arg" in
        --dry-run)   DRY_RUN=1 ;;
        --yes)       ASSUME_YES=1 ;;
        --no-backup) NO_BACKUP=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

# Volume-URL scheme prefix in fb2k mac paths. Source of truth for this
# standalone script; substring offsets are derived as ${#SCHEME}.
SCHEME="mac-volume://"

UUID_RE='^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$'
INDEX_TABLE_RE='^metadb_index_[0-9A-Fa-f]{8}(_[0-9A-Fa-f]{4}){3}_[0-9A-Fa-f]{12}$'

[ -f "$DB" ] || { echo "ERROR: $DB not found" >&2; exit 1; }

# Canonicalize a path for comparison; falls back to the raw path when it
# does not exist or cannot be resolved.
canonical_path() { /usr/bin/readlink -f "$1" 2>/dev/null || echo "$1"; }

# True when both arguments name the same directory. Compares device+inode,
# which catches APFS firmlink aliases (e.g. /System/Volumes/Data$HOME/...)
# that readlink -f does not fold; falls back to canonical-path comparison
# when either stat fails (path missing or unreadable).
same_dir() {
    local a b
    a="$(/usr/bin/stat -f '%d:%i' "$1" 2>/dev/null)" || a=""
    b="$(/usr/bin/stat -f '%d:%i' "$2" 2>/dev/null)" || b=""
    if [ -n "$a" ] && [ -n "$b" ]; then
        [ "$a" = "$b" ]
    else
        [ "$(canonical_path "$1")" = "$(canonical_path "$2")" ]
    fi
}

OVERRIDE_IS_DEFAULT=1
if [ -n "${PLORG_FB2K_DIR:-}" ] && ! same_dir "$FB2K_DIR" "$FB2K_DEFAULT_DIR"; then
    OVERRIDE_IS_DEFAULT=0
fi

if [ "$DRY_RUN" -eq 0 ] && [ "$OVERRIDE_IS_DEFAULT" -eq 1 ] && /usr/bin/pgrep -x foobar2000 >/dev/null 2>&1; then
    echo "ERROR: foobar2000 is running. Quit it first (or use --dry-run for a read-only analysis)." >&2
    exit 1
fi

# --- Build the keep-set -----------------------------------------------------

declare -a KEEP=()

# 1. UUIDs referenced by any current .fplite playlist
if [ -d "$PLAYLISTS_DIR" ]; then
    while IFS= read -r u; do
        KEEP+=("$u")
    done < <(grep -aohE "${SCHEME}[0-9A-Fa-f-]{36}" "$PLAYLISTS_DIR"/*.fplite 2>/dev/null \
             | sed "s|$SCHEME||" | sort -u | tr '[:lower:]' '[:upper:]')
fi

# 2. Live UUIDs from plorg's last registry snapshot
if [ -f "$JSON" ]; then
    if command -v python3 >/dev/null 2>&1; then
        while IFS= read -r u; do
            KEEP+=("$u")
        done < <(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("WARNING: could not parse %s: %s" % (sys.argv[1], e), file=sys.stderr)
    print("         Keep-set will rely on playlist references only.", file=sys.stderr)
    sys.exit(0)
for entry in d.get("paths", {}).values():
    for u in entry.get("live_uuids", []):
        print(u)
' "$JSON" | tr '[:lower:]' '[:upper:]')
    else
        echo "WARNING: python3 not found; cannot read live UUIDs from $JSON." >&2
        echo "         Keep-set will rely on playlist references only." >&2
    fi
fi

# Dedup + validate before anything is interpolated into SQL. KEEP_SET mirrors
# KEEP_VALID as a |-delimited string for cheap membership tests during analysis
# (associative arrays need bash 4; macOS ships bash 3.2 at /bin/bash).
declare -a KEEP_VALID=()
KEEP_SET="|"
for u in $(printf '%s\n' "${KEEP[@]:-}" | sort -u); do
    [[ "$u" =~ $UUID_RE ]] && { KEEP_VALID+=("$u"); KEEP_SET="${KEEP_SET}${u}|"; }
done

if [ "${#KEEP_VALID[@]}" -eq 0 ]; then
    echo "ERROR: keep-set is empty (no playlist references, no live registry UUIDs)." >&2
    echo "       Refusing to delete anything without a confirmed set of UUIDs to keep." >&2
    exit 1
fi

echo "Keep-set (${#KEEP_VALID[@]} UUID(s) that will NOT be touched):"
printf '  %s\n' "${KEEP_VALID[@]}"
echo

# --- Analyze the database ---------------------------------------------------

SQLITE_RO=(/usr/bin/sqlite3 -cmd ".timeout 30000" "file:$DB?mode=ro")

echo "Analyzing $DB (this scans the whole table; may take a minute)..."
DIST="$("${SQLITE_RO[@]}" "SELECT substr(name, instr(name, '$SCHEME')+${#SCHEME}, 36), COUNT(*)
    FROM metadb WHERE name LIKE '%$SCHEME%'
    GROUP BY 1 ORDER BY 2 DESC;" | tr '[:lower:]' '[:upper:]')"

declare -a DEAD=()
TOTAL_DELETE=0
echo "Volume UUIDs in metadb:"
while IFS='|' read -r uuid count; do
    [ -n "$uuid" ] || continue
    if ! [[ "$uuid" =~ $UUID_RE ]]; then
        echo "  $uuid ($count rows) - malformed, skipped"
        continue
    fi
    if [[ "$KEEP_SET" == *"|$uuid|"* ]]; then
        echo "  $uuid ($count rows) - KEEP (referenced/live)"
    else
        echo "  $uuid ($count rows) - DELETE (dead, unreferenced)"
        DEAD+=("$uuid")
        TOTAL_DELETE=$((TOTAL_DELETE + count))
    fi
done <<< "$DIST"
echo

if [ "${#DEAD[@]}" -eq 0 ]; then
    echo "Nothing to clean: every volume UUID in metadb is referenced or live."
    exit 0
fi

DB_SIZE=$(/usr/bin/stat -f%z "$DB")
echo "Plan: delete $TOTAL_DELETE rows across ${#DEAD[@]} dead UUID(s), then VACUUM."
echo "Current size: $(echo "$DB_SIZE" | awk '{printf "%.1f GB", $1/1073741824}')"
echo

if [ "$DRY_RUN" -eq 1 ]; then
    echo "Dry run - no changes made."
    exit 0
fi

# --- Disk space + confirmation ----------------------------------------------

AVAIL=$(( $(/bin/df -k "$FB2K_DIR" | /usr/bin/awk 'NR==2 {print $4}') * 1024 ))
if [ "$NO_BACKUP" -eq 0 ]; then
    NEEDED=$(( DB_SIZE * 2 + DB_SIZE / 5 ))   # backup copy + VACUUM temp
else
    NEEDED=$(( DB_SIZE + DB_SIZE / 5 ))       # VACUUM temp only
fi
if [ "$AVAIL" -lt "$NEEDED" ]; then
    echo "ERROR: not enough free disk space." >&2
    echo "  needed:    $(echo "$NEEDED" | awk '{printf "%.1f GB", $1/1073741824}') (backup + VACUUM workspace)" >&2
    echo "  available: $(echo "$AVAIL" | awk '{printf "%.1f GB", $1/1073741824}')" >&2
    [ "$NO_BACKUP" -eq 0 ] && echo "  (retry with --no-backup to skip the backup copy)" >&2
    exit 1
fi

if [ "$ASSUME_YES" -eq 0 ]; then
    printf "Proceed? [y/N] "
    read -r answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *) echo "Aborted."; exit 0 ;;
    esac
fi

# --- Backup ------------------------------------------------------------------

if [ "$NO_BACKUP" -eq 0 ]; then
    echo "Backing up to $BK ..."
    /bin/cp -f "$DB" "$BK"
    for ext in -wal -shm; do
        if [ -f "$DB$ext" ]; then /bin/cp -f "$DB$ext" "$BK$ext"; else rm -f "$BK$ext"; fi
    done
fi

# --- Build and run the cleanup SQL -------------------------------------------

SQL="$(mktemp /tmp/plorg_metadb_cleanup_sql.XXXXXX)"
trap 'rm -f "$SQL"' EXIT

{
    echo ".bail on"
    echo ".timeout 10000"
    echo "BEGIN IMMEDIATE;"
    for u in "${DEAD[@]}"; do
        echo "DELETE FROM metadb WHERE name LIKE '%$SCHEME$u/%';"
    done

    # Index tables: (key INTEGER, filename TEXT UNIQUE PRIMARY KEY). GLOB
    # treats '_' literally, so 'metadb_index_*' cannot match metadb_indexes;
    # the shell regex below re-validates the exact GUID shape anyway.
    while IFS= read -r t; do
        [[ "$t" =~ $INDEX_TABLE_RE ]] || continue
        for u in "${DEAD[@]}"; do
            echo "DELETE FROM \"$t\" WHERE filename LIKE '%$SCHEME$u/%';"
        done
        # GC blob rows whose key is no longer referenced by any filename
        echo "DELETE FROM \"${t}_data\" WHERE key NOT IN (SELECT key FROM \"$t\");"
    done < <("${SQLITE_RO[@]}" "SELECT name FROM sqlite_master WHERE type='table'
              AND name GLOB 'metadb_index_*' AND NOT name GLOB '*_data';")

    echo "COMMIT;"
    echo "VACUUM;"
} > "$SQL"

echo "Deleting dead rows and vacuuming (VACUUM rewrites the whole DB; expect several minutes)..."
if ! /usr/bin/sqlite3 "$DB" < "$SQL"; then
    echo "ERROR: cleanup SQL run failed (disk full during VACUUM, lock, or I/O error)." >&2
    STATE="$(/usr/bin/sqlite3 -cmd '.timeout 10000' "$DB" 'PRAGMA quick_check;' 2>&1 || true)"
    echo "  DB state (quick_check): $STATE" >&2
    echo "  Deletes are all-or-nothing; a failure before COMMIT is rolled back, and" >&2
    echo "  an aborted VACUUM leaves the original data intact." >&2
    if [ "$NO_BACKUP" -eq 0 ]; then
        echo "  Backup: $BK" >&2
        echo "  Restore: cp '$BK' '$DB' (and the -wal/-shm siblings if present)" >&2
    else
        echo "  No backup was taken (--no-backup); verify with: sqlite3 '$DB' 'PRAGMA quick_check;'" >&2
    fi
    exit 1
fi

# --- Verify -------------------------------------------------------------------

echo "Verifying integrity (quick_check)..."
CHECK="$(/usr/bin/sqlite3 "$DB" "PRAGMA quick_check;")"
NEW_SIZE=$(/usr/bin/stat -f%z "$DB")

echo
echo "Result:"
echo "  quick_check: $CHECK"
echo "  size before: $(echo "$DB_SIZE"  | awk '{printf "%.1f GB", $1/1073741824}')"
echo "  size after:  $(echo "$NEW_SIZE" | awk '{printf "%.1f GB", $1/1073741824}')"

if [ "$CHECK" != "ok" ]; then
    echo "ERROR: integrity check failed AFTER cleanup." >&2
    if [ "$NO_BACKUP" -eq 0 ]; then
        echo "Restore the backup: cp '$BK' '$DB' (and the -wal/-shm siblings if present)" >&2
    fi
    exit 1
fi

if [ "$NO_BACKUP" -eq 0 ]; then
    echo
    echo "Backup kept at $BK - delete it once foobar2000 has been verified working:"
    echo "  rm '$BK'"
fi
echo "Done."
