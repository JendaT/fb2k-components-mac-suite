#!/bin/bash
#
# volume_registry_prune.sh - remove foobar2000 volume-registry entries that
# nothing uses any more.
#
# foobar2000 keeps a bookmark per volume UUID in config.sqlite
# (mac.volume.<UUID>.originalPath / .bookmark). Every remount of the music share
# under a new server identity adds one, and none are ever removed: this machine
# had 20, carrying four different addresses for the same share (Bonjour, Bonjour
# service name, Tailscale, DDNS). A bookmark resolves by mounting the address it
# embeds, so each stale entry is a way for foobar2000 to bring the share up a
# second time - /Volumes/music-1 - and cache a second full copy of the library.
#
# An entry is removed only when ALL of these hold:
#   * its originalPath is the share's mountpoint: /Volumes/<share> or
#     /Volumes/<share>-N (case-insensitive) - other volumes are not ours to judge
#   * the Media Library does not watch it (library-v2.0 folders / rootPath)
#   * no live playlist references its UUID (plorg's backup_* folders are ignored;
#     a restored backup is re-mapped by plorg's volume sync anyway)
#   * no metadb row references it
#
# Dry run by default. --apply writes, and only while foobar2000 is not running;
# config.sqlite is backed up first and the deletion is one transaction.
#
# Exit: 0 ok (or nothing to do)  1 usage  2 foobar2000 running  3 failed

set -u

FB2K_DIR="${FB2K_DIR:-$HOME/Library/foobar2000-v2}"
SHARE="music"
APPLY=0
FB2K_PROCESS="${FB2K_PROCESS:-foobar2000}"   # test seam

usage() {
    cat <<USAGE
volume_registry_prune.sh [--apply] [--share NAME]

  (no args)     dry run: list what would be removed and why, change nothing
  --apply       remove the entries (foobar2000 must not be running)
  --share NAME  mountpoint name of the share (default: music)
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1 ;;
        --share) shift; SHARE="${1:-}"; [ -n "$SHARE" ] || { usage; exit 1; } ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage; exit 1 ;;
    esac
    shift
done

CONFIG="$FB2K_DIR/config.sqlite"
METADB="$FB2K_DIR/metadb.sqlite"
PLAYLISTS="$FB2K_DIR/playlists-v2.0"
LIBRARY="$FB2K_DIR/library-v2.0"
UUID_RE='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'

[ -f "$CONFIG" ] || { echo "no config.sqlite at $CONFIG" >&2; exit 3; }

if [ "$APPLY" -eq 1 ] && /usr/bin/pgrep -x "$FB2K_PROCESS" >/dev/null 2>&1; then
    echo "foobar2000 is running. It keeps this registry in memory and writes it"
    echo "back, so quit it first. Nothing was changed."
    exit 2
fi

WORK="$(/usr/bin/mktemp -d -t plorgprune)" || exit 3
trap '/bin/rm -rf "$WORK"' EXIT

# Read from a consistent snapshot, never the live files: foobar2000 may be
# running during a dry run.
/usr/bin/sqlite3 "file:$CONFIG?mode=ro" ".backup '$WORK/config.sqlite'" 2>/dev/null \
    || { echo "could not read $CONFIG" >&2; exit 3; }

# UUIDs referenced anywhere that matters, upper-cased, one per line.
{
    if [ -d "$PLAYLISTS" ]; then
        /usr/bin/find "$PLAYLISTS" -maxdepth 1 -type f -exec \
            /usr/bin/grep -aohE "mac-volume://$UUID_RE" {} + 2>/dev/null
    fi
    # The Media Library's watched folders. Missing these let a prune delete the
    # bookmark the library root depends on, so the library could not refill
    # (2026-10-02). Both the folder list and each library database's rootPath.
    if [ -f "$LIBRARY/folders" ]; then
        /usr/bin/grep -aohE "mac-volume://$UUID_RE" "$LIBRARY/folders" 2>/dev/null
    fi
    for lib in "$LIBRARY"/*/content.sqlite; do
        [ -f "$lib" ] || continue
        /usr/bin/sqlite3 -cmd "PRAGMA busy_timeout=15000;" "file:$lib?mode=ro" \
            "SELECT value FROM config WHERE key = 'rootPath';" 2>/dev/null \
            | /usr/bin/grep -aoE "mac-volume://$UUID_RE" \
            || true
    done
    if [ -f "$METADB" ]; then
        /usr/bin/sqlite3 -cmd "PRAGMA busy_timeout=15000;" "file:$METADB?mode=ro" "
            SELECT DISTINCT substr(name, instr(name, 'mac-volume://'), 49)
            FROM metadb WHERE name LIKE '%mac-volume://%';" 2>/dev/null \
            || echo "METADB_UNREADABLE"
    fi
} | /usr/bin/sed 's|^mac-volume://||' | /usr/bin/tr 'a-f' 'A-F' | /usr/bin/sort -u > "$WORK/referenced"

# A partial reference set would make live entries look unused.
if /usr/bin/grep -qx "METADB_UNREADABLE" "$WORK/referenced"; then
    echo "could not read metadb.sqlite (locked?). Refusing to decide on partial data." >&2
    exit 3
fi

share_lc="$(printf '%s' "$SHARE" | /usr/bin/tr 'A-Z' 'a-z')"
/usr/bin/sqlite3 -separator '|' "$WORK/config.sqlite" \
    "SELECT substr(name, 12, 36), value FROM configStrings
     WHERE name LIKE 'mac.volume.%.originalPath' ORDER BY name;" > "$WORK/registry"

total=0; keep=0; remove=0
: > "$WORK/remove"
printf '%-38s %-20s %s\n' "UUID" "originalPath" "decision"
while IFS='|' read -r uuid path; do
    [ -z "$uuid" ] && continue
    total=$((total + 1))
    uu="$(printf '%s' "$uuid" | /usr/bin/tr 'a-f' 'A-F')"
    base_lc="$(printf '%s' "${path#/Volumes/}" | /usr/bin/tr 'A-Z' 'a-z')"
    ours=0
    case "$path" in
        /Volumes/*/*) ours=0 ;;
        /Volumes/*)
            if [ "$base_lc" = "$share_lc" ]; then ours=1
            else
                case "$base_lc" in
                    "$share_lc"-*) suffix="${base_lc#"$share_lc"-}"
                        case "$suffix" in ''|*[!0-9]*) ;; *) ours=1 ;; esac ;;
                esac
            fi ;;
    esac
    if [ "$ours" -eq 0 ]; then
        why="keep - not the $SHARE share"; keep=$((keep + 1))
    elif /usr/bin/grep -qxF "$uu" "$WORK/referenced"; then
        why="keep - referenced"; keep=$((keep + 1))
    else
        why="REMOVE - unreferenced"; remove=$((remove + 1))
        printf '%s\n' "$uuid" >> "$WORK/remove"
    fi
    printf '%-38s %-20s %s\n' "$uuid" "$path" "$why"
done < "$WORK/registry"

echo
echo "registry entries: $total   keep: $keep   remove: $remove"

if [ "$remove" -eq 0 ]; then
    echo "Nothing to remove."
    exit 0
fi
if [ "$APPLY" -eq 0 ]; then
    echo "Dry run - nothing changed. Re-run with --apply while foobar2000 is quit."
    exit 0
fi

backup="$CONFIG.plorg-prune-$(/bin/date +%Y%m%d-%H%M%S)"
/bin/cp -f "$CONFIG" "$backup" || { echo "backup failed; nothing changed" >&2; exit 3; }
echo "backed up config.sqlite to $backup"

{
    echo ".bail on"
    echo "BEGIN IMMEDIATE;"
    while read -r uuid; do
        # uuid came from the registry and matched the UUID shape via substr, but
        # validate again before it is interpolated into SQL.
        printf '%s' "$uuid" | /usr/bin/grep -qE "^$UUID_RE\$" || continue
        for t in config configStrings configInts configBlobs configReals; do
            echo "DELETE FROM $t WHERE name LIKE 'mac.volume.$uuid.%';"
        done
    done < "$WORK/remove"
    echo "COMMIT;"
} > "$WORK/prune.sql"

if ! /usr/bin/sqlite3 "$CONFIG" < "$WORK/prune.sql"; then
    echo "deletion failed; the transaction rolled back. Backup kept at $backup" >&2
    exit 3
fi
chk="$(/usr/bin/sqlite3 "$CONFIG" 'PRAGMA quick_check;' 2>&1 | /usr/bin/head -1)"
if [ "$chk" != "ok" ]; then
    /bin/cp -f "$backup" "$CONFIG"
    echo "integrity check failed ($chk); restored the backup" >&2
    exit 3
fi
left="$(/usr/bin/sqlite3 "$CONFIG" "SELECT count(*) FROM configStrings WHERE name LIKE 'mac.volume.%.originalPath';")"
echo "removed $remove entries; $left remain. Integrity: ok. Backup: $backup"
