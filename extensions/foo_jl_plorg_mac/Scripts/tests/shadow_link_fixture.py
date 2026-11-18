#!/usr/bin/env python3
"""Builds a synthetic foobar2000 profile for test_shadow_link_migrate.sh, plus
the files the migration is expected to produce.

Usage: shadow_link_fixture.py PROFILE EXPECTED LINK MD_ROOT

The expected values are written out explicitly from the records below, and
the BPM keys use a separate formulation of the hash (int.from_bytes), so the
test does not compare the tool against its own code.
"""
import hashlib
import os
import sqlite3
import struct
import sys

PROFILE, EXPECTED, LINK, MD_ROOT = sys.argv[1:5]

A = "AAAAAAAA-1111-2222-3333-444444444444"   # the share, registry /Volumes/music-1
B = "BBBBBBBB-5555-6666-7777-888888888888"   # another volume, /Volumes/LaCie
D = "DDDDDDDD-9999-AAAA-BBBB-CCCCCCCCCCCC"   # the share again, /Volumes/music (drift)
E = "EEEEEEEE-0000-1111-2222-333333333333"   # /Volumes/music-backup: not the share
F = "FFFFFFFF-0000-1111-2222-333333333333"   # /Volumes/music/sub: not the share
UNKNOWN = "11111111-2222-3333-4444-555555555555"
BPM = "4C2B7E91-0A36-4F58-B1D4-8E5A27C91F03"
STATS = "C653739F-14B3-4EF2-819B-A3E2883230AE"

PA = "mac-volume://%s/" % A
PA_LOWER = "mac-volume://%s/" % A.lower()
PMD = "file://%s/" % MD_ROOT
PL = "file://%s/" % LINK
PB = "mac-volume://%s/" % B


def unpack(typ, span, rest):
    """foobar2000 counts the archive span in UTF-8 bytes."""
    return "unpack://%s|%d|%s|%s" % (typ, len(span.encode("utf-8")), span, rest)


def key_of(location, subsong):
    d = hashlib.md5(("%s|%d" % (location, subsong)).encode("utf-8")).digest()
    v = int.from_bytes(d[:8], "little") ^ int.from_bytes(d[8:], "little")
    return v - (1 << 64) if v >= (1 << 63) else v


def nested(prefix):
    inner = unpack("zip", prefix + "music.local/y/outer.zip", "inner.rar")
    return unpack("rar", inner, "(01) Deep.flac")


def nested_cz(prefix):
    inner = unpack("zip", prefix + "music.local/Žluťoučký kůň/outer.zip", "vnitřní.rar")
    return unpack("rar", inner, "(05) Hluboko.flac")


# (label, subsong, old location, new location or None (unchanged), fate)
# fate: "rename", "keep", "delete" (conflict: an existing link row wins), "tie"
# (conflict: the same file under the earlier --from wins)
REC = [
    ("one", 0, PA + "music.hq/Artist/one.flac", PL + "music.hq/Artist/one.flac", "rename"),
    ("cue1", 1, PA + "music.hq/Artist/cue.flac", PL + "music.hq/Artist/cue.flac", "rename"),
    ("cue2", 2, PA + "music.hq/Artist/cue.flac", PL + "music.hq/Artist/cue.flac", "rename"),
    ("dvorak", 0, PA + "music.hq/Dvořák/Largo – ž.flac", PL + "music.hq/Dvořák/Largo – ž.flac", "rename"),
    ("lower", 0, PA_LOWER + "music.hq/Artist/lower.flac", PL + "music.hq/Artist/lower.flac", "rename"),
    ("rar", 0, unpack("rar", PA + "music.local/x/__prep.rar", "(02) Track.flac"),
     unpack("rar", PL + "music.local/x/__prep.rar", "(02) Track.flac"), "rename"),
    ("rar_utf8", 0, unpack("rar", PA + "music.local/x/__prep.rar", "(03) Píseň č. 3.flac"),
     unpack("rar", PL + "music.local/x/__prep.rar", "(03) Píseň č. 3.flac"), "rename"),
    ("nested", 0, nested(PA), nested(PL), "rename"),
    # non-ASCII archive paths: counts in bytes differ from counts in characters
    ("rar_cz", 0, unpack("rar", PA + "music.local/Dvořák/Šárka.rar", "(04) Píseň.flac"),
     unpack("rar", PL + "music.local/Dvořák/Šárka.rar", "(04) Píseň.flac"), "rename"),
    ("nested_cz", 0, nested_cz(PA), nested_cz(PL), "rename"),
    ("other_vol", 0, PB + "other/x.flac", None, "keep"),
    ("tidal", 0, "tidal://track/123456", None, "keep"),
    ("other_file", 0, "file:///Users/test/Other/y.flac", None, "keep"),
    ("dup_old", 0, PA + "music.hq/Artist/dup.flac", PL + "music.hq/Artist/dup.flac", "delete"),
    ("dup_link", 0, PL + "music.hq/Artist/dup.flac", None, "keep"),
    ("md", 0, PMD + "music.hq/Artist/md.flac", PL + "music.hq/Artist/md.flac", "rename"),
    ("both_a", 0, PA + "music.hq/Artist/both.flac", PL + "music.hq/Artist/both.flac", "rename"),
    ("both_md", 0, PMD + "music.hq/Artist/both.flac", PL + "music.hq/Artist/both.flac", "tie"),
]
R = {r[0]: r for r in REC}


def name(label, new=False):
    _, sub, old, nw, _ = R[label]
    return "%d+%s" % (sub, nw if new and nw else old)


def final_name(label):
    """Value after the migration, or None when the row is deleted."""
    fate = R[label][4]
    if fate in ("delete", "tie"):
        return None
    return name(label, new=(fate == "rename"))


os.makedirs(os.path.join(PROFILE, "playlists-v2.0", "backup_volume_sync_2026-01-01_000000"))
os.makedirs(os.path.join(PROFILE, "library-v2.0", "0123456789ABCDEF"))
os.makedirs(os.path.join(EXPECTED, "playlists"))


def write(path, data):
    with open(path, "wb") as f:
        f.write(data)


# ---- metadb.sqlite --------------------------------------------------------
db = sqlite3.connect(os.path.join(PROFILE, "metadb.sqlite"))
db.executescript("""
CREATE TABLE metadb (name TEXT UNIQUE PRIMARY KEY NOT NULL, info BLOB, infoBrowse BLOB, size INTEGER,
  lastModified INTEGER, infoBrowseTime INTEGER, lastseen INTEGER, created INTEGER, attribs INTEGER,
  attribsValid INTEGER, partial INTEGER NOT NULL DEFAULT 0);
CREATE TABLE metadb_indexes (name TEXT UNIQUE PRIMARY KEY NOT NULL, synced INTEGER, retention INTEGER);
CREATE TABLE config (key TEXT UNIQUE PRIMARY KEY NOT NULL, value);
INSERT INTO config VALUES ('uniNormFix', 1), ('version', 3);
""")
for guid in (STATS, BPM, UNKNOWN):
    t = "metadb_index_" + guid.replace("-", "_")
    db.execute("INSERT INTO metadb_indexes VALUES (?, 1, 0)", (guid,))
    db.execute('CREATE TABLE "%s" (key INTEGER NOT NULL, filename TEXT NOT NULL UNIQUE PRIMARY KEY)' % t)
    db.execute('CREATE INDEX "%s_key" ON "%s" (key)' % (t, t))
    db.execute('CREATE TABLE "%s_data" (key INTEGER NOT NULL PRIMARY KEY UNIQUE, value BLOB)' % t)
for i, r in enumerate(REC):
    db.execute("INSERT INTO metadb (name, info, size) VALUES (?, ?, ?)",
               (name(r[0]), b"info-" + r[0].encode(), 1000 + i))

# play statistics: keyed by metadata, so keys are arbitrary and can be shared
st = "metadb_index_" + STATS.replace("-", "_")
stats_keys = {}
for i, r in enumerate(REC):
    stats_keys[r[0]] = 5555 if r[0] in ("cue1", "cue2") else 7000 + i
    db.execute('INSERT INTO "%s" VALUES (?, ?)' % st, (stats_keys[r[0]], name(r[0])))
for k in sorted(set(stats_keys.values())):
    db.execute('INSERT INTO "%s_data" VALUES (?, ?)' % st, (k, b"plays-%d" % k))

# BPM grids: keyed by path hash
bt = "metadb_index_" + BPM.replace("-", "_")
bpm_labels = ["one", "cue1", "cue2", "dvorak", "lower", "rar", "nested", "rar_cz", "nested_cz",
              "other_vol", "dup_old", "dup_link", "md", "both_a", "both_md"]
grids = ["one", "cue1", "lower", "rar", "nested", "rar_cz", "other_vol", "dup_old", "dup_link",
         "both_md"]
for lab in bpm_labels:
    _, sub, old, _, _ = R[lab]
    db.execute('INSERT INTO "%s" VALUES (?, ?)' % bt, (key_of(old, sub), name(lab)))
for lab in grids:
    _, sub, old, _, _ = R[lab]
    db.execute('INSERT INTO "%s_data" VALUES (?, ?)' % bt, (key_of(old, sub), b"grid-" + lab.encode()))

# an index this tool does not know: filenames rewritten, keys kept
ut = "metadb_index_" + UNKNOWN.replace("-", "_")
unknown_labels = {"one": 7, "md": 8, "other_vol": 9}
for lab, k in unknown_labels.items():
    db.execute('INSERT INTO "%s" VALUES (?, ?)' % ut, (k, name(lab)))
    db.execute('INSERT INTO "%s_data" VALUES (?, ?)' % ut, (k, b"u%d" % k))
db.commit()
db.close()

# expected rows
names = sorted(n for n in (final_name(r[0]) for r in REC) if n)
write(os.path.join(EXPECTED, "metadb_names.txt"), "".join(n + "\n" for n in names).encode())
write(os.path.join(EXPECTED, "stats_rows.txt"), "".join(
    "%d|%s\n" % (stats_keys[r[0]], final_name(r[0])) for r in REC if final_name(r[0])).encode())
bpm_rows = []
for lab in bpm_labels:
    fn = final_name(lab)
    if fn:
        _, sub, old, nw, fate = R[lab]
        bpm_rows.append("%d|%s\n" % (key_of(nw if fate == "rename" else old, sub), fn))
write(os.path.join(EXPECTED, "bpm_rows.txt"), "".join(bpm_rows).encode())
# grids: moved to the new key unless the target already had one (dup_old stays,
# dup_link keeps its own); both_md's row is deleted as a tie but its grid moves
# into both_a's empty new key.
bpm_data = []
for lab in grids:
    _, sub, old, nw, fate = R[lab]
    if lab in ("other_vol", "dup_link", "dup_old"):
        k = key_of(old, sub)
    else:
        k = key_of(nw, sub)
    bpm_data.append("%d|%s\n" % (k, ("grid-" + lab).encode().hex()))
write(os.path.join(EXPECTED, "bpm_data.txt"), "".join(bpm_data).encode())
write(os.path.join(EXPECTED, "unknown_rows.txt"), "".join(
    "%d|%s\n" % (k, final_name(lab)) for lab, k in unknown_labels.items()).encode())

# ---- playlists ------------------------------------------------------------
BOM = b"\xef\xbb\xbf"


def playlist(labels_or_lines, eol, final_eol, new):
    lines = []
    for x in labels_or_lines:
        if x in R:
            _, _, old, nw, _ = R[x]
            lines.append(nw if new and nw else old)
        else:
            lines.append(x)
    body = eol.join(l.encode("utf-8") for l in lines) + (eol if final_eol else b"")
    return BOM + body


pl = os.path.join(PROFILE, "playlists-v2.0")
specs = {
    "playlist-aaa.fplite": (["one", "tidal", "dvorak", "other_file", "lower", "other_vol", "nested",
                             "rar_cz"], b"\n", True),
    "playlist-bbb.fplite": (["tidal", "other_file", "other_vol"], b"\n", True),
    "playlist-ccc.fplite": (["md", "both_a", "both_md", "tidal"], b"\r\n", False),
}
for fname, (items, eol, final_eol) in specs.items():
    write(os.path.join(pl, fname), playlist(items, eol, final_eol, False))
    write(os.path.join(EXPECTED, "playlists", fname), playlist(items, eol, final_eol, True))
write(os.path.join(pl, "index.txt"), b"playlist-aaa\nplaylist-bbb\nplaylist-ccc\n")
write(os.path.join(pl, "backup_volume_sync_2026-01-01_000000", "playlist-aaa.fplite"),
      BOM + (PA + "music.hq/Artist/one.flac\n").encode())

# ---- library-v2.0 ---------------------------------------------------------
TRAIL = b"\x07\x00\x00\x00"   # real files have zeros; non-zero proves they are kept


def folders(urls):
    out = struct.pack("<I", len(urls))
    for u in urls:
        out += struct.pack("<I", len(u)) + u
    return out + TRAIL


write(os.path.join(PROFILE, "library-v2.0", "folders"), folders([b"file:///Users/test/Music/shadow-test/album/"]))
write(os.path.join(EXPECTED, "folders"), folders([PL.encode("utf-8")]))
lib = sqlite3.connect(os.path.join(PROFILE, "library-v2.0", "0123456789ABCDEF", "content.sqlite"))
lib.executescript("CREATE TABLE config (key TEXT UNIQUE PRIMARY KEY, value TEXT);"
                  "INSERT INTO config VALUES ('rootPath', 'file:///Users/test/Music/shadow-test/album/');")
lib.close()

# ---- config.sqlite: the volume registry, as volume_registry_prune.sh reads it
cfg = sqlite3.connect(os.path.join(PROFILE, "config.sqlite"))
cfg.executescript("""
CREATE TABLE config (name TEXT UNIQUE PRIMARY KEY NOT NULL, value INTEGER);
CREATE TABLE configStrings (name TEXT UNIQUE PRIMARY KEY NOT NULL, value TEXT);
CREATE TABLE configInts (name TEXT UNIQUE PRIMARY KEY NOT NULL, value INTEGER);
CREATE TABLE configBlobs (name TEXT UNIQUE PRIMARY KEY NOT NULL, value BLOB);
CREATE TABLE configReals (name TEXT UNIQUE PRIMARY KEY NOT NULL, value REAL);
INSERT INTO configStrings VALUES ('unrelated.setting', 'keep me');
""")
for u, path in ((A, "/Volumes/music-1"), (B, "/Volumes/LaCie"), (D, "/Volumes/Music"),
                (E, "/Volumes/music-backup"), (F, "/Volumes/music/sub")):
    cfg.execute("INSERT INTO configStrings VALUES (?, ?)", ("mac.volume.%s.originalPath" % u, path))
    cfg.execute("INSERT INTO configBlobs VALUES (?, x'00')", ("mac.volume.%s.bookmark" % u,))
cfg.commit()
cfg.close()

# a non-profile file the tool must ignore
write(os.path.join(PROFILE, "plorg_volume_uuids.json"), b'{"paths": {}}\n')
