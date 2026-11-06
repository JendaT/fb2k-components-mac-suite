#!/bin/bash
# Renders the migrator shell script straight out of VolumeSyncService.mm and runs
# it against synthetic databases. Rendering from source (rather than keeping a
# copy here) is deliberate: a hand-copied duplicate drifts, and two runtime-only
# defects have already escaped a `bash -n` check - `declare -A` on bash 3.2, and
# a trailing && that made the script exit non-zero on success.
set -u
SRC="${1:-src/Core/VolumeSyncService.mm}"
T="$(mktemp -d -t plorgmig)"
PASS=0; FAIL=0
ck() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  ok   $1"; else FAIL=$((FAIL+1)); echo "  FAIL $1: expected '$3', got '$2'"; fi; }

render() { # render <db> <sql> <log> <mark> <pid> <abortwait>
  python3 - "$SRC" "$1" "$2" "$3" "$4" "$5" "$6" <<'PY'
import sys, re
src, db, sql, log, mark, pid, aw = sys.argv[1:8]
t = open(src).read()
i = t.index('NSString *script = [NSString stringWithFormat:')
j = t.index('        dbPath, sqlPath, logPath, markerPath, appPath, appPath,', i)
body = t[i:j]
lines = re.findall(r'^\s*@"(.*)"\s*,?\s*$', body, re.M)
out = []
for L in lines:
    L = L.replace('\\"', '"').replace('\\\\', '\\')
    if L.endswith('\\n'): L = L[:-2]
    out.append(L)
s = '\n'.join(out) + '\n'
for val in (db, sql, log, mark, '', ''):      # %@ x6: DB SQL LOG MARK APP APP
    s = s.replace('%@', val, 1)
for val in (pid, aw, '20'):                    # %d x3: PID ABORTWAIT VACUUM_PCT
    s = s.replace('%d', val, 1)
s = s.replace('%%', '%')
# TEST SEAM: a developer machine usually has the real foobar2000 running,
# which would match `pgrep -x foobar2000` and send every case down the
# abort path. Watch for a stand-in process name instead.
s = s.replace('pgrep -x foobar2000', 'pgrep -x plorgfaketest')
sys.stdout.write(s)
PY
}

mkdb() { # mkdb <path> <nrows>
  rm -f "$1" "$1-wal" "$1-shm"
  sqlite3 "$1" <<SQL
CREATE TABLE metadb (name TEXT UNIQUE PRIMARY KEY NOT NULL, info BLOB, infoBrowse BLOB, size INTEGER, lastModified INTEGER, infoBrowseTime INTEGER, lastseen INTEGER, created INTEGER, attribs INTEGER, attribsValid INTEGER, partial INTEGER NOT NULL DEFAULT 0);
CREATE TABLE "metadb_index_C653739F_14B3_4EF2_819B_A3E2883230AE" (key INTEGER NOT NULL, filename TEXT NOT NULL UNIQUE PRIMARY KEY);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i < $2)
INSERT INTO metadb (name, info, size) SELECT 'mac-volume://OLDOLDOLD-0000-0000-0000-000000000000/t'||i, randomblob(300), i FROM c;
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i < $2)
INSERT INTO "metadb_index_C653739F_14B3_4EF2_819B_A3E2883230AE" (key, filename) SELECT i, 'mac-volume://OLDOLDOLD-0000-0000-0000-000000000000/t'||i FROM c;
-- a row already cached under the LIVE uuid, colliding with migrated t1
INSERT INTO metadb (name, info, size) VALUES ('mac-volume://NEWNEWNE-1111-1111-1111-111111111111/t1', x'DEADBEEF', 999);
SQL
}

mksql() { # mksql <path> [slow]
  cat > "$1" <<SQL
PRAGMA busy_timeout=10000;
BEGIN IMMEDIATE;
$([ "${2:-}" = slow ] && echo "WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i<15000000) SELECT count(*) FROM c;")
UPDATE OR IGNORE metadb SET name = REPLACE(name, 'mac-volume://OLDOLDOLD-0000-0000-0000-000000000000', 'mac-volume://NEWNEWNE-1111-1111-1111-111111111111') WHERE name LIKE '%mac-volume://OLDOLDOLD-0000-0000-0000-000000000000/%';
DELETE FROM metadb WHERE name LIKE '%mac-volume://OLDOLDOLD-0000-0000-0000-000000000000/%' AND REPLACE(name, 'mac-volume://OLDOLDOLD-0000-0000-0000-000000000000', 'mac-volume://NEWNEWNE-1111-1111-1111-111111111111') <> name;
UPDATE OR IGNORE "metadb_index_C653739F_14B3_4EF2_819B_A3E2883230AE" SET filename = REPLACE(filename, 'mac-volume://OLDOLDOLD-0000-0000-0000-000000000000', 'mac-volume://NEWNEWNE-1111-1111-1111-111111111111') WHERE filename LIKE '%mac-volume://OLDOLDOLD-0000-0000-0000-000000000000/%';
DELETE FROM "metadb_index_C653739F_14B3_4EF2_819B_A3E2883230AE" WHERE filename LIKE '%mac-volume://OLDOLDOLD-0000-0000-0000-000000000000/%' AND REPLACE(filename, 'mac-volume://OLDOLDOLD-0000-0000-0000-000000000000', 'mac-volume://NEWNEWNE-1111-1111-1111-111111111111') <> filename;
COMMIT;
SQL
}

# A process actually named foobar2000, so `pgrep -x foobar2000` sees it.
FAKEDIR="$T/fake"; mkdir -p "$FAKEDIR"; ln -s /bin/sleep "$FAKEDIR/plorgfaketest"   # symlink: a COPY of a system binary will not exec
# NOTE: the background process must not inherit the caller's stdout - inside a
# command substitution it would hold the pipe open and block the caller until
# it exited, so the stand-in was already gone by the time the script ran.
start_fake() { "$FAKEDIR/plorgfaketest" "$1" >/dev/null 2>&1 & echo $!; }

echo "=============================================================="
echo " TEST 1: happy path - migrate the copy, swap it in"
echo "=============================================================="
DB="$T/metadb.sqlite"; mkdb "$DB" 3000; mksql "$T/m.sql"
BEFORE_SUM=$(sqlite3 "$DB" "SELECT count(*) FROM metadb;")
sleep 2 & GONE=$!
touch "$T/mark"
render "$DB" "$T/m.sql" "$T/m.log" "$T/mark" "$GONE" 120 > "$T/s1.sh"
bash "$T/s1.sh"; ck "exit status" "$?" "0"
ck "rows migrated to NEW" "$(sqlite3 "$DB" "SELECT count(*) FROM metadb WHERE name LIKE '%NEWNEWNE%';")" "3000"
ck "no rows left on OLD" "$(sqlite3 "$DB" "SELECT count(*) FROM metadb WHERE name LIKE '%OLDOLDOLD%';")" "0"
ck "pre-existing live row NOT clobbered" "$(sqlite3 "$DB" "SELECT hex(info) FROM metadb WHERE name='mac-volume://NEWNEWNE-1111-1111-1111-111111111111/t1';")" "DEADBEEF"
ck "one collision absorbed, nothing else lost" "$(sqlite3 "$DB" 'SELECT count(*) FROM metadb;')" "$((BEFORE_SUM - 1))"
ck "index table migrated" "$(sqlite3 "$DB" "SELECT count(*) FROM \"metadb_index_C653739F_14B3_4EF2_819B_A3E2883230AE\" WHERE filename LIKE '%NEWNEWNE%';")" "3000"
ck "integrity" "$(sqlite3 "$DB" 'PRAGMA quick_check;')" "ok"
ck "work file cleaned up" "$([ -e "$DB.plorg-work" ] && echo yes || echo no)" "no"
ck "prev file cleaned up" "$([ -e "$DB.plorg-prev" ] && echo yes || echo no)" "no"
ck "staged SQL consumed" "$([ -e "$T/m.sql" ] && echo yes || echo no)" "no"
ck "relaunch marker consumed" "$([ -e "$T/mark" ] && echo yes || echo no)" "no"
ck "log reports the swap" "$(grep -c 'Swap complete and verified' "$T/m.log")" "1"

echo
echo "=============================================================="
echo " TEST 2: fb2k already running before the migration starts"
echo "=============================================================="
DB2="$T/db2.sqlite"; mkdb "$DB2" 100; mksql "$T/m2.sql"
sleep 1 & GONE2=$!
FAKE=$(start_fake 6)
touch "$T/mark2"
render "$DB2" "$T/m2.sql" "$T/m2.log" "$T/mark2" "$GONE2" 3 > "$T/s2.sh"
bash "$T/s2.sh"; ck "exit status" "$?" "0"
ck "live DB untouched (still on OLD)" "$(sqlite3 "$DB2" "SELECT count(*) FROM metadb WHERE name LIKE '%OLDOLDOLD%';")" "100"
ck "log says skipped" "$(grep -c 'Migration SKIPPED' "$T/m2.log")" "1"
ck "no work file left" "$([ -e "$DB2.plorg-work" ] && echo yes || echo no)" "no"
kill "$FAKE" 2>/dev/null; wait "$FAKE" 2>/dev/null

echo
echo "=============================================================="
echo " TEST 3: fb2k reopens DURING the copy migration (the 08-27 crash)"
echo "=============================================================="
DB3="$T/db3.sqlite"; mkdb "$DB3" 12000; mksql "$T/m3.sql" slow
sleep 1 & GONE3=$!
touch "$T/mark3"
render "$DB3" "$T/m3.sql" "$T/m3.log" "$T/mark3" "$GONE3" 120 > "$T/s3.sh"
# as soon as the working copy appears, launch a real foobar2000-named process
( n=0; while [ ! -e "$DB3.plorg-work" ] && [ $n -lt 400 ]; do sleep 0.05; n=$((n+1)); done; "$FAKEDIR/plorgfaketest" 8 & echo $! > "$T/f3.pid" ) &
RACE=$!
bash "$T/s3.sh"; ck "exit status" "$?" "0"
wait "$RACE" 2>/dev/null
ck "live DB untouched (still on OLD)" "$(sqlite3 "$DB3" "SELECT count(*) FROM metadb WHERE name LIKE '%OLDOLDOLD%';")" "12000"
ck "live DB still readable" "$(sqlite3 "$DB3" 'PRAGMA quick_check;')" "ok"
ck "log says swap skipped" "$(grep -c 'Swap SKIPPED' "$T/m3.log")" "1"
ck "work copy discarded" "$([ -e "$DB3.plorg-work" ] && echo yes || echo no)" "no"
ck "original never renamed away" "$([ -e "$DB3.plorg-prev" ] && echo yes || echo no)" "no"
[ -f "$T/f3.pid" ] && { kill "$(cat "$T/f3.pid")" 2>/dev/null; wait "$(cat "$T/f3.pid")" 2>/dev/null; }

echo
echo "=============================================================="
echo " TEST 4: live DB changes while the copy is migrating"
echo "=============================================================="
DB4="$T/db4.sqlite"; mkdb "$DB4" 12000; mksql "$T/m4.sql" slow
sleep 1 & GONE4=$!
touch "$T/mark4"
render "$DB4" "$T/m4.sql" "$T/m4.log" "$T/mark4" "$GONE4" 120 > "$T/s4.sh"
( n=0; while [ ! -e "$DB4.plorg-work" ] && [ $n -lt 400 ]; do sleep 0.05; n=$((n+1)); done; sleep 0.2; printf 'x' >> "$DB4" ) &
RACE4=$!
bash "$T/s4.sh"; ck "exit status" "$?" "0"
wait "$RACE4" 2>/dev/null
ck "log says swap skipped" "$(grep -c 'Swap SKIPPED' "$T/m4.log")" "1"
ck "work copy discarded" "$([ -e "$DB4.plorg-work" ] && echo yes || echo no)" "no"

echo
echo "=============================================================="
echo " TEST 5: not enough disk to stage a copy is a clean skip"
echo "=============================================================="
DB5="$T/db5.sqlite"; mkdb "$DB5" 100; mksql "$T/m5.sql"
sleep 1 & GONE5=$!
render "$DB5" "$T/m5.sql" "$T/m5.log" "$T/nomark5" "$GONE5" 120 \
  | sed 's|^avail=.*|avail=1|' > "$T/s5.sh"
bash "$T/s5.sh"; ck "exit status" "$?" "0"
ck "live DB untouched" "$(sqlite3 "$DB5" "SELECT count(*) FROM metadb WHERE name LIKE '%OLDOLDOLD%';")" "100"
ck "log says skipped for space" "$(grep -c 'free to stage a copy' "$T/m5.log")" "1"

echo
echo "=============================================================="
echo " TEST 6: a bloated copy is compacted before the swap"
echo "=============================================================="
DB6="$T/db6.sqlite"; mkdb "$DB6" 6000; mksql "$T/m6.sql"
# Manufacture free pages the way the old copy-then-delete scheme left them behind.
sqlite3 "$DB6" "CREATE TABLE ballast (k INTEGER PRIMARY KEY, v BLOB);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i<6000)
INSERT INTO ballast SELECT i, randomblob(2000) FROM c;
DELETE FROM ballast;"
PC=$(sqlite3 "$DB6" 'PRAGMA page_count;'); FL=$(sqlite3 "$DB6" 'PRAGMA freelist_count;')
ck "fixture really is bloated (>=20% free)" "$([ "$((FL*100/PC))" -ge 20 ] && echo yes || echo no)" "yes"
SIZE_BEFORE=$(stat -f%z "$DB6")
sleep 1 & GONE6=$!
touch "$T/mark6"
render "$DB6" "$T/m6.sql" "$T/m6.log" "$T/mark6" "$GONE6" 120 > "$T/s6.sh"
bash "$T/s6.sh"; ck "exit status" "$?" "0"
ck "log reports compaction" "$(grep -c 'Compacted the working copy' "$T/m6.log")" "1"
ck "file actually shrank" "$([ "$(stat -f%z "$DB6")" -lt "$SIZE_BEFORE" ] && echo yes || echo no)" "yes"
ck "free pages reclaimed" "$([ "$(sqlite3 "$DB6" 'PRAGMA freelist_count;')" -lt "$FL" ] && echo yes || echo no)" "yes"
ck "rows still migrated" "$(sqlite3 "$DB6" "SELECT count(*) FROM metadb WHERE name LIKE '%NEWNEWNE%';")" "6000"
ck "integrity" "$(sqlite3 "$DB6" 'PRAGMA quick_check;')" "ok"

echo
echo "=============================================================="
echo " TEST 7: a healthy copy is NOT vacuumed (no pointless churn)"
echo "=============================================================="
DB7="$T/db7.sqlite"; mkdb "$DB7" 2000; mksql "$T/m7.sql"
sleep 1 & GONE7=$!
render "$DB7" "$T/m7.sql" "$T/m7.log" "$T/nomark7" "$GONE7" 120 > "$T/s7.sh"
bash "$T/s7.sh"; ck "exit status" "$?" "0"
ck "no compaction attempted" "$(grep -c 'Compacted the working copy' "$T/m7.log")" "0"
ck "rows still migrated" "$(sqlite3 "$DB7" "SELECT count(*) FROM metadb WHERE name LIKE '%NEWNEWNE%';")" "2000"

echo
echo "=============================================================="
printf ' RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "=============================================================="
rm -rf "$T"
[ "$FAIL" -eq 0 ]
