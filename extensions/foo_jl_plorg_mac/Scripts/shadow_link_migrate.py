#!/usr/bin/env python3
"""
shadow_link_migrate.py - one-time move of a foobar2000 (macOS) profile from
volume-ID paths to a fixed symlink path.

foobar2000 records files on a network share as mac-volume://<volume UUID>/...,
and the UUID changes whenever the share comes back under a different server
identity. A symlink (for example ~/Music/NAS/music) that a mount agent keeps
pointed at the mounted share gives every track one stable path instead. This
tool rewrites an existing profile to that path, once, with foobar2000 quit:

  playlists-v2.0/*.fplite   lines under a --from prefix (top level only)
  metadb.sqlite             metadb.name and every metadb_index_* filename,
                            including archive rows (unpack://...|<len>|...),
                            whose length fields (in UTF-8 bytes) are
                            corrected. BPM beat-grid keys are a hash of the
                            path: they are recomputed and the grids moved to
                            the new keys.
  library-v2.0/folders      one Media Library root: the link

config.sqlite is backed up but never written. Waveform caches and plorg's own
json files are not touched.

Modes (exactly one):
  --dry-run        plan, counts, conflicts and self-checks; writes nothing
  --apply          back up, stage, verify, then swap the staged files in
  --check          drift report: values still under the share's volume IDs
                   (registry originalPath /Volumes/<share> or /Volumes/<share>-N,
                   the rule volume_registry_prune.sh uses) or a --from prefix
  --rollback DIR   restore metadb, library-v2.0 and the playlists the migration
                   rewrote from a backup. If config.sqlite changed since the
                   backup (volume_registry_prune.sh --apply removes the old
                   volume ID), add --restore-config or --keep-config.

Safety (apply and rollback):
  - refuses while foobar2000 runs, when --profile is its live profile
    (~/Library/foobar2000-v2, compared by device:inode)
  - refuses while plorg's quit-time metadb migrator is pending or running
    for the live profile
  - refuses on a non-empty metadb WAL or a hot rollback journal
  - fingerprints (size:mtime) every file it will replace, and re-checks them
    right before the swap
  - backs up to <profile>/shadow-link-backup-<timestamp>/ with a sha256
    manifest, stages everything next to the originals, verifies the staged
    files, then swaps them in by rename. The live metadb is never opened for
    writing. If a swap step fails, every item is restored from the backup.

Conflicts: when a rewritten value already exists (an older fold, or two --from
prefixes naming the same file), the existing row at the link path wins and the
old row is deleted. When no such row exists but several old rows map to the
same new value, the one under the earlier --from wins. A beat grid moves only
into a key that has no grid yet. Every conflict is listed.

Exit: 0 ok, 1 failed / refused / drift found, 2 usage.

Example:
  shadow_link_migrate.py --dry-run --link ~/Music/NAS/music \\
      --from mac-volume://01234567-89AB-CDEF-0123-456789ABCDEF/
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import sqlite3
import stat
import struct
import subprocess
import sys
import time
import urllib.parse
from collections import Counter, defaultdict

PLAYLISTS = "playlists-v2.0"
LIBRARY = "library-v2.0"
METADB = "metadb.sqlite"
CONFIG = "config.sqlite"
FOLDERS = "folders"

BPM_GUID = "4C2B7E91-0A36-4F58-B1D4-8E5A27C91F03"
STATS_GUID = "C653739F-14B3-4EF2-819B-A3E2883230AE"
INDEX_LABELS = {BPM_GUID: "BPM beat grids", STATS_GUID: "play statistics"}

STAGE_SUFFIX = ".shadow-link.tmp"            # staged playlist / folders files
STAGED_DB = METADB + ".shadow-link-staged"   # staged metadb copy
RESTORE_SUFFIX = ".shadow-link-restore.tmp"  # restore copies (rollback, failed swap)
BACKUP_PREFIX = "shadow-link-backup-"
ASIDE_PREFIX = "shadow-link-pre-rollback-"
MANIFEST = "manifest.json"
CHUNK = 8 << 20

# Test seams. Normal use needs none of them.
ENV_LIVE_PROFILE = "SHADOW_LINK_LIVE_PROFILE"    # path treated as the live profile
ENV_MIGRATOR_DIRS = "SHADOW_LINK_MIGRATOR_DIRS"  # ':'-separated dirs holding plorg's staged SQL
ENV_FAIL_SWAP = "SHADOW_LINK_TEST_FAIL_SWAP"     # make swap step N (1-based) fail
ENV_CRASH_SWAP = "SHADOW_LINK_TEST_CRASH_SWAP"   # exit at once at apply swap step N

UUID = r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
MAC_VOLUME_PREFIX_RE = re.compile(r"mac-volume://" + UUID + r"/\Z")
MAC_VOLUME_ID_RE = re.compile(r"mac-volume://(" + UUID + r")/")
FILE_PREFIX_RE = re.compile(r"file:///[^\r\n/][^\r\n]*/\Z")
INDEX_TABLE_RE = re.compile(r"metadb_index_([0-9A-Fa-f]{8}(?:_[0-9A-Fa-f]{4}){3}_[0-9A-Fa-f]{12})\Z")
NAME_RE = re.compile(r"([0-9]+)\+(.*)\Z", re.S)
UNPACK_HEAD_RE = re.compile(r"unpack://([^|]*)\|([0-9]+)\|")
BOM = b"\xef\xbb\xbf"
ASCII_LOWER = str.maketrans("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz")


class Failure(Exception):
    """Stops the run. The message becomes the final FAILED line."""


class UnpackError(Exception):
    """An unpack:// location whose length field does not check out."""


def say(msg=""):
    print(msg, flush=True)


def human(n):
    n = float(n)
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return "%d B" % n if unit == "B" else "%.1f %s" % (n, unit)
        n /= 1024.0
    return "%.1f GB" % n


def short(s, limit=160):
    return s if len(s) <= limit else s[:limit - 3] + "..."


# --------------------------------------------------------------------------
# Locations
# --------------------------------------------------------------------------

class Prefix:
    """A --from prefix. mac-volume:// prefixes match the UUID in any case;
    file:// prefixes match exactly."""

    def __init__(self, text):
        self.text = text
        self.ci = text.startswith("mac-volume://")
        self.key = text.translate(ASCII_LOWER) if self.ci else text
        self.key_bytes = self.key.encode("utf-8")

    def matches_start(self, s):
        head = s[:len(self.text)]
        return (head.translate(ASCII_LOWER) if self.ci else head) == self.key

    def contained_in(self, s):
        return self.key in (s.translate(ASCII_LOWER) if self.ci else s)

    def contained_in_bytes(self, b):
        if self.ci:
            b = bytes(c + 32 if 65 <= c <= 90 else c for c in b)
        return self.key_bytes in b


def parse_unpack(loc):
    """Split 'unpack://<type>|<len>|<archive location>|<inner name>'.

    Returns (head, count, span, rest): head is 'unpack://<type>|', span the
    counted archive location, rest what follows the span's closing '|'.
    foobar2000 counts the span in UTF-8 bytes: on a real profile, every
    non-ASCII archive path fits only that way (ASCII ones fit both ways).
    Self-check: the count, taken as UTF-8 bytes, must land on a '|'. Raises
    UnpackError otherwise, saying whether it would fit as characters.
    """
    m = UNPACK_HEAD_RE.match(loc)
    if not m:
        raise UnpackError("no 'unpack://<type>|<length>|' header")
    count = int(m.group(2))
    start = m.end()
    raw = loc.encode("utf-8")
    bstart = len(loc[:start].encode("utf-8"))
    end = bstart + count
    if raw[end:end + 1] == b"|":
        # '|' never occurs inside a multi-byte UTF-8 sequence, so both halves decode.
        span = raw[bstart:end].decode("utf-8")
        return loc[:m.start(2)], count, span, raw[end + 1:].decode("utf-8")
    if loc[start + count:start + count + 1] == "|":
        raise UnpackError("length %d fits only when counted as characters, but foobar2000 "
                          "counts UTF-8 bytes" % count)
    raise UnpackError("length %d does not end on a '|' (counted as UTF-8 bytes, nor as characters)"
                      % count)


def check_unpack(loc):
    """Self-check every nesting level of an unpack:// location."""
    _, _, span, _ = parse_unpack(loc)
    if span.startswith("unpack://"):
        check_unpack(span)


def split_name(value):
    """'<subsong>+<location>' -> (subsong text, location); (None, value) without one."""
    m = NAME_RE.match(value)
    return (m.group(1), m.group(2)) if m else (None, value)


def bpm_key(location, subsong):
    """foo_jl_bpm's index key: md5 of '<path>|<subsong>' (UTF-8), folded to 64
    bits as the little-endian XOR of its two 8-byte halves (the SDK's
    hasher_md5_result::xorHalve), stored by SQLite as a signed integer."""
    d = hashlib.md5(("%s|%d" % (location, int(subsong))).encode("utf-8")).digest()
    return struct.unpack("<q", bytes(a ^ b for a, b in zip(d[:8], d[8:])))[0]


class Rewrite:
    __slots__ = ("old", "new", "idx", "sub", "old_loc", "new_loc", "unpack")

    def __init__(self, old, new, idx, sub, old_loc, new_loc):
        self.old, self.new, self.idx = old, new, idx
        self.sub, self.old_loc, self.new_loc = sub, old_loc, new_loc
        self.unpack = old_loc.startswith("unpack://")


class Rewriter:
    def __init__(self, froms, link_url):
        self.froms = froms
        self.link = link_url

    def contains_from(self, s):
        return any(p.contained_in(s) for p in self.froms)

    def contains_from_bytes(self, b):
        return any(p.contained_in_bytes(b) for p in self.froms)

    def rewrite_location(self, loc):
        """New location, and the index of the --from prefix it was under;
        (None, None) when no prefix sits at a rewritable position."""
        for i, p in enumerate(self.froms):
            if p.matches_start(loc):
                return self.link + loc[len(p.text):], i
        if loc.startswith("unpack://"):
            head, _, span, rest = parse_unpack(loc)
            new_span, i = self.rewrite_location(span)
            if new_span is None:
                return None, None
            return "%s%d|%s|%s" % (head, len(new_span.encode("utf-8")), new_span, rest), i
        return None, None

    def rewrite_value(self, value):
        sub, loc = split_name(value)
        new_loc, i = self.rewrite_location(loc)
        if new_loc is None:
            return None
        new = new_loc if sub is None else sub + "+" + new_loc
        return Rewrite(value, new, i, sub, loc, new_loc)


# --------------------------------------------------------------------------
# Small file helpers
# --------------------------------------------------------------------------

def sha256_file(path):
    h = hashlib.sha256()
    size = 0
    with open(path, "rb") as f:
        while True:
            b = f.read(CHUNK)
            if not b:
                break
            h.update(b)
            size += len(b)
    return size, h.hexdigest()


def copy_file(src, dst):
    """Copy src to dst, which must not exist; fsync; keep mode and times.
    Returns (size, sha256 of the bytes read)."""
    h = hashlib.sha256()
    size = 0
    with open(src, "rb") as fi, open(dst, "xb") as fo:
        while True:
            b = fi.read(CHUNK)
            if not b:
                break
            h.update(b)
            fo.write(b)
            size += len(b)
        fo.flush()
        os.fsync(fo.fileno())
    st = os.stat(src)
    os.chmod(dst, stat.S_IMODE(st.st_mode))
    os.utime(dst, ns=(st.st_atime_ns, st.st_mtime_ns))
    return size, h.hexdigest()


def write_new(path, data, mode_from=None):
    with open(path, "xb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    if mode_from:
        os.chmod(path, stat.S_IMODE(os.stat(mode_from).st_mode))


def fingerprint(path):
    try:
        st = os.stat(path)
    except FileNotFoundError:
        return None
    return (st.st_size, st.st_mtime_ns)


def remove_quietly(path):
    try:
        if os.path.isdir(path) and not os.path.islink(path):
            shutil.rmtree(path)
        else:
            os.unlink(path)
    except FileNotFoundError:
        pass


def free_bytes(path):
    st = os.statvfs(path)
    return st.f_bavail * st.f_frsize


def same_dir(a, b):
    """True when both paths name the same directory: device+inode, which also
    folds firmlink and symlink aliases; canonical paths when a stat fails."""
    try:
        sa, sb = os.stat(a), os.stat(b)
        return (sa.st_dev, sa.st_ino) == (sb.st_dev, sb.st_ino)
    except OSError:
        return os.path.realpath(a) == os.path.realpath(b)


def open_ro(path, immutable=False):
    """Read-only connection. immutable is only for files nothing else can be
    writing (the staged copy): SQLite then takes no locks and creates no
    -wal/-shm files."""
    uri = "file:%s?mode=ro%s" % (urllib.parse.quote(os.path.abspath(path)),
                                 "&immutable=1" if immutable else "")
    return sqlite3.connect(uri, uri=True, timeout=15, isolation_level=None)


# --------------------------------------------------------------------------
# Profile
# --------------------------------------------------------------------------

class Paths:
    def __init__(self, profile):
        self.profile = profile
        self.metadb = os.path.join(profile, METADB)
        self.config = os.path.join(profile, CONFIG)
        self.playlists = os.path.join(profile, PLAYLISTS)
        self.library = os.path.join(profile, LIBRARY)
        self.folders = os.path.join(self.library, FOLDERS)
        self.staged_db = os.path.join(profile, STAGED_DB)

    def playlist_files(self):
        if not os.path.isdir(self.playlists):
            return []
        out = []
        for name in sorted(os.listdir(self.playlists)):
            if not name.endswith(".fplite"):
                continue
            p = os.path.join(self.playlists, name)
            if os.path.islink(p):
                raise Failure("playlist %s is a symlink; refusing to replace it" % p)
            if os.path.isfile(p):
                out.append(p)
        return out

    def stale_staging(self):
        found = []
        for p in (self.staged_db, self.staged_db + "-wal", self.staged_db + "-shm",
                  self.staged_db + "-journal", self.folders + STAGE_SUFFIX,
                  self.folders + RESTORE_SUFFIX, self.metadb + RESTORE_SUFFIX,
                  self.metadb + "-wal" + RESTORE_SUFFIX, self.metadb + "-shm" + RESTORE_SUFFIX,
                  self.config + RESTORE_SUFFIX, self.config + "-wal" + RESTORE_SUFFIX,
                  self.config + "-shm" + RESTORE_SUFFIX,
                  os.path.join(self.profile, LIBRARY + RESTORE_SUFFIX)):
            if os.path.lexists(p):
                found.append(p)
        if os.path.isdir(self.playlists):
            for name in sorted(os.listdir(self.playlists)):
                if name.endswith(STAGE_SUFFIX) or name.endswith(RESTORE_SUFFIX):
                    found.append(os.path.join(self.playlists, name))
        return found

    def metadb_sidecars(self, strict):
        """Existing -wal/-shm of metadb. A non-empty WAL or a hot rollback
        journal means foobar2000 is running or did not shut down cleanly."""
        problems = []
        j = self.metadb + "-journal"
        if os.path.exists(j) and os.path.getsize(j) > 0:
            problems.append("%s exists and is not empty (unfinished transaction)" % j)
        w = self.metadb + "-wal"
        if os.path.exists(w) and os.path.getsize(w) > 0:
            problems.append("%s is not empty (foobar2000 running or not shut down cleanly)" % w)
        if problems and strict:
            raise Failure("; ".join(problems))
        for p in problems:
            say("note: --apply would refuse: %s" % p)
        return [s for s in ("-wal", "-shm") if os.path.exists(self.metadb + s)]


def open_profile_db(path, live):
    """Read-only connection to one of the profile's databases. Immutable (no
    locks, no -wal/-shm created; a WAL database without them cannot be opened
    otherwise) when nothing can be writing it: its WAL is empty, and either this
    is not the live profile or foobar2000 is not running. Otherwise a normal
    read-only connection that shares foobar2000's locks."""
    wal = path + "-wal"
    quiet = (not os.path.exists(wal) or os.path.getsize(wal) == 0) and \
        (not live or not pgrep(["-x", "foobar2000"]))
    return open_ro(path, immutable=quiet)


def live_profile_path():
    return os.environ.get(ENV_LIVE_PROFILE) or os.path.expanduser("~/Library/foobar2000-v2")


def is_live(profile):
    live = live_profile_path()
    return os.path.exists(live) and same_dir(profile, live)


def pgrep(args):
    exe = shutil.which("pgrep") or "/usr/bin/pgrep"
    try:
        r = subprocess.run([exe] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           universal_newlines=True)
    except OSError as e:
        raise Failure("could not run pgrep (%s); cannot tell what is running" % e)
    if r.returncode == 0:
        return r.stdout.split()
    if r.returncode == 1:
        return []
    raise Failure("pgrep %s failed (exit %d); cannot tell what is running"
                  % (" ".join(args), r.returncode))


def migrator_dirs():
    env = os.environ.get(ENV_MIGRATOR_DIRS)
    if env is not None:
        return [d for d in env.split(":") if d]
    dirs = ["/tmp"]
    tmp = os.environ.get("TMPDIR")
    if tmp:
        dirs.append(tmp)
    return dirs


def migrator_signals(paths):
    """Evidence that plorg's quit-time metadb migrator is pending or running.
    It stages /tmp/plorg_metadb_migration_<pid>.sql while foobar2000 runs,
    runs as a shell after the quit, and works on metadb.sqlite.plorg-work /
    .plorg-prev next to the live database."""
    found = []
    for d in migrator_dirs():
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for n in names:
            if n.startswith("plorg_metadb_migration_") and n.endswith(".sql"):
                found.append("staged migration SQL %s" % os.path.join(d, n))
    pids = pgrep(["-f", "plorg_metadb_migration_"])
    if pids:
        found.append("migrator process(es) running: pid %s" % ", ".join(pids))
    return found


def guard(paths, live, action, strict):
    """Refuse (strict) or warn when writing would race foobar2000 or plorg."""
    problems = []
    if live and pgrep(["-x", "foobar2000"]):
        problems.append("foobar2000 is running and %s is its live profile. Quit it first."
                        % paths.profile)
    for suffix in (".plorg-work", ".plorg-prev"):
        p = paths.metadb + suffix
        if os.path.lexists(p):
            problems.append("%s exists: plorg's migrator is mid-run or crashed. "
                            "Check its log in /tmp before going on." % p)
    signals = migrator_signals(paths)
    if signals:
        if live:
            problems.append("plorg's metadb migrator is pending or running (%s). Wait for it to "
                            "finish (log: /tmp/plorg_metadb_migration_<pid>.log). A staged SQL file "
                            "with no migrator process left is from an interrupted run: read its log, "
                            "then delete it." % "; ".join(signals))
        else:
            say("note: plorg's metadb migrator is pending for the live profile (%s); "
                "it does not touch this profile." % "; ".join(signals))
    if problems:
        if strict:
            for p in problems[1:]:
                say("refused: %s" % p)
            raise Failure("%s refused: %s" % (action, problems[0]))
        for p in problems:
            say("note: --%s would refuse: %s" % (action, p))


def stale_check(paths):
    stale = paths.stale_staging()
    if stale:
        for p in stale:
            say("  leftover: %s" % p)
        backups = sorted(n for n in os.listdir(paths.profile) if n.startswith(BACKUP_PREFIX))
        target = "'%s'" % os.path.join(paths.profile, backups[-1]) if backups else "<backup folder>"
        raise Failure("files from an unfinished run exist (listed above). Run --rollback %s: "
                      "it removes them and restores the backup." % target)


# --------------------------------------------------------------------------
# Playlists
# --------------------------------------------------------------------------

def split_eol(raw):
    if raw.endswith(b"\r\n"):
        return raw[:-2], b"\r\n"
    if raw.endswith(b"\n") or raw.endswith(b"\r"):
        return raw[:-1], raw[-1:]
    return raw, b""


def rewrite_playlist(data, rw, path):
    """Rewrite each line that starts with a --from prefix (after the BOM on the
    first line). Every other byte stays as it was, line endings included."""
    out = []
    changed = 0
    per = Counter()
    for n, raw in enumerate(data.splitlines(True)):
        body, eol = split_eol(raw)
        bom = b""
        if n == 0 and body.startswith(BOM):
            bom, body = BOM, body[len(BOM):]
        try:
            text = body.decode("utf-8")
        except UnicodeDecodeError:
            if rw.contains_from_bytes(body):
                raise Failure("%s line %d is not UTF-8 but contains a --from prefix" % (path, n + 1))
            out.append(raw)
            continue
        if not rw.contains_from(text):
            out.append(raw)
            continue
        try:
            new, idx = rw.rewrite_location(text)
        except UnpackError as e:
            raise Failure("%s line %d: unpack self-check failed: %s" % (path, n + 1, e))
        if new is None:
            raise Failure("%s line %d contains a --from prefix where it cannot be rewritten: %s"
                          % (path, n + 1, short(text)))
        out.append(bom + new.encode("utf-8") + eol)
        changed += 1
        per[idx] += 1
    return b"".join(out), changed, per


class PlaylistPlan:
    def __init__(self):
        self.scanned = []      # every top-level .fplite
        self.changes = []      # (path, new bytes, lines changed)
        self.lines = 0
        self.per = Counter()


def plan_playlists(paths, rw):
    plan = PlaylistPlan()
    for p in paths.playlist_files():
        plan.scanned.append(p)
        with open(p, "rb") as f:
            data = f.read()
        new, n, per = rewrite_playlist(data, rw, p)
        if n:
            plan.changes.append((p, new, n))
            plan.lines += n
            plan.per.update(per)
    return plan


def verify_playlist(old, new, rw, path):
    """Independent check of a staged playlist against its original."""
    a, b = old.splitlines(True), new.splitlines(True)
    if len(a) != len(b):
        raise Failure("staged %s has %d lines, original %d" % (path, len(b), len(a)))
    if old.startswith(BOM) != new.startswith(BOM):
        raise Failure("staged %s lost or gained the BOM" % path)
    for n, (x, y) in enumerate(zip(a, b)):
        if split_eol(x)[1] != split_eol(y)[1]:
            raise Failure("staged %s line %d changed its line ending" % (path, n + 1))
        if x != y:
            body = split_eol(y)[0]
            if n == 0 and body.startswith(BOM):
                body = body[len(BOM):]
            text = body.decode("utf-8")
            under_link = text.startswith(rw.link) or (text.startswith("unpack://") and rw.link in text)
            if rw.contains_from(text) or not under_link:
                raise Failure("staged %s line %d is not under the link: %s" % (path, n + 1, short(text)))
        elif rw.contains_from_bytes(split_eol(y)[0]):
            raise Failure("staged %s line %d still has a --from prefix" % (path, n + 1))


# --------------------------------------------------------------------------
# library-v2.0/folders
# --------------------------------------------------------------------------

def parse_folders(data, path):
    """u32 LE count, then per entry u32 LE length + URL bytes, then exactly 4
    trailing bytes. Anything else is refused."""
    def bad(why):
        return Failure("%s does not have the expected layout (%s); refusing to write it" % (path, why))
    if len(data) < 8:
        raise bad("only %d bytes" % len(data))
    count = struct.unpack_from("<I", data, 0)[0]
    if count > 4096:
        raise bad("entry count %d" % count)
    pos = 4
    urls = []
    for i in range(count):
        if pos + 4 > len(data):
            raise bad("entry %d has no length field" % (i + 1))
        n = struct.unpack_from("<I", data, pos)[0]
        pos += 4
        if pos + n > len(data):
            raise bad("entry %d runs past the end" % (i + 1))
        urls.append(data[pos:pos + n])
        pos += n
    if len(data) - pos != 4:
        raise bad("%d bytes after the entries, expected 4" % (len(data) - pos))
    return urls, data[pos:]


def build_folders(urls, trailing):
    out = [struct.pack("<I", len(urls))]
    for u in urls:
        out.append(struct.pack("<I", len(u)) + u)
    out.append(trailing)
    return b"".join(out)


class FoldersPlan:
    def __init__(self, old_urls, new_bytes):
        self.old_urls = old_urls
        self.new_bytes = new_bytes   # None: already has the link root, unchanged


def plan_folders(paths, link_url):
    if not os.path.isfile(paths.folders):
        raise Failure("%s not found" % paths.folders)
    with open(paths.folders, "rb") as f:
        data = f.read()
    urls, trailing = parse_folders(data, paths.folders)
    target = link_url.encode("utf-8")
    if target in urls:
        return FoldersPlan(urls, None)
    return FoldersPlan(urls, build_folders([target], trailing))


# --------------------------------------------------------------------------
# metadb planning
# --------------------------------------------------------------------------

class Entry:
    """One touched row: renamed (kept is None) or deleted as a conflict."""
    __slots__ = ("rw", "old_key", "new_key", "kept", "reason")

    def __init__(self, rw, old_key, new_key=None, kept=None, reason=None):
        self.rw, self.old_key, self.new_key = rw, old_key, new_key
        self.kept, self.reason = kept, reason


class TablePlan:
    def __init__(self, table, column, kind, guid=None):
        self.table, self.column, self.kind, self.guid = table, column, kind, guid
        self.before = 0
        self.renames = []
        self.deletes = []
        self.direct = 0
        self.unpack = 0
        self.per = Counter()
        self.unpack_untouched_ok = 0
        self.unpack_untouched_bad = []
        self.formula_ok = 0
        self.formula_untouched_bad = 0
        self.data_before = 0
        self.moves = []          # (old key, new key, delete source)
        self.kept_grids = []     # (old key, new key, Entry): target already had a grid
        self.expected = None     # metadb: set of names; index: {filename: key}
        self.expected_data = None

    @property
    def label(self):
        if self.kind == "metadb":
            return "metadb"
        return "index %s (%s)" % (self.guid, INDEX_LABELS.get(self.guid, "unknown index"))


def discover(conn):
    tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}

    def cols(t):
        return {r[1] for r in conn.execute('PRAGMA table_info("%s")' % t.replace('"', '""'))}

    if "metadb" not in tables or "name" not in cols("metadb"):
        raise Failure("metadb.sqlite has no metadb(name) table")
    indexes = []
    for t in sorted(tables):
        # Same selection as GLOB 'metadb_index_*' AND NOT GLOB '*_data'.
        if not t.startswith("metadb_index_") or t.endswith("_data"):
            continue
        m = INDEX_TABLE_RE.match(t)
        if not m:
            raise Failure("unexpected index table name %r" % t)
        if not {"key", "filename"} <= cols(t):
            raise Failure("index table %s lacks key/filename columns" % t)
        if t + "_data" not in tables or not {"key", "value"} <= cols(t + "_data"):
            raise Failure("index table %s has no %s_data(key, value) table" % (t, t))
        indexes.append((t, m.group(1).replace("_", "-").upper()))
    return indexes


def plan_table(tp, rows, rw):
    """rows: [(key or None, value)]. Fills renames, deletes, expected."""
    candidates = defaultdict(list)
    existing = set()
    touched = set()
    for key, v in rows:
        tp.before += 1
        if not isinstance(v, str):
            if isinstance(v, bytes) and rw.contains_from_bytes(v):
                raise Failure("%s: a non-text value contains a --from prefix" % tp.label)
            continue
        existing.add(v)
        if not rw.contains_from(v):
            loc = split_name(v)[1]
            if loc.startswith("unpack://"):
                try:
                    check_unpack(loc)
                    tp.unpack_untouched_ok += 1
                except UnpackError as e:
                    tp.unpack_untouched_bad.append((v, str(e)))
            continue
        try:
            r = rw.rewrite_value(v)
            if r is not None and r.unpack:
                check_unpack(r.old_loc)
                check_unpack(r.new_loc)
        except UnpackError as e:
            raise Failure("%s: unpack self-check failed for %s: %s" % (tp.label, short(v), e))
        if r is None:
            raise Failure("%s: %s contains a --from prefix where it cannot be rewritten"
                          % (tp.label, short(v)))
        if rw.contains_from(r.new):
            raise Failure("%s: rewritten value still contains a --from prefix: %s" % (tp.label, short(r.new)))
        touched.add(v)
        candidates[r.new].append((r, key))
        if r.unpack:
            tp.unpack += 1
        else:
            tp.direct += 1
        tp.per[r.idx] += 1

    for new in sorted(candidates):
        olds = sorted(candidates[new], key=lambda c: (c[0].idx, c[0].old))
        if new in existing:
            for r, key in olds:
                tp.deletes.append(Entry(r, key, kept=new, reason="existing row at the link path kept"))
        else:
            r0, key0 = olds[0]
            tp.renames.append(Entry(r0, key0))
            for r, key in olds[1:]:
                tp.deletes.append(Entry(r, key, kept=r0.old,
                                        reason="same file under an earlier --from kept"))

    if tp.kind == "metadb":
        exp = {v for _, v in rows if v not in touched}
        exp.update(e.rw.new for e in tp.renames)
        tp.expected = exp
    else:
        tp.expected = {v: k for k, v in rows if v not in touched}
    return touched


def plan_bpm(tp, rows, touched, data):
    """Verify the key formula, compute new keys and the grid moves."""
    for key, v in rows:
        if not isinstance(v, str):
            continue
        sub, loc = split_name(v)
        ok = sub is not None and isinstance(key, int) and bpm_key(loc, sub) == key
        if ok:
            tp.formula_ok += 1
        elif v in touched:
            raise Failure("%s: stored key %r of %s does not match the path-hash formula; "
                          "refusing to re-key grids" % (tp.label, key, short(v)))
        else:
            tp.formula_untouched_bad += 1
    for e in tp.renames + tp.deletes:
        e.new_key = bpm_key(e.rw.new_loc, e.rw.sub)
    for e in tp.renames:
        tp.expected[e.rw.new] = e.new_key

    remaining = Counter(tp.expected.values())
    occupied = set(data)
    expected_data = dict(data)
    for e in tp.renames + tp.deletes:
        k_old, k_new = e.old_key, e.new_key
        if k_old == k_new or k_old not in occupied:
            continue
        if k_new in occupied:
            tp.kept_grids.append((k_old, k_new, e))
            continue
        delete_src = remaining[k_old] == 0
        tp.moves.append((k_old, k_new, delete_src))
        expected_data[k_new] = expected_data[k_old]
        occupied.add(k_new)
        if delete_src:
            del expected_data[k_old]
            occupied.discard(k_old)
    tp.expected_data = expected_data


def plan_metadb(conn, rw):
    indexes = discover(conn)
    plans = []
    tp = TablePlan("metadb", "name", "metadb")
    plan_table(tp, [(None, r[0]) for r in conn.execute("SELECT name FROM metadb")], rw)
    plans.append(tp)
    for table, guid in indexes:
        kind = "bpm" if guid == BPM_GUID else "stats" if guid == STATS_GUID else "unknown"
        tp = TablePlan(table, "filename", kind, guid)
        rows = conn.execute('SELECT key, filename FROM "%s"' % table).fetchall()
        touched = plan_table(tp, rows, rw)
        for e in tp.renames:
            e.new_key = e.old_key
            tp.expected[e.rw.new] = e.old_key
        tp.data_before = conn.execute('SELECT count(*) FROM "%s_data"' % table).fetchone()[0]
        if kind == "bpm":
            data = dict(conn.execute('SELECT key, value FROM "%s_data"' % table).fetchall())
            plan_bpm(tp, rows, touched, data)
        plans.append(tp)
    return plans


def plan_digest(plans):
    h = hashlib.sha256()
    for tp in plans:
        h.update(repr((tp.table, tp.before, tp.data_before, tp.moves)).encode("utf-8"))
        for e in tp.renames:
            h.update(repr(("r", e.rw.old, e.rw.new, e.old_key, e.new_key)).encode("utf-8"))
        for e in tp.deletes:
            h.update(repr(("d", e.rw.old, e.kept)).encode("utf-8"))
    return h.hexdigest()


def plan_changes(plans):
    return sum(len(tp.renames) + len(tp.deletes) for tp in plans)


# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------

def report_prefixes(per, froms, indent="    "):
    for i, p in enumerate(froms):
        if per.get(i):
            say("%sunder %s: %d" % (indent, p.text, per[i]))


def report(pl, fp, plans, froms, link_url):
    say("playlists: %d scanned, %d to change, %d lines rewritten"
        % (len(pl.scanned), len(pl.changes), pl.lines))
    report_prefixes(pl.per, froms)
    for p, _, n in pl.changes:
        say("    %s: %d" % (os.path.basename(p), n))
    conflicts = []
    for tp in plans:
        line = "%s: %d rows, %d under --from (%d direct, %d archive): rewrite %d, conflicts %d" % (
            tp.label, tp.before, len(tp.renames) + len(tp.deletes), tp.direct, tp.unpack,
            len(tp.renames), len(tp.deletes))
        if tp.kind in ("stats", "unknown"):
            line += "; keys and data kept"
        say(line)
        report_prefixes(tp.per, froms)
        if tp.unpack or tp.unpack_untouched_ok or tp.unpack_untouched_bad:
            say("    archive self-check: %d rewritten rows ok, %d other rows ok"
                % (tp.unpack, tp.unpack_untouched_ok))
        if tp.unpack_untouched_bad:
            say("    warning: %d archive rows outside the --from prefixes fail the self-check "
                "(left untouched), e.g. %s: %s" % (len(tp.unpack_untouched_bad),
                                                   short(tp.unpack_untouched_bad[0][0]),
                                                   tp.unpack_untouched_bad[0][1]))
        if tp.kind == "bpm":
            say("    key formula verified on %d of %d rows (all rewritten rows match)"
                % (tp.formula_ok, tp.before))
            if tp.formula_untouched_bad:
                say("    warning: %d rows outside the --from prefixes do not match the formula "
                    "(left untouched)" % tp.formula_untouched_bad)
            say("    re-key %d rows; grids: %d stored, move %d, keep %d in place (target already "
                "has a grid)" % (len(tp.renames), tp.data_before, len(tp.moves), len(tp.kept_grids)))
        if tp.kind == "unknown":
            say("    note: unknown index: filenames rewritten, keys kept")
        for e in tp.deletes:
            conflicts.append("%s: %s -> %s (%s; old row deleted)"
                             % (tp.label, e.rw.old, e.rw.new, e.reason))
        for k_old, k_new, e in tp.kept_grids:
            conflicts.append("%s: grid at key %d stays (key %d of %s already has a grid)"
                             % (tp.label, k_old, k_new, e.rw.new))
    if fp.new_bytes is None:
        say("library folders: already has %s, unchanged" % link_url)
    else:
        say("library folders: %d root(s) -> %s" % (len(fp.old_urls), link_url))
        for u in fp.old_urls:
            say("    was: %s" % u.decode("utf-8", "replace"))
    say("conflicts: %d" % len(conflicts))
    for c in conflicts:
        say("    " + c)


# --------------------------------------------------------------------------
# Execute on the staged copy, then verify it
# --------------------------------------------------------------------------

def execute_plan(conn, plans):
    conn.execute("PRAGMA cache_size=-262144")
    conn.execute("BEGIN IMMEDIATE")
    try:
        for tp in plans:
            t, c = tp.table, tp.column
            cur = conn.executemany('DELETE FROM "%s" WHERE %s = ?' % (t, c),
                                   [(e.rw.old,) for e in tp.deletes])
            if tp.deletes and cur.rowcount != len(tp.deletes):
                raise Failure("%s: deleted %d rows, planned %d" % (tp.label, cur.rowcount, len(tp.deletes)))
            if tp.kind == "bpm":
                cur = conn.executemany('UPDATE "%s" SET filename = ?, key = ? WHERE filename = ?' % t,
                                       [(e.rw.new, e.new_key, e.rw.old) for e in tp.renames])
            else:
                cur = conn.executemany('UPDATE "%s" SET %s = ? WHERE %s = ?' % (t, c, c),
                                       [(e.rw.new, e.rw.old) for e in tp.renames])
            if tp.renames and cur.rowcount != len(tp.renames):
                raise Failure("%s: renamed %d rows, planned %d" % (tp.label, cur.rowcount, len(tp.renames)))
            for k_old, k_new, delete_src in tp.moves:
                d = t + "_data"
                if conn.execute('SELECT count(*) FROM "%s" WHERE key = ?' % d, (k_new,)).fetchone()[0]:
                    raise Failure("%s: grid target key %d is not empty" % (tp.label, k_new))
                cur = conn.execute('INSERT INTO "%s" (key, value) SELECT ?, value FROM "%s" WHERE key = ?'
                                   % (d, d), (k_new, k_old))
                if cur.rowcount != 1:
                    raise Failure("%s: grid at key %d not found" % (tp.label, k_old))
                if delete_src:
                    conn.execute('DELETE FROM "%s" WHERE key = ?' % d, (k_old,))
        conn.execute("COMMIT")
    except BaseException:
        if conn.in_transaction:
            conn.execute("ROLLBACK")
        raise


def finish_staged_db(conn, path):
    """Fold any WAL back into the staged file and close it, so the staged
    database is one self-contained file."""
    mode = conn.execute("PRAGMA journal_mode").fetchone()[0]
    if mode.lower() == "wal":
        busy, _, _ = conn.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
        if busy:
            raise Failure("could not checkpoint the staged database")
    conn.close()
    for s in ("-wal", "-shm", "-journal"):
        p = path + s
        if os.path.exists(p):
            if s != "-shm" and os.path.getsize(p) > 0:
                raise Failure("staged database left a non-empty %s" % p)
            os.unlink(p)


def verify_staged_db(path, plans, rw):
    conn = open_ro(path, immutable=True)
    try:
        res = [r[0] for r in conn.execute("PRAGMA integrity_check")]
        if res != ["ok"]:
            raise Failure("integrity_check of the staged database: %s" % short("; ".join(res)))
        for tp in plans:
            t = tp.table
            n = conn.execute('SELECT count(*) FROM "%s"' % t).fetchone()[0]
            if n != tp.before - len(tp.deletes):
                raise Failure("%s: %d rows after, expected %d before minus %d conflicts"
                              % (tp.label, n, tp.before, len(tp.deletes)))
            if tp.kind == "metadb":
                values = [r[0] for r in conn.execute("SELECT name FROM metadb")]
                if set(values) != tp.expected:
                    raise Failure("metadb: staged names differ from the plan")
            else:
                rows = conn.execute('SELECT key, filename FROM "%s"' % t).fetchall()
                values = [v for _, v in rows]
                if {v: k for k, v in rows} != tp.expected:
                    raise Failure("%s: staged rows differ from the plan" % tp.label)
                d = t + "_data"
                if tp.kind == "bpm":
                    data = dict(conn.execute('SELECT key, value FROM "%s"' % d).fetchall())
                    if data != tp.expected_data:
                        raise Failure("%s: staged grids differ from the plan" % tp.label)
                    staged = {v: k for k, v in rows}
                    for e in tp.renames:
                        if bpm_key(split_name(e.rw.new)[1], e.rw.sub) != staged[e.rw.new]:
                            raise Failure("%s: re-keyed row does not hash to its key" % tp.label)
                else:
                    m = conn.execute('SELECT count(*) FROM "%s"' % d).fetchone()[0]
                    if m != tp.data_before:
                        raise Failure("%s: data rows changed (%d -> %d)" % (tp.label, tp.data_before, m))
            for v in values:
                if isinstance(v, str):
                    if rw.contains_from(v):
                        raise Failure("%s: a value still contains a --from prefix: %s" % (tp.label, short(v)))
                elif isinstance(v, bytes) and rw.contains_from_bytes(v):
                    raise Failure("%s: a value still contains a --from prefix" % tp.label)
            for e in tp.renames:
                if e.rw.unpack:
                    check_unpack(split_name(e.rw.new)[1])
    except UnpackError as e:
        raise Failure("unpack self-check of a staged value failed: %s" % e)
    finally:
        conn.close()


# --------------------------------------------------------------------------
# Backup and restore
# --------------------------------------------------------------------------

def backup_set(paths, playlists, sidecars):
    rels = [METADB] + [METADB + s for s in sidecars]
    if os.path.isfile(paths.config):
        rels.append(CONFIG)
        rels += [CONFIG + s for s in ("-wal", "-shm") if os.path.exists(paths.config + s)]
    rels += [PLAYLISTS + "/" + os.path.basename(p) for p in playlists]
    dirs = []
    if os.path.isdir(paths.library):
        for root, dnames, fnames in os.walk(paths.library):
            dnames.sort()
            rel_root = os.path.relpath(root, paths.profile)
            dirs.append(rel_root)
            for n in dnames + fnames:
                if os.path.islink(os.path.join(root, n)):
                    raise Failure("unexpected symlink in %s: %s" % (LIBRARY, os.path.join(root, n)))
            rels += [os.path.join(rel_root, n) for n in sorted(fnames)]
    return rels, dirs


def write_manifest(bdir, manifest):
    tmp = os.path.join(bdir, MANIFEST + ".tmp")
    remove_quietly(tmp)
    write_new(tmp, json.dumps(manifest, indent=1, sort_keys=True).encode("utf-8"))
    os.replace(tmp, os.path.join(bdir, MANIFEST))


def make_backup(paths, rels, dirs, link_url, froms, rewritten):
    ts = time.strftime("%Y%m%d-%H%M%S")
    bdir = os.path.join(paths.profile, BACKUP_PREFIX + ts)
    n = 2
    while os.path.lexists(bdir):
        bdir = os.path.join(paths.profile, "%s%s-%d" % (BACKUP_PREFIX, ts, n))
        n += 1
    os.mkdir(bdir)
    files = {}
    for d in dirs:
        os.makedirs(os.path.join(bdir, d), exist_ok=True)
    for rel in rels:
        dst = os.path.join(bdir, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        size, digest = copy_file(os.path.join(paths.profile, rel), dst)
        if sha256_file(dst) != (size, digest):
            raise Failure("backup copy of %s does not read back identical" % rel)
        files[rel] = {"size": size, "sha256": digest}
    # "rewritten": the playlists this run replaces; --rollback restores only
    # those. "post_swap" (added after a successful swap): size and mtime of
    # the files as swapped in, so --rollback can tell what changed since.
    manifest = {"tool": "shadow_link_migrate", "format": 1,
                "created": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                "profile": os.path.realpath(paths.profile), "link": link_url,
                "from": [p.text for p in froms], "dirs": dirs, "files": files,
                "rewritten": sorted(rewritten)}
    write_manifest(bdir, manifest)
    return bdir, manifest


def restore_file(bdir, manifest, rel, profile):
    """Put one backed-up file back in place by copy + rename, and confirm it."""
    target = os.path.join(profile, rel)
    tmp = target + RESTORE_SUFFIX
    remove_quietly(tmp)
    copy_file(os.path.join(bdir, rel), tmp)
    os.replace(tmp, target)
    want = manifest["files"][rel]
    if sha256_file(target) != (want["size"], want["sha256"]):
        raise OSError("restored %s does not match the backup" % rel)


# --------------------------------------------------------------------------
# Modes
# --------------------------------------------------------------------------

def link_status(link):
    if os.path.islink(link):
        return "symlink -> %s" % os.readlink(link)
    if os.path.exists(link):
        return "exists but is not a symlink"
    return "does not exist yet"


def header(mode, paths, live, rw=None, link=None):
    say("shadow_link_migrate: %s" % mode)
    say("profile: %s%s" % (paths.profile, " (live foobar2000 profile)" if live else ""))
    if rw is not None:
        say("link:    %s  (%s)" % (rw.link, link_status(link)))
        for p in rw.froms:
            say("from:    %s" % p.text)


def build_plan(paths, rw, conn):
    pl = plan_playlists(paths, rw)
    fp = plan_folders(paths, rw.link)
    plans = plan_metadb(conn, rw)
    return pl, fp, plans


def run_dry(paths, rw, link):
    live = is_live(paths.profile)
    header("dry run (writes nothing)", paths, live, rw, link)
    if not os.path.isfile(paths.metadb):
        raise Failure("%s not found" % paths.metadb)
    guard(paths, live, "apply", strict=False)
    paths.metadb_sidecars(strict=False)
    stale = paths.stale_staging()
    if stale:
        say("note: --apply would refuse: leftovers of an unfinished run: %s" % ", ".join(stale))
    conn = open_profile_db(paths.metadb, live)
    try:
        pl, fp, plans = build_plan(paths, rw, conn)
    finally:
        conn.close()
    report(pl, fp, plans, rw.froms, rw.link)
    say("OK: dry run, nothing written")
    return 0


def run_apply(paths, rw, link):
    live = is_live(paths.profile)
    header("apply", paths, live, rw, link)
    if not os.path.isfile(paths.metadb):
        raise Failure("%s not found" % paths.metadb)
    guard(paths, live, "apply", strict=True)
    stale_check(paths)
    sidecars = paths.metadb_sidecars(strict=True)

    playlists = paths.playlist_files()
    # -shm is left out: it is shared memory, and a reader (this tool's own
    # planning pass on a WAL database) may touch it.
    watched = [paths.metadb, paths.metadb + "-wal"] + playlists + [paths.folders]
    prints = {p: fingerprint(p) for p in watched}

    conn = open_profile_db(paths.metadb, live)
    try:
        pl, fp, plans = build_plan(paths, rw, conn)
    finally:
        conn.close()
    report(pl, fp, plans, rw.froms, rw.link)
    if not pl.changes and fp.new_bytes is None and plan_changes(plans) == 0:
        say("OK: nothing to change")
        return 0
    # The staged copy is planned again and must come out identical; only the
    # digest of this first plan is kept, to halve peak memory.
    live_digest = plan_digest(plans)
    del plans

    rels, dirs = backup_set(paths, playlists, sidecars)
    db_size = os.path.getsize(paths.metadb)
    need = sum(os.path.getsize(os.path.join(paths.profile, r)) for r in rels) + db_size \
        + db_size // 10 + (64 << 20)
    avail = free_bytes(paths.profile)
    if avail < need:
        raise Failure("not enough free space: need %s (backup + staged copy), have %s"
                      % (human(need), human(avail)))

    say("backing up ...")
    try:
        bdir, manifest = make_backup(paths, rels, dirs, rw.link, rw.froms,
                                     [PLAYLISTS + "/" + os.path.basename(p) for p, _, _ in pl.changes])
    except OSError as e:
        raise Failure("backup failed (%s); nothing was changed" % e)
    say("backup: %s (%d files)" % (bdir, len(manifest["files"])))

    staged = []   # (staged path, target path, backup rel)
    try:
        say("staging ...")
        for path, new, _ in pl.changes:
            tmp = path + STAGE_SUFFIX
            write_new(tmp, new, mode_from=path)
            staged.append((tmp, path, PLAYLISTS + "/" + os.path.basename(path)))
        if fp.new_bytes is not None:
            tmp = paths.folders + STAGE_SUFFIX
            write_new(tmp, fp.new_bytes, mode_from=paths.folders)
            staged.append((tmp, paths.folders, os.path.relpath(paths.folders, paths.profile)))
        size, digest = copy_file(paths.metadb, paths.staged_db)
        want = manifest["files"][METADB]
        if (size, digest) != (want["size"], want["sha256"]):
            raise Failure("metadb changed between backup and staging")
        staged.insert(0, (paths.staged_db, paths.metadb, METADB))

        conn = sqlite3.connect(paths.staged_db, timeout=15, isolation_level=None)
        try:
            plans = plan_metadb(conn, rw)
            if plan_digest(plans) != live_digest:
                raise Failure("the staged metadb plans differently from the live one")
            say("rewriting the staged metadb ...")
            execute_plan(conn, plans)
        except BaseException:
            conn.close()
            raise
        finish_staged_db(conn, paths.staged_db)

        say("verifying ...")
        verify_staged_db(paths.staged_db, plans, rw)
        for tmp, target, _ in staged:
            if target == paths.metadb:
                continue
            with open(target, "rb") as f:
                old = f.read()
            with open(tmp, "rb") as f:
                new = f.read()
            if target == paths.folders:
                urls, trailing = parse_folders(new, tmp)
                if urls != [rw.link.encode("utf-8")] or trailing != parse_folders(old, target)[1]:
                    raise Failure("staged folders file does not hold exactly the link root")
            else:
                expect = dict((p, b) for p, b, _ in pl.changes)[target]
                if new != expect:
                    raise Failure("staged %s does not read back as written" % tmp)
                verify_playlist(old, new, rw, target)

        guard(paths, live, "apply", strict=True)
        sidecars = paths.metadb_sidecars(strict=True)
        changed = [p for p in watched if fingerprint(p) != prints[p]]
        if changed:
            raise Failure("changed since the start, nothing swapped: %s" % ", ".join(changed))
    except BaseException:
        for tmp, _, _ in staged:
            remove_quietly(tmp)
        for s in ("-wal", "-shm", "-journal"):
            remove_quietly(paths.staged_db + s)
        remove_quietly(paths.staged_db)
        say("nothing was swapped; the profile is unchanged. Backup kept: %s" % bdir)
        raise

    # The old database's empty -wal and its -shm go with it; they are in the
    # backup unless they appeared after it (then they hold no data).
    ops = [("replace", tmp, target, rel) for tmp, target, rel in staged[:1]]
    ops += [("remove", None, paths.metadb + s, METADB + s) for s in sidecars]
    ops += [("replace", tmp, target, rel) for tmp, target, rel in staged[1:]]
    fail_at = int(os.environ.get(ENV_FAIL_SWAP) or 0)
    crash_at = int(os.environ.get(ENV_CRASH_SWAP) or 0)
    say("swapping %d files ..." % len(ops))
    try:
        for n, (kind, tmp, target, _) in enumerate(ops, 1):
            if n == crash_at:
                os._exit(70)
            if n == fail_at:
                raise OSError("injected failure at swap step %d (%s)" % (n, ENV_FAIL_SWAP))
            if kind == "replace":
                os.replace(tmp, target)
            else:
                os.unlink(target)
    except BaseException as e:
        say("swap failed: %s" % e)
        say("restoring every item from %s ..." % bdir)
        problems = []
        for kind, tmp, target, rel in ops:
            if rel in manifest["files"]:
                try:
                    restore_file(bdir, manifest, rel, paths.profile)
                except Exception as e2:
                    problems.append("%s: %s" % (rel, e2))
            if tmp:
                remove_quietly(tmp)
        if problems:
            for p in problems:
                say("  NOT restored: %s" % p)
            raise Failure("swap failed and %d item(s) could not be restored; copy them back from %s "
                          "by hand before starting foobar2000" % (len(problems), bdir))
        raise Failure("swap failed; all %d items restored from the backup, byte-identical" % len(ops))

    # The swapped file is the verified staged copy; this only confirms it opens.
    try:
        conn = open_ro(paths.metadb, immutable=True)
        try:
            n = conn.execute("SELECT count(*) FROM metadb").fetchone()[0]
        finally:
            conn.close()
    except sqlite3.Error as e:
        raise Failure("the swapped metadb does not open (%s); roll back with --rollback %s" % (e, bdir))
    if n != plans[0].before - len(plans[0].deletes):
        raise Failure("swapped metadb has %d rows, expected %d; roll back with --rollback %s"
                      % (n, plans[0].before - len(plans[0].deletes), bdir))
    manifest["post_swap"] = {rel: list(fingerprint(os.path.join(paths.profile, rel)))
                             for rel in [METADB] + manifest["rewritten"]}
    try:
        write_manifest(bdir, manifest)
    except OSError as e:
        say("warning: could not record the post-swap state in the manifest (%s); --rollback "
            "will not be able to list changes made after the migration" % e)
    say("backup: %s" % bdir)
    say("undo:   %s --profile '%s' --rollback '%s'" % (sys.argv[0], paths.profile, bdir))
    say("        (if config.sqlite changes before then, e.g. volume_registry_prune.sh --apply, "
        "add --restore-config or --keep-config)")
    say("OK: migrated %d playlist lines, %d metadb values, folders %s"
        % (pl.lines, plan_changes(plans), "rewritten" if fp.new_bytes is not None else "unchanged"))
    return 0


def load_manifest(bdir, paths):
    mpath = os.path.join(bdir, MANIFEST)
    if not os.path.isfile(mpath):
        raise Failure("%s has no %s; not a backup made by this tool" % (bdir, MANIFEST))
    with open(mpath, "rb") as f:
        manifest = json.loads(f.read().decode("utf-8"))
    if manifest.get("tool") != "shadow_link_migrate":
        raise Failure("%s is not a shadow_link_migrate manifest" % mpath)
    owner = manifest.get("profile", "")
    if not (same_dir(os.path.dirname(os.path.abspath(bdir)), paths.profile)
            or (os.path.isdir(owner) and same_dir(owner, paths.profile))):
        raise Failure("backup %s was made for %s, not %s" % (bdir, owner, paths.profile))
    for rel, want in sorted(manifest["files"].items()):
        p = os.path.join(bdir, rel)
        if not os.path.isfile(p) or sha256_file(p) != (want["size"], want["sha256"]):
            raise Failure("backup file %s is missing or damaged" % p)
    if METADB not in manifest["files"]:
        raise Failure("backup %s has no metadb.sqlite" % bdir)
    return manifest


def config_state(paths, files):
    """'absent' (no config.sqlite in the backup), 'same' or 'changed'."""
    if CONFIG not in files:
        return "absent"
    if not os.path.isfile(paths.config) or \
            sha256_file(paths.config) != (files[CONFIG]["size"], files[CONFIG]["sha256"]):
        return "changed"
    wal = paths.config + "-wal"
    if os.path.exists(wal) and os.path.getsize(wal) > 0:
        return "changed"
    return "same"


def new_dir_name(paths, prefix):
    ts = time.strftime("%Y%m%d-%H%M%S")
    d = os.path.join(paths.profile, prefix + ts)
    n = 2
    while os.path.lexists(d):
        d = os.path.join(paths.profile, "%s%s-%d" % (prefix, ts, n))
        n += 1
    return d


def run_rollback(paths, bdir, config_choice):
    live = is_live(paths.profile)
    header("rollback from %s" % bdir, paths, live)
    if not os.path.isdir(bdir):
        raise Failure("%s is not a directory" % bdir)
    guard(paths, live, "rollback", strict=True)
    paths.metadb_sidecars(strict=True)
    manifest = load_manifest(bdir, paths)
    files = manifest["files"]
    say("backup verified against its manifest (%d files)" % len(files))

    # config.sqlite holds the volume registry. volume_registry_prune.sh, run
    # after a migration, deletes the old volume ID, and the mac-volume:// paths
    # this rollback brings back cannot resolve without it.
    restore_config = False
    cfg = config_state(paths, files)
    if cfg == "changed":
        if config_choice is None:
            raise Failure("config.sqlite differs from the backup (volume_registry_prune.sh --apply or "
                          "foobar2000 changed it since). The restored mac-volume:// paths need the "
                          "volume registry it holds. Re-run with --restore-config to restore it from "
                          "the backup too, or --keep-config to keep it as it is.")
        if config_choice == "restore":
            w = paths.config + "-wal"
            if os.path.exists(w) and os.path.getsize(w) > 0:
                raise Failure("%s is not empty (foobar2000 running or not shut down cleanly)" % w)
            restore_config = True
            say("config.sqlite differs from the backup: restoring it too (--restore-config)")
        else:
            say("WARNING: config.sqlite differs from the backup and is kept (--keep-config). The restored "
                "mac-volume:// paths may not resolve until their volume registry entry is restored "
                "(the backup copy is %s)." % os.path.join(bdir, CONFIG))
    elif config_choice:
        say("note: config.sqlite %s; --%s-config has nothing to do"
            % ("matches the backup" if cfg == "same" else "is not in the backup", config_choice))

    # Leftovers of an interrupted apply or rollback: only names this tool
    # creates. The backup is verified, so they are not needed.
    for p in paths.stale_staging():
        remove_quietly(p)
        say("removed leftover of an unfinished run: %s" % p)

    db_rels = [r for r in (METADB, METADB + "-wal", METADB + "-shm") if r in files]
    cfg_rels = [r for r in (CONFIG, CONFIG + "-wal", CONFIG + "-shm") if r in files] if restore_config else []
    all_pl = sorted(r for r in files if r.startswith(PLAYLISTS + "/"))
    if "rewritten" in manifest:
        pl_rels = sorted(r for r in manifest["rewritten"] if r in files)
        if len(pl_rels) < len(all_pl):
            say("restoring the %d playlists the migration rewrote; the other %d are left as they are"
                % (len(pl_rels), len(all_pl) - len(pl_rels)))
    else:
        pl_rels = all_pl
        say("note: this backup does not record which playlists the migration rewrote; "
            "restoring all %d" % len(pl_rels))
    lib_rels = sorted(r for r in files if r.startswith(LIBRARY + "/"))
    has_lib = LIBRARY in manifest.get("dirs", [])
    file_rels = db_rels + cfg_rels + pl_rels

    need = sum(files[r]["size"] for r in file_rels + lib_rels) + (64 << 20)
    avail = free_bytes(paths.profile)
    if avail < need:
        raise Failure("not enough free space: need %s, have %s" % (human(need), human(avail)))

    aside = new_dir_name(paths, ASIDE_PREFIX)
    post = manifest.get("post_swap")
    if post is None:
        say("note: the backup has no record of the profile right after the migration (the apply did "
            "not finish, or an older version made it); changes made since cannot be listed")
    else:
        since = [rel for rel, fp in sorted(post.items())
                 if fingerprint(os.path.join(paths.profile, rel)) != tuple(fp)]
        if since:
            say("WARNING: changed since the migration: %s. The rollback replaces them with the "
                "pre-migration backup, so those changes (play counts, playlist edits) are undone; "
                "the current versions are moved to %s." % (", ".join(since), aside))

    watched = [os.path.join(paths.profile, r) for r in file_rels]
    watched += [paths.metadb, paths.metadb + "-wal", paths.folders]
    if restore_config:
        watched += [paths.config, paths.config + "-wal"]
    watched = sorted(set(watched))
    prints = {p: fingerprint(p) for p in watched}

    lib_tmp = os.path.join(paths.profile, LIBRARY + RESTORE_SUFFIX)
    items = []    # (staged, target)
    try:
        say("staging restore copies ...")
        for rel in file_rels:
            target = os.path.join(paths.profile, rel)
            if not os.path.isdir(os.path.dirname(target)):
                os.makedirs(os.path.dirname(target))
            copy_file(os.path.join(bdir, rel), target + RESTORE_SUFFIX)
            items.append((target + RESTORE_SUFFIX, target))
        if has_lib:
            for d in manifest["dirs"]:
                os.makedirs(os.path.join(lib_tmp, os.path.relpath(d, LIBRARY)), exist_ok=True)
            for rel in lib_rels:
                copy_file(os.path.join(bdir, rel), os.path.join(lib_tmp, os.path.relpath(rel, LIBRARY)))
            items.append((lib_tmp, paths.library))
        for rel in file_rels:
            p = os.path.join(paths.profile, rel) + RESTORE_SUFFIX
            if sha256_file(p) != (files[rel]["size"], files[rel]["sha256"]):
                raise Failure("restore copy %s does not match the backup" % p)
        for rel in lib_rels:
            p = os.path.join(lib_tmp, os.path.relpath(rel, LIBRARY))
            if sha256_file(p) != (files[rel]["size"], files[rel]["sha256"]):
                raise Failure("restore copy %s does not match the backup" % p)
        guard(paths, live, "rollback", strict=True)
        paths.metadb_sidecars(strict=True)
        changed = [p for p in watched if fingerprint(p) != prints[p]]
        if changed:
            raise Failure("changed since the start, nothing swapped: %s" % ", ".join(changed))
    except BaseException:
        for tmp, _ in items:
            remove_quietly(tmp)
        remove_quietly(lib_tmp)
        say("nothing was swapped; the profile is unchanged")
        raise

    # Current files are moved aside, not deleted: a rollback can be undone too.
    extra = [paths.metadb + s for s in ("-wal", "-shm")
             if os.path.exists(paths.metadb + s) and METADB + s not in files]
    if restore_config:
        extra += [paths.config + s for s in ("-wal", "-shm")
                  if os.path.exists(paths.config + s) and CONFIG + s not in files]
    done = []     # (src, dst) renames, undone in reverse on failure
    fail_at = int(os.environ.get(ENV_FAIL_SWAP) or 0)
    step = 0
    say("swapping ...")
    try:
        os.mkdir(aside)
        for target in extra:
            step += 1
            if step == fail_at:
                raise OSError("injected failure at swap step %d" % step)
            dst = os.path.join(aside, os.path.relpath(target, paths.profile))
            os.rename(target, dst)
            done.append((target, dst))
        for tmp, target in items:
            step += 1
            if step == fail_at:
                raise OSError("injected failure at swap step %d" % step)
            if os.path.lexists(target):
                dst = os.path.join(aside, os.path.relpath(target, paths.profile))
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                os.rename(target, dst)
                done.append((target, dst))
            os.rename(tmp, target)
            done.append((tmp, target))
    except BaseException as e:
        say("swap failed: %s; undoing ..." % e)
        problems = []
        for src, dst in reversed(done):
            try:
                os.rename(dst, src)
            except OSError as e2:
                problems.append("%s -> %s: %s" % (dst, src, e2))
        for tmp, _ in items:
            remove_quietly(tmp)
        if problems:
            for p in problems:
                say("  NOT undone: %s" % p)
            raise Failure("rollback swap failed and could not be fully undone; files are in %s" % aside)
        shutil.rmtree(aside, ignore_errors=True)
        raise Failure("rollback swap failed; the profile is as it was before the rollback")

    bad = []
    for rel in file_rels + lib_rels:
        p = os.path.join(paths.profile, rel)
        if not os.path.isfile(p) or sha256_file(p) != (files[rel]["size"], files[rel]["sha256"]):
            bad.append(rel)
    if has_lib:
        present = set()
        for root, _, fnames in os.walk(paths.library):
            present.update(os.path.relpath(os.path.join(root, n), paths.profile) for n in fnames)
        bad += sorted(present - set(lib_rels))
    if bad:
        raise Failure("restored files differ from the backup: %s" % ", ".join(bad))
    say("restored %d metadb file(s), %s%d playlist(s), %s"
        % (len(db_rels), "%d config file(s), " % len(cfg_rels) if cfg_rels else "", len(pl_rels),
           "library-v2.0 (%d files)" % len(lib_rels) if has_lib else "no library-v2.0"))
    say("the files they replaced are in %s; delete it once foobar2000 works" % aside)
    say("OK: rolled back; restored files are byte-identical to the backup")
    return 0


def read_registry(config, live):
    """{UUID (upper case): originalPath} from a consistent in-memory snapshot."""
    src = open_profile_db(config, live)
    mem = sqlite3.connect(":memory:")
    try:
        src.backup(mem)
    finally:
        src.close()
    try:
        rows = mem.execute("SELECT name, value FROM configStrings "
                           "WHERE name LIKE 'mac.volume.%.originalPath'").fetchall()
    except sqlite3.OperationalError:
        rows = []
    mem.close()
    reg = {}
    for name, value in rows:
        u = name[len("mac.volume."):-len(".originalPath")]
        if re.fullmatch(UUID, u):
            reg[u.upper()] = value
    return reg


def is_share_path(path, share):
    """volume_registry_prune.sh's rule: /Volumes/<share> or /Volumes/<share>-N,
    case-insensitive (ASCII), nothing below it."""
    if not isinstance(path, str) or not path.startswith("/Volumes/"):
        return False
    base = path[len("/Volumes/"):].translate(ASCII_LOWER)
    s = share.translate(ASCII_LOWER)
    if "/" in base:
        return False
    return base == s or (base.startswith(s + "-") and re.fullmatch(r"[0-9]+", base[len(s) + 1:]) is not None)


def run_check(paths, froms, link_url, link, share):
    live = is_live(paths.profile)
    header("check (writes nothing)", paths, live)
    if link_url:
        say("link:    %s  (%s)" % (link_url, link_status(link)))
    reg = read_registry(paths.config, live) if os.path.isfile(paths.config) else {}
    share_ids = sorted(u for u, p in reg.items() if is_share_path(p, share))
    say("registry: %d volume IDs; share %r: %s" % (
        len(reg), share, ", ".join("%s (%s)" % (u, reg[u]) for u in share_ids) or "none"))
    prefixes = []
    seen = set()
    for p in [Prefix("mac-volume://%s/" % u) for u in share_ids] + froms:
        if p.key not in seen:
            seen.add(p.key)
            prefixes.append(p)
    counts = [Counter() for _ in prefixes]
    files_hit = [set() for _ in prefixes]
    under_link = Counter()
    ids = Counter()

    def tally(value, category, fname=None):
        for i, p in enumerate(prefixes):
            if p.contained_in(value):
                counts[i][category] += 1
                if fname:
                    files_hit[i].add(fname)
                break
        if link_url and link_url in value:
            under_link[category] += 1

    for pth in paths.playlist_files():
        with open(pth, "rb") as f:
            data = f.read()
        if data.startswith(BOM):
            data = data[len(BOM):]
        for raw in data.splitlines():
            tally(raw.decode("utf-8", "replace"), "playlist lines", os.path.basename(pth))
    categories = ["playlist lines"]
    if os.path.isfile(paths.metadb):
        conn = open_profile_db(paths.metadb, live)
        try:
            for (v,) in conn.execute("SELECT name FROM metadb"):
                if isinstance(v, str):
                    tally(v, "metadb rows")
                    for m in MAC_VOLUME_ID_RE.finditer(v):
                        ids[m.group(1).upper()] += 1
            categories.append("metadb rows")
            for table, guid in discover(conn):
                cat = "index %s rows" % guid
                categories.append(cat)
                for (v,) in conn.execute('SELECT filename FROM "%s"' % table):
                    if isinstance(v, str):
                        tally(v, cat)
        finally:
            conn.close()
    if ids:
        say("mac-volume IDs in metadb:")
        for u, n in sorted(ids.items()):
            say("    %s: %d rows (%s)" % (u, n, reg.get(u, "not in registry")))
    if link_url:
        say("under the link: %s" % ", ".join("%s %d" % (c, under_link[c]) for c in categories))
    if os.path.isfile(paths.folders):
        with open(paths.folders, "rb") as f:
            urls, _ = parse_folders(f.read(), paths.folders)
        say("library folders: %s" % (", ".join(u.decode("utf-8", "replace") for u in urls) or "none"))
    total = 0
    hit = []
    for i, p in enumerate(prefixes):
        n = sum(counts[i].values())
        total += n
        if n:
            hit.append(p.text)
            say("drift under %s: %s" % (p.text, ", ".join("%s %d" % (c, counts[i][c]) for c in categories)))
            if files_hit[i]:
                say("    playlists: %s" % ", ".join(sorted(files_hit[i])))
    if not prefixes:
        say("OK: nothing to check (no share volume IDs in the registry, no --from given)")
        return 0
    if total == 0:
        say("OK: no drift")
        return 0
    say("FAILED: drift found: %d values under %d prefix(es). Fold them in with foobar2000 quit: "
        "--apply --link <link> %s" % (total, len(hit), " ".join("--from '%s'" % h for h in hit)))
    return 1


# --------------------------------------------------------------------------
# Arguments
# --------------------------------------------------------------------------

def link_to_url(link):
    path = os.path.abspath(os.path.expanduser(link))
    if any(c in path for c in "\r\n\0"):
        raise Failure("--link contains a line break or NUL")
    if path == "/":
        raise Failure("--link cannot be /")
    return path, "file://" + path.rstrip("/") + "/"


def parse_froms(values, link_url):
    froms = []
    for v in values:
        if not (MAC_VOLUME_PREFIX_RE.match(v) or FILE_PREFIX_RE.match(v)):
            raise Failure("--from %r must be mac-volume://<UUID>/ or file:///.../ (ending in /)" % v)
        froms.append(Prefix(v))
    for i, a in enumerate(froms):
        if link_url and (link_url.startswith(a.text) or a.text.startswith(link_url)):
            raise Failure("--from %s overlaps the link %s" % (a.text, link_url))
        for b in froms[i + 1:]:
            if a.key.startswith(b.key) or b.key.startswith(a.key):
                raise Failure("--from %s and %s overlap" % (a.text, b.text))
    return froms


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Move a foobar2000 profile from mac-volume:// paths to a fixed symlink path.",
        epilog="See the header of this script for the safety rules.")
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true", help="plan and self-check; write nothing")
    mode.add_argument("--apply", action="store_true", help="back up, stage, verify, swap")
    mode.add_argument("--check", action="store_true", help="report drift; write nothing")
    mode.add_argument("--rollback", metavar="DIR", help="restore from a backup made by --apply")
    ap.add_argument("--profile", default=os.path.expanduser("~/Library/foobar2000-v2"),
                    help="foobar2000 profile directory (default: %(default)s)")
    ap.add_argument("--link", metavar="PATH", help="the symlink path; rendered as file://<path>/")
    ap.add_argument("--from", dest="froms", action="append", default=[], metavar="PREFIX",
                    help="prefix to rewrite: mac-volume://<UUID>/ or file:///.../ (repeatable)")
    ap.add_argument("--share-name", default="music",
                    help="share mountpoint name for --check (default: %(default)s)")
    cfg = ap.add_mutually_exclusive_group()
    cfg.add_argument("--restore-config", dest="config_choice", action="store_const", const="restore",
                     help="--rollback: also restore config.sqlite when it differs from the backup")
    cfg.add_argument("--keep-config", dest="config_choice", action="store_const", const="keep",
                     help="--rollback: keep the current config.sqlite when it differs from the backup")
    args = ap.parse_args(argv)
    if (args.dry_run or args.apply) and (not args.link or not args.froms):
        ap.error("--dry-run and --apply need --link and at least one --from")
    if args.config_choice and not args.rollback:
        ap.error("--restore-config and --keep-config go with --rollback")

    try:
        profile = os.path.abspath(os.path.expanduser(args.profile))
        if not os.path.isdir(profile):
            raise Failure("profile %s is not a directory" % profile)
        paths = Paths(profile)
        link = link_url = None
        if args.link:
            link, link_url = link_to_url(args.link)
        froms = parse_froms(args.froms, link_url)
        if args.rollback:
            return run_rollback(paths, os.path.abspath(os.path.expanduser(args.rollback)),
                                args.config_choice)
        if args.check:
            return run_check(paths, froms, link_url, link, args.share_name)
        rw = Rewriter(froms, link_url)
        if args.dry_run:
            return run_dry(paths, rw, link)
        return run_apply(paths, rw, link)
    except Failure as e:
        say("FAILED: %s" % e)
        return 1
    except sqlite3.Error as e:
        say("FAILED: sqlite error: %s" % e)
        return 1
    except OSError as e:
        say("FAILED: %s" % e)
        return 1
    except KeyboardInterrupt:
        say("FAILED: interrupted")
        return 1


if __name__ == "__main__":
    sys.exit(main())
