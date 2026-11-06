#!/bin/bash
# Runs volume_registry_prune.sh against a synthetic foobar2000 profile.
set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/volume_registry_prune.sh"
T="$(mktemp -d -t plorgprunetest)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ck() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  ok   $1"; else FAIL=$((FAIL+1)); echo "  FAIL $1: expected '$3', got '$2'"; fi; }

LIVE=5A49E84B-7913-C241-20A9-D2FA194343AB     # referenced by a live playlist
META=1998A73C-D4D2-23A1-D179-EB8E0C71035A     # referenced only by metadb (lower-case there)
DEAD1=5963B3DB-169A-6BBC-183D-E5926BB95686    # /Volumes/music-1, only in a backup playlist
DEAD2=B73BE788-9B0D-2CA7-E3AE-1C0A69A46706    # /Volumes/Music, unreferenced
LACIE=54C73A05-8A56-02D8-5E23-722811C58504    # other volume, unreferenced
NEAR=AAAAAAAA-0000-0000-0000-000000000001     # /Volumes/music-backup, unreferenced - not ours

mkprofile() {
    local d="$1"; rm -rf "$d"; mkdir -p "$d/playlists-v2.0/backup_volume_sync_2026-09-24_190223"
    sqlite3 "$d/config.sqlite" "
      CREATE TABLE config (name TEXT UNIQUE PRIMARY KEY NOT NULL, value INTEGER);
      CREATE TABLE configStrings (name TEXT UNIQUE PRIMARY KEY NOT NULL, value TEXT);
      CREATE TABLE configInts (name TEXT UNIQUE PRIMARY KEY NOT NULL, value INTEGER);
      CREATE TABLE configBlobs (name TEXT UNIQUE PRIMARY KEY NOT NULL, value BLOB);
      CREATE TABLE configReals (name TEXT UNIQUE PRIMARY KEY NOT NULL, value REAL);
      INSERT INTO configStrings VALUES ('unrelated.setting', 'keep me');"
    for p in "$LIVE:/Volumes/music" "$META:/Volumes/music" "$DEAD1:/Volumes/music-1" \
             "$DEAD2:/Volumes/Music" "$LACIE:/Volumes/LaCie" "$NEAR:/Volumes/music-backup"; do
        u="${p%%:*}"; path="${p#*:}"
        sqlite3 "$d/config.sqlite" "INSERT INTO configStrings VALUES ('mac.volume.$u.originalPath', '$path');
                                    INSERT INTO configBlobs VALUES ('mac.volume.$u.bookmark', x'00');"
    done
    printf 'junk mac-volume://%s/a.flac junk' "$LIVE" > "$d/playlists-v2.0/playlist-1.fplite"
    printf 'mac-volume://%s/b.flac' "$DEAD1" > "$d/playlists-v2.0/backup_volume_sync_2026-09-24_190223/playlist-1.fplite"
    sqlite3 "$d/metadb.sqlite" "CREATE TABLE metadb (name TEXT UNIQUE PRIMARY KEY NOT NULL, info BLOB);
      INSERT INTO metadb VALUES ('file://mac-volume://$(echo $META | tr 'A-F' 'a-f')/c.flac', NULL);"
}
entries() { sqlite3 "$1/config.sqlite" "SELECT count(*) FROM configStrings WHERE name LIKE 'mac.volume.%.originalPath';"; }
has() { sqlite3 "$1/config.sqlite" "SELECT count(*) FROM config$3 WHERE name LIKE 'mac.volume.$2.%';"; }

echo "=== 1. dry run decides correctly and changes nothing ==="
P="$T/p1"; mkprofile "$P"
OUT="$(FB2K_DIR="$P" FB2K_PROCESS=plorgnosuchproc "$SCRIPT" 2>&1)"; rc=$?
ck "exit 0" "$rc" "0"
ck "live-playlist UUID kept"          "$(echo "$OUT" | grep "$LIVE"  | grep -c 'keep - referenced')" "1"
ck "metadb-only UUID kept (any case)" "$(echo "$OUT" | grep "$META"  | grep -c 'keep - referenced')" "1"
ck "backup-only music-1 UUID removed" "$(echo "$OUT" | grep "$DEAD1" | grep -c 'REMOVE')" "1"
ck "/Volumes/Music (case) removed"    "$(echo "$OUT" | grep "$DEAD2" | grep -c 'REMOVE')" "1"
ck "LaCie not ours - kept"            "$(echo "$OUT" | grep "$LACIE" | grep -c 'not the music share')" "1"
ck "music-backup not ours - kept"     "$(echo "$OUT" | grep "$NEAR"  | grep -c 'not the music share')" "1"
ck "nothing written"                  "$(entries "$P")" "6"

echo "=== 2. --apply refused while foobar2000 runs ==="
P="$T/p2"; mkprofile "$P"
ln -s /bin/sleep "$T/plorgfakefb2k"; "$T/plorgfakefb2k" 5 >/dev/null 2>&1 & FAKE=$!
sleep 0.3
FB2K_DIR="$P" FB2K_PROCESS=plorgfakefb2k "$SCRIPT" --apply >/dev/null 2>&1; rc=$?
kill "$FAKE" 2>/dev/null; wait "$FAKE" 2>/dev/null
ck "exit 2" "$rc" "2"
ck "nothing written" "$(entries "$P")" "6"
ck "no backup made"  "$(ls "$P"/config.sqlite.plorg-prune-* 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "=== 3. --apply removes exactly the two, both tables, backs up ==="
P="$T/p3"; mkprofile "$P"
FB2K_DIR="$P" FB2K_PROCESS=plorgnosuchproc "$SCRIPT" --apply >/dev/null 2>&1; rc=$?
ck "exit 0" "$rc" "0"
ck "4 entries left"            "$(entries "$P")" "4"
ck "DEAD1 path gone"           "$(has "$P" "$DEAD1" Strings)" "0"
ck "DEAD1 bookmark gone"       "$(has "$P" "$DEAD1" Blobs)" "0"
ck "DEAD2 gone"                "$(has "$P" "$DEAD2" Strings)" "0"
ck "LIVE bookmark kept"        "$(has "$P" "$LIVE" Blobs)" "1"
ck "unrelated setting kept"    "$(sqlite3 "$P/config.sqlite" "SELECT value FROM configStrings WHERE name='unrelated.setting';")" "keep me"
ck "backup made"               "$(ls "$P"/config.sqlite.plorg-prune-* 2>/dev/null | wc -l | tr -d ' ')" "1"
ck "backup still has all 6"    "$(sqlite3 "$(ls "$P"/config.sqlite.plorg-prune-*)" "SELECT count(*) FROM configStrings WHERE name LIKE 'mac.volume.%.originalPath';")" "6"
ck "integrity"                 "$(sqlite3 "$P/config.sqlite" 'PRAGMA quick_check;')" "ok"

echo "=== 4. second --apply is a no-op ==="
OUT="$(FB2K_DIR="$P" FB2K_PROCESS=plorgnosuchproc "$SCRIPT" --apply 2>&1)"; rc=$?
ck "exit 0" "$rc" "0"
ck "says nothing to remove" "$(echo "$OUT" | grep -c 'Nothing to remove')" "1"

echo "=== 5. unreadable metadb -> refuse rather than decide on partial data ==="
P="$T/p5"; mkprofile "$P"; echo "not a database" > "$P/metadb.sqlite"
FB2K_DIR="$P" FB2K_PROCESS=plorgnosuchproc "$SCRIPT" --apply >/dev/null 2>&1; rc=$?
ck "exit 3" "$rc" "3"
ck "nothing written" "$(entries "$P")" "6"

echo "=== 6. a UUID only the Media Library watches is kept (2026-10-02) ==="
P="$T/p6"; mkprofile "$P"
mkdir -p "$P/library-v2.0/2C246EEC2C162256"
printf '\001\000\000\0002\000\000\000mac-volume://%s/\000\000\000\000' "$DEAD2" > "$P/library-v2.0/folders"
sqlite3 "$P/library-v2.0/2C246EEC2C162256/content.sqlite" "CREATE TABLE config (key TEXT UNIQUE PRIMARY KEY, value TEXT); INSERT INTO config VALUES ('rootPath','mac-volume://$NEAR/');"
OUT="$(FB2K_DIR="$P" FB2K_PROCESS=plorgnosuchproc "$SCRIPT" 2>&1)"
ck "library folder UUID kept"       "$(echo "$OUT" | grep "$DEAD2" | grep -c 'keep - referenced')" "1"
ck "dead music-1 UUID still removed" "$(echo "$OUT" | grep "$DEAD1" | grep -c 'REMOVE')" "1"

echo; printf ' RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
