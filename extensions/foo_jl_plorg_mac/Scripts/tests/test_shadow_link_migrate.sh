#!/bin/bash
# Runs shadow_link_migrate.py against synthetic foobar2000 profiles built by
# shadow_link_fixture.py. A fake pgrep on PATH stands in for running processes,
# and SHADOW_LINK_LIVE_PROFILE / SHADOW_LINK_MIGRATOR_DIRS keep the real
# profile and the real /tmp out of every case.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL="$HERE/../shadow_link_migrate.py"
FIXTURE="$HERE/shadow_link_fixture.py"
PY=/usr/bin/python3                       # the interpreter the tool must run on
T="$(mktemp -d -t plorgshadow)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ck() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  ok   $1"; else FAIL=$((FAIL+1)); echo "  FAIL $1: expected '$3', got '$2'"; fi; }
has() { printf '%s\n' "$1" | grep -cF -- "$2"; }

A=AAAAAAAA-1111-2222-3333-444444444444
B=BBBBBBBB-5555-6666-7777-888888888888
D=DDDDDDDD-9999-AAAA-BBBB-CCCCCCCCCCCC
E=EEEEEEEE-0000-1111-2222-333333333333
LINK="$T/home/Music/NAS/music"
MDROOT="$T/md root/Volumes.noindex/Srv/music"
FROM_A="mac-volume://$A/"
FROM_MD="file://$MDROOT/"
PL="file://$LINK/"
BPMT=metadb_index_4C2B7E91_0A36_4F58_B1D4_8E5A27C91F03
STATT=metadb_index_C653739F_14B3_4EF2_819B_A3E2883230AE
UNKT=metadb_index_11111111_2222_3333_4444_555555555555

mkdir -p "$T/bin" "$T/mig" "$T/home/Music/NAS" "$T/share"
ln -s "$T/share" "$LINK"
cat > "$T/bin/pgrep" <<'SH'
#!/bin/bash
# Stand-in for pgrep: "finds" a process when the last argument matches $FAKE_PGREP_MATCH.
last="${@: -1}"
if [ -n "${FAKE_PGREP_MATCH:-}" ] && [[ "$last" =~ $FAKE_PGREP_MATCH ]]; then echo 4242; exit 0; fi
exit 1
SH
chmod +x "$T/bin/pgrep"
"$PY" "$FIXTURE" "$T/base" "$T/exp" "$LINK" "$MDROOT" || { echo "fixture build failed"; exit 1; }

fresh() { rm -rf "$1"; cp -R "$T/base" "$1"; }
# tool PROFILE ARGS... ; LIVE=<dir treated as the live profile>, FAKE=<pgrep match>, FAILSWAP=<n>
tool() {
    local p="$1"; shift
    PATH="$T/bin:$PATH" FAKE_PGREP_MATCH="${FAKE:-}" SHADOW_LINK_LIVE_PROFILE="${LIVE:-$T/nolive}" \
        SHADOW_LINK_MIGRATOR_DIRS="$T/mig" SHADOW_LINK_TEST_FAIL_SWAP="${FAILSWAP:-}" \
        "$PY" "$TOOL" --profile "$p" "$@" 2>&1
}
migrate() { local p="$1" m="$2"; shift 2; tool "$p" "$m" --link "$LINK" --from "$FROM_A" --from "$FROM_MD" "$@"; }
q() { sqlite3 "$1/metadb.sqlite" "$2"; }
sorted() { LC_ALL=C sort; }
last() { printf '%s\n' "$1" | tail -1; }
backups() { ls -d "$1"/shadow-link-backup-* 2>/dev/null | wc -l | tr -d ' '; }
leftovers() { find "$1" -name '*shadow-link*' -not -path "$1/shadow-link-*" | wc -l | tr -d ' '; }

# treesum DIR [strict]: hash of names + contents. Default skips the tool's own
# shadow-link-* folders; strict covers everything and adds file and folder
# mtimes, so even a created-then-deleted temp file shows up.
treesum() {
    "$PY" - "$@" <<'PY'
import hashlib, os, sys
root, strict = sys.argv[1], len(sys.argv) > 2
h = hashlib.sha256()
for d, dirs, files in os.walk(root):
    dirs.sort()
    rel = os.path.relpath(d, root)
    if not strict and rel == ".":
        dirs[:] = [x for x in dirs if not x.startswith("shadow-link-")]
    h.update(("D %s %s\n" % (rel, os.stat(d).st_mtime_ns if strict else "")).encode())
    for f in sorted(files):
        p = os.path.join(d, f)
        with open(p, "rb") as fh:
            h.update(("F %s %s %s\n" % (os.path.join(rel, f), hashlib.sha256(fh.read()).hexdigest(),
                                        os.stat(p).st_mtime_ns if strict else "")).encode())
print(h.hexdigest())
PY
}

# Independent check of every unpack:// value: the archive span is everything up
# to the last '|' of its level (the inner names here hold no '|'), and its
# stored length must equal the span's length in UTF-8 bytes, which is how
# foobar2000 counts. Prints "<levels checked> <bad> <non-ASCII levels>".
unpack_counts() {
    "$PY" - "$1/metadb.sqlite" <<'PY'
import re, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
vals = [r[0] for r in db.execute("SELECT name FROM metadb")]
for (t,) in db.execute("SELECT name FROM sqlite_master WHERE type='table' "
                       "AND name GLOB 'metadb_index_*' AND NOT name GLOB '*_data'"):
    vals += [r[0] for r in db.execute('SELECT filename FROM "%s"' % t)]
n = bad = wide = 0
for v in vals:
    loc = v.split("+", 1)[1]
    while loc.startswith("unpack://"):
        m = re.match(r"unpack://[^|]*\|(\d+)\|", loc)
        rest = loc[m.end():]
        span = rest[:rest.rindex("|")]
        n += 1
        if int(m.group(1)) != len(span.encode("utf-8")):
            bad += 1
        if len(span) != len(span.encode("utf-8")):
            wide += 1
        loc = span
print(n, bad, wide)
PY
}

# BPM key computed with md5(1) and bash arithmetic, not Python.
bpm_key_sh() {
    local h lo="" hi="" i
    h=$(printf '%s' "$1" | /sbin/md5 -q)
    for i in 14 12 10 8 6 4 2 0; do lo+="${h:$i:2}"; done
    for i in 30 28 26 24 22 20 18 16; do hi+="${h:$i:2}"; done
    echo $(( 0x$lo ^ 0x$hi ))
}

echo "=== 1. dry run: plan, self-checks, nothing written ==="
P="$T/p1"; fresh "$P"
ORIG="$(treesum "$P")"; STRICT="$(treesum "$P" strict)"
OUT="$(migrate "$P" --dry-run)"; rc=$?
ck "exit 0" "$rc" "0"
ck "final OK line" "$(last "$OUT" | grep -c '^OK: dry run')" "1"
ck "playlist plan"  "$(has "$OUT" 'playlists: 3 scanned, 2 to change, 8 lines rewritten')" "1"
ck "metadb plan"    "$(has "$OUT" 'metadb: 18 rows, 14 under --from (9 direct, 5 archive): rewrite 12, conflicts 2')" "1"
ck "BPM plan"       "$(has "$OUT" 're-key 11 rows; grids: 10 stored, move 7, keep 1 in place')" "1"
ck "BPM formula verified on every row" "$(has "$OUT" 'key formula verified on 15 of 15 rows')" "1"
ck "archive self-check" "$(has "$OUT" 'archive self-check: 5 rewritten rows ok')" "2"
ck "unknown index reported" "$(has "$OUT" 'index 11111111-2222-3333-4444-555555555555 (unknown index)')" "1"
ck "every conflict listed" "$(has "$OUT" 'conflicts: 7')" "1"
ck "tie conflict explained" "$(has "$OUT" 'same file under an earlier --from kept')" "3"
ck "tree untouched (contents + mtimes)" "$(treesum "$P" strict)" "$STRICT"

echo "=== 2. apply (copy profile, foobar2000 'running' elsewhere) ==="
OUT="$(FAKE='^foobar2000$' migrate "$P" --apply)"; rc=$?
ck "exit 0" "$rc" "0"
ck "final OK line" "$(last "$OUT" | grep -c '^OK: migrated 8 playlist lines, 43 metadb values')" "1"
for f in aaa bbb ccc; do
    cmp -s "$P/playlists-v2.0/playlist-$f.fplite" "$T/exp/playlists/playlist-$f.fplite"; ck "playlist-$f as expected (BOM, endings, other lines)" "$?" "0"
done
ck "BOM kept" "$(head -c 3 "$P/playlists-v2.0/playlist-aaa.fplite" | xxd -p)" "efbbbf"
ck "CRLF kept" "$(grep -c $'\r$' "$P/playlists-v2.0/playlist-ccc.fplite")" "3"
cmp -s "$P/playlists-v2.0/backup_volume_sync_2026-01-01_000000/playlist-aaa.fplite" \
       "$T/base/playlists-v2.0/backup_volume_sync_2026-01-01_000000/playlist-aaa.fplite"; ck "sub-folder playlist untouched" "$?" "0"
cmp -s "$P/playlists-v2.0/index.txt" "$T/base/playlists-v2.0/index.txt"; ck "index.txt untouched" "$?" "0"
ck "metadb names" "$(q "$P" 'SELECT name FROM metadb' | sorted)" "$(sorted < "$T/exp/metadb_names.txt")"
ck "play-stats rows: filenames rewritten, keys kept" \
   "$(q "$P" "SELECT key||'|'||filename FROM $STATT" | sorted)" "$(sorted < "$T/exp/stats_rows.txt")"
ck "play-stats data untouched" "$(q "$P" "SELECT key, hex(value) FROM ${STATT}_data ORDER BY key")" \
   "$(q "$T/base" "SELECT key, hex(value) FROM ${STATT}_data ORDER BY key")"
ck "BPM rows re-keyed" "$(q "$P" "SELECT key||'|'||filename FROM $BPMT" | sorted)" "$(sorted < "$T/exp/bpm_rows.txt")"
ck "BPM grids moved / kept" "$(q "$P" "SELECT key||'|'||lower(hex(value)) FROM ${BPMT}_data" | sorted)" \
   "$(sorted < "$T/exp/bpm_data.txt")"
ck "unknown index: filenames rewritten, keys kept" \
   "$(q "$P" "SELECT key||'|'||filename FROM $UNKT" | sorted)" "$(sorted < "$T/exp/unknown_rows.txt")"
ck "unknown index data untouched" "$(q "$P" "SELECT count(*) FROM ${UNKT}_data")" "3"
ck "unpack counts = UTF-8 bytes, every level (9 non-ASCII)" "$(unpack_counts "$P")" "20 0 9"
span="${PL}music.local/Dvořák/Šárka.rar"; loc="unpack://rar|$(printf '%s' "$span" | wc -c | tr -d ' ')|$span|(04) Píseň.flac"
ck "non-ASCII archive path: byte count (wc -c)" "$(q "$P" "SELECT count(*) FROM metadb WHERE name='0+$loc'")" "1"
ck "non-ASCII archive path: grid at its new key (md5 in bash)" \
   "$(q "$P" "SELECT value FROM ${BPMT}_data WHERE key=$(bpm_key_sh "$loc|0")")" "grid-rar_cz"
inner="${PL}music.local/Žluťoučký kůň/outer.zip"
mid="unpack://zip|$(printf '%s' "$inner" | wc -c | tr -d ' ')|$inner|vnitřní.rar"
loc="unpack://rar|$(printf '%s' "$mid" | wc -c | tr -d ' ')|$mid|(05) Hluboko.flac"
ck "nested non-ASCII archive paths: byte counts (wc -c)" "$(q "$P" "SELECT count(*) FROM $STATT WHERE filename='0+$loc'")" "1"
loc="${PL}music.hq/Artist/one.flac"
ck "BPM key of one.flac (md5 in bash)" "$(q "$P" "SELECT key FROM $BPMT WHERE filename='0+$loc'")" "$(bpm_key_sh "$loc|0")"
loc="${PL}music.hq/Artist/both.flac"
ck "tie loser's grid moved into the winner's empty key" \
   "$(q "$P" "SELECT value FROM ${BPMT}_data WHERE key=$(bpm_key_sh "$loc|0")")" "grid-both_md"
ck "row data kept on rename" "$(q "$P" "SELECT info FROM metadb WHERE name='0+${PL}music.hq/Artist/one.flac'")" "info-one"
ck "metadb config table untouched" "$(q "$P" "SELECT key||'='||value FROM config ORDER BY key" | tr '\n' ' ')" "uniNormFix=1 version=3 "
ck "integrity" "$(q "$P" 'PRAGMA integrity_check;')" "ok"
cmp -s "$P/config.sqlite" "$T/base/config.sqlite"; ck "config.sqlite never written" "$?" "0"
cmp -s "$P/library-v2.0/folders" "$T/exp/folders"; ck "folders: one link root, trailing bytes kept" "$?" "0"
cmp -s "$P/library-v2.0/0123456789ABCDEF/content.sqlite" "$T/base/library-v2.0/0123456789ABCDEF/content.sqlite"; ck "library dir untouched" "$?" "0"
ck "one backup" "$(backups "$P")" "1"
B1="$(ls -d "$P"/shadow-link-backup-*)"
cmp -s "$B1/metadb.sqlite" "$T/base/metadb.sqlite"; ck "backup metadb = original" "$?" "0"
ck "backup holds playlists, config, library, manifest" \
   "$(ls "$B1/playlists-v2.0" | tr '\n' ' ')$(ls "$B1" | tr '\n' ' ')" \
   "playlist-aaa.fplite playlist-bbb.fplite playlist-ccc.fplite config.sqlite library-v2.0 manifest.json metadb.sqlite playlists-v2.0 "
ck "no staged leftovers" "$(leftovers "$P")" "0"

echo "=== 3. second apply finds nothing ==="
OUT="$(migrate "$P" --apply)"; rc=$?
ck "exit 0" "$rc" "0"
ck "nothing to change" "$(last "$OUT")" "OK: nothing to change"
ck "no second backup" "$(backups "$P")" "1"

echo "=== 4. --check: clean, then drift under the <share>/<share>-N rule ==="
OUT="$(tool "$P" --check --link "$LINK" --share-name music)"; rc=$?
ck "clean: exit 0" "$rc" "0"
ck "clean: OK" "$(last "$OUT")" "OK: no drift"
ck "share IDs from the registry (music-1, Music; not music-backup, music/sub)" \
   "$(has "$OUT" "share 'music': $A (/Volumes/music-1), $D (/Volumes/Music)")" "1"
DL="$(echo "$D" | tr 'A-F' 'a-f')"
q "$P" "INSERT INTO metadb (name) VALUES ('0+mac-volume://$D/music.hq/new.flac'),
        ('0+mac-volume://$DL/music.hq/new2.flac'), ('0+mac-volume://$E/x.flac');"
printf 'mac-volume://%s/music.hq/new.flac\n' "$D" >> "$P/playlists-v2.0/playlist-bbb.fplite"
OUT="$(tool "$P" --check --link "$LINK" --share-name music)"; rc=$?
ck "drift: exit 1" "$rc" "1"
ck "drift counted (any UUID case)" "$(has "$OUT" "drift under mac-volume://$D/: playlist lines 1, metadb rows 2,")" "1"
ck "drift playlist named" "$(has "$OUT" "playlists: playlist-bbb.fplite")" "1"
ck "not-ours volume not drift" "$(has "$OUT" "drift under mac-volume://$E/")" "0"
ck "FAILED line suggests the fold" "$(last "$OUT" | grep -c "^FAILED: drift found: 3 values under 1 prefix.*--from 'mac-volume://$D/'")" "1"

echo "=== 5. rollback restores byte-identical files ==="
OUT="$(tool "$P" --rollback "$B1")"; rc=$?
ck "exit 0" "$rc" "0"
ck "final OK line" "$(last "$OUT" | grep -c '^OK: rolled back')" "1"
ck "profile = pre-apply state" "$(treesum "$P")" "$ORIG"
ASIDE="$(ls -d "$P"/shadow-link-pre-rollback-* 2>/dev/null)"
ck "replaced files kept aside" "$(sqlite3 "$ASIDE/metadb.sqlite" "SELECT count(*) FROM metadb WHERE name LIKE '%new.flac'")" "1"
ck "no staged leftovers" "$(leftovers "$P")" "0"

echo "=== 6. a failed swap step restores every item from the backup ==="
P="$T/p2"; fresh "$P"
OUT="$(FAILSWAP=3 migrate "$P" --apply)"; rc=$?
ck "exit 1" "$rc" "1"
ck "FAILED, all restored" "$(last "$OUT")" "FAILED: swap failed; all 4 items restored from the backup, byte-identical"
ck "profile byte-identical to before" "$(treesum "$P")" "$ORIG"
ck "no staged leftovers" "$(leftovers "$P")" "0"
ck "backup kept" "$(backups "$P")" "1"

echo "=== 7. a failed rollback swap is undone ==="
P="$T/p3"; fresh "$P"
migrate "$P" --apply >/dev/null; B3="$(ls -d "$P"/shadow-link-backup-*)"
POST="$(treesum "$P")"
OUT="$(FAILSWAP=2 tool "$P" --rollback "$B3")"; rc=$?
ck "exit 1" "$rc" "1"
ck "FAILED, undone" "$(last "$OUT")" "FAILED: rollback swap failed; the profile is as it was before the rollback"
ck "profile = post-apply state" "$(treesum "$P")" "$POST"
ck "no staged leftovers" "$(leftovers "$P")" "0"
OUT="$(tool "$P" --rollback "$B3")"; rc=$?
ck "retry succeeds" "$rc" "0"
ck "profile = pre-apply state" "$(treesum "$P")" "$ORIG"

echo "=== 8. live profile: refused while foobar2000 runs ==="
P="$T/p4"; fresh "$P"; STRICT="$(treesum "$P" strict)"
OUT="$(LIVE="$P" FAKE='^foobar2000$' migrate "$P" --apply)"; rc=$?
ck "apply exit 1" "$rc" "1"
ck "says why" "$(last "$OUT" | grep -c 'foobar2000 is running')" "1"
ln -s "$P" "$T/p4link"
OUT="$(LIVE="$P" FAKE='^foobar2000$' migrate "$T/p4link" --apply)"; rc=$?
ck "same profile by another path: refused" "$(last "$OUT" | grep -c 'foobar2000 is running')" "1"
OUT="$(LIVE="$P" FAKE='^foobar2000$' tool "$P" --rollback "$B3")"; rc=$?
ck "rollback refused too" "$(last "$OUT" | grep -c 'rollback refused: foobar2000 is running')" "1"
OUT="$(LIVE="$P" FAKE='^foobar2000$' migrate "$P" --dry-run)"; rc=$?
ck "dry run still allowed, with a note" "$rc|$(has "$OUT" 'note: --apply would refuse: foobar2000 is running')" "0|1"
ck "nothing written" "$(treesum "$P" strict)" "$STRICT"

echo "=== 9. refused while plorg's migrator is pending or running ==="
touch "$T/mig/plorg_metadb_migration_4242.sql"
OUT="$(LIVE="$P" migrate "$P" --apply)"; rc=$?
ck "staged SQL: exit 1" "$rc" "1"
ck "staged SQL: says why" "$(last "$OUT" | grep -c "migrator is pending or running (staged migration SQL")" "1"
OUT="$(migrate "$P" --dry-run)"
ck "other profile: only a note" "$(has "$OUT" "note: plorg's metadb migrator is pending for the live profile")" "1"
rm -f "$T/mig/plorg_metadb_migration_4242.sql"
OUT="$(LIVE="$P" FAKE='plorg_metadb_migration_' migrate "$P" --apply)"; rc=$?
ck "migrator process: refused" "$rc|$(last "$OUT" | grep -c 'migrator process(es) running')" "1|1"
ck "nothing written" "$(treesum "$P" strict)" "$STRICT"
touch "$P/metadb.sqlite.plorg-work"
OUT="$(migrate "$P" --apply)"; rc=$?
ck "migrator work file in the profile: refused" "$rc|$(last "$OUT" | grep -c 'plorg-work exists')" "1|1"
rm -f "$P/metadb.sqlite.plorg-work"

echo "=== 10. non-empty WAL refused ==="
printf 'x' > "$P/metadb.sqlite-wal"
OUT="$(migrate "$P" --apply)"; rc=$?
ck "exit 1" "$rc|$(last "$OUT" | grep -c 'metadb.sqlite-wal is not empty')" "1|1"
ck "no backup made" "$(backups "$P")" "0"
rm -f "$P/metadb.sqlite-wal"

echo "=== 11. malformed folders file refused ==="
P="$T/p5"; fresh "$P"; printf '\0' >> "$P/library-v2.0/folders"; STRICT="$(treesum "$P" strict)"
OUT="$(migrate "$P" --dry-run)"; rc=$?
ck "dry run exit 1" "$rc|$(last "$OUT" | grep -c 'does not have the expected layout (5 bytes after the entries')" "1|1"
OUT="$(migrate "$P" --apply)"; rc=$?
ck "apply exit 1" "$rc" "1"
ck "nothing written" "$(treesum "$P" strict)" "$STRICT"

echo "=== 12. BPM formula mismatch aborts ==="
P="$T/p6"; fresh "$P"
q "$P" "UPDATE $BPMT SET key = key + 1 WHERE filename LIKE '%/one.flac'"
OUT="$(migrate "$P" --dry-run)"; rc=$?
ck "exit 1, says why" "$rc|$(last "$OUT" | grep -c 'does not match the path-hash formula')" "1|1"

echo "=== 13. unpack self-check ==="
P="$T/p7"; fresh "$P"
span="mac-volume://$A/music.local/x/__prep.rar"; n=${#span}
q "$P" "UPDATE metadb SET name = replace(name, 'rar|$n|', 'rar|$((n + 1))|') WHERE name LIKE '%(02) Track.flac'"
OUT="$(migrate "$P" --dry-run)"; rc=$?
ck "wrong length: exit 1" "$rc|$(last "$OUT" | grep -c 'unpack self-check failed .* does not end on a')" "1|1"
# A length that fits only when counted in characters (non-ASCII archive path):
# foobar2000 counts bytes, so such a row is malformed.
chars() { "$PY" -c 'import sys; print(len(sys.argv[1]))' "$1"; }
P="$T/p8"; fresh "$P"
other="mac-volume://$B/Dvořák/a.rar"
q "$P" "INSERT INTO metadb (name) VALUES ('0+unpack://rar|$(chars "$other")|$other|t.flac')"
OUT="$(migrate "$P" --dry-run)"; rc=$?
ck "character count outside --from: warning only" "$rc|$(has "$OUT" 'warning: 1 archive rows outside the --from prefixes')" "0|1"
mine="mac-volume://$A/music.local/Dvořák/a.rar"
q "$P" "INSERT INTO metadb (name) VALUES ('0+unpack://rar|$(chars "$mine")|$mine|t.flac')"
OUT="$(migrate "$P" --dry-run)"; rc=$?
ck "character count under --from: refused" "$rc|$(last "$OUT" | grep -c 'fits only when counted as characters, but foobar2000 counts UTF-8 bytes')" "1|1"

echo "=== 14. WAL-mode metadb (empty -wal/-shm left behind, as macOS SQLite does) ==="
mkwal() { fresh "$1"; "$PY" -c "import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.execute('PRAGMA journal_mode=wal'); c.execute('PRAGMA wal_checkpoint(TRUNCATE)'); c.close()" "$1/metadb.sqlite"; }
P="$T/p9"; mkwal "$P"; WALORIG="$(treesum "$P")"
OUT="$(FAILSWAP=2 migrate "$P" --apply)"; rc=$?
ck "failed swap at the sidecar step: exit 1" "$rc" "1"
ck "restored byte-identical, sidecars included" "$(treesum "$P")" "$WALORIG"
rm -rf "$P"/shadow-link-backup-*
OUT="$(migrate "$P" --apply)"; rc=$?
ck "apply exit 0" "$rc" "0"
ck "old sidecars gone, no staged leftovers" "$(ls "$P" | grep -c 'metadb.sqlite-')|$(leftovers "$P")" "0|0"
ck "backup has the sidecars" "$(ls "$P"/shadow-link-backup-*/ | grep -c 'metadb.sqlite-')" "2"
ck "still WAL mode" "$(xxd -s 18 -l 2 -p "$P/metadb.sqlite")" "0202"
ck "metadb names" "$(q "$P" 'SELECT name FROM metadb' | sorted)" "$(sorted < "$T/exp/metadb_names.txt")"
P="$T/p10"; mkwal "$P"; rm -f "$P/metadb.sqlite-wal" "$P/metadb.sqlite-shm"
OUT="$(migrate "$P" --apply)"; rc=$?
ck "WAL database without sidecars: apply exit 0" "$rc" "0"

echo "=== 15. argument checks ==="
OUT="$(tool "$T/p1" --dry-run --link "$LINK" --from "mac-volume://$A")"; rc=$?
ck "prefix without trailing slash refused" "$rc|$(last "$OUT" | grep -c 'must be mac-volume')" "1|1"
OUT="$(tool "$T/p1" --dry-run --link "$LINK" --from "file://$T/home/")"; rc=$?
ck "prefix overlapping the link refused" "$rc|$(last "$OUT" | grep -c 'overlaps the link')" "1|1"
tool "$T/p1" --apply --link "$LINK" >/dev/null; rc=$?
ck "missing --from is a usage error" "$rc" "2"

echo; printf ' RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
