#!/usr/bin/env python3
"""Thin beets adapter for the intake CLI (doc 02, hard path).

Usage: beets_identify.py <release_dir> <file>... --json

Each <file> is one of the release's audio files, relative to <release_dir>
(the form of the sidecar's files[].path, so disc subdirs such as cd1/01.flac
come along). The caller picks the files; the shim never lists the dir. A file
that is absolute, has a `..` component, resolves outside <release_dir> or is
not an existing regular file is refused. Files without an audio extension and
AppleDouble `._` files are skipped.

Runs beets' autotag candidate search WITHOUT the import flow. Prints one JSON
document on stdout:

  {"candidates": [{"source": ..., "release_id": ..., "artist": ...,
    "album": ..., "year": ..., "label": ..., "catno": ..., "distance": ...,
    "track_mapping": {...}}]}

track_mapping is keyed by the <file> argument as given. Or {"error": "..."}.
Exit codes: 0 ok, 2 bad invocation (usage, a refused file, no audio file
among the files), 3 beets unavailable or beets error.

Supports beets 1.6 and 2.x. The API shape is detected, not assumed:
- beets >= 2.4 has no built-in MusicBrainz; every metadata source is a plugin.
  The shim loads the plugins named in the beets config's `plugins` list
  (beets' default config lists `musicbrainz`) before tagging. Older beets has
  MusicBrainz built in, and the shim loads no plugins there.
- beets >= 2.14 takes a Source and returns Proposal(candidates,
  recommendation); older beets takes the items and returns
  (artist, album, Proposal).

Only MusicBrainz ("mb") and Discogs ("discogs") candidates are reported;
candidates from other metadata plugins are dropped. Never writes to the
library or the release dir: pure read + network lookup.
"""

import contextlib
import inspect
import json
import os
import socket
import sys

AUDIO_EXTS = {".flac", ".mp3", ".wav", ".aiff", ".aif", ".m4a", ".ogg", ".ape", ".wv", ".dsf", ".dff"}
SOURCES = {"musicbrainz": "mb", "discogs": "discogs"}
MAX_CANDIDATES = 5
SOCKET_TIMEOUT_S = 30  # socket.setdefaulttimeout, in seconds (see main)
USAGE = "usage: beets_identify.py <release_dir> <file>... --json"

_STDOUT = sys.stdout


def is_audio(rel):
    name = os.path.basename(rel)
    return os.path.splitext(name)[1].lower() in AUDIO_EXTS and not name.startswith("._")


def emit(doc):
    _STDOUT.write(json.dumps(doc) + "\n")
    _STDOUT.flush()


def fail(code, error):
    emit({"error": error})
    sys.exit(code)


def load_metadata_plugins(plugins):
    """beets >= 2.4: load_plugins() takes no arguments and loads the config's
    `plugins` list itself (pluginpath, disabled_plugins and the legacy
    musicbrainz.enabled flag included). Older beets takes explicit names and
    has MusicBrainz built in, so nothing is loaded there."""
    if not inspect.signature(plugins.load_plugins).parameters:
        plugins.load_plugins()


def album_candidates(autotag, items):
    """Candidate AlbumMatches, best first, from either tag_album API shape."""
    # beets >= 2.14: tag_album(Source) -> Proposal(candidates, recommendation).
    # Older: tag_album(items) -> (cur_artist, cur_album, Proposal).
    arg = autotag.Source.from_items(items) if hasattr(autotag, "Source") else items
    result = autotag.tag_album(arg)
    proposal = result if hasattr(result, "candidates") else result[2]
    return list(proposal.candidates)


def serialize(candidates, rel_of):
    """rel_of: item.path -> the <file> argument it was read from."""
    out = []
    for match in candidates:
        info = match.info
        source = SOURCES.get((info.data_source or "").lower())
        if source is None:
            continue
        mapping = {}
        for item, track in (match.mapping or {}).items():
            name = rel_of.get(item.path)
            if name is None:  # not one of ours; never expected
                name = os.path.basename(os.fsdecode(item.path))
            mapping[name] = track.title or ""
        out.append(
            {
                "source": source,
                "release_id": str(info.album_id) if info.album_id else None,
                "artist": info.artist,
                "album": info.album,
                "year": str(info.year) if info.year else None,
                "label": info.label,
                "catno": info.catalognum,
                "distance": round(float(match.distance), 4),
                "track_mapping": mapping or None,
            }
        )
        if len(out) == MAX_CANDIDATES:
            break
    return out


def check_file(release_dir, rel):
    """Exit 2 unless `rel` names an existing regular file inside release_dir."""
    if os.path.isabs(rel) or ".." in rel.split("/"):
        fail(2, "file_outside_release_dir: %s" % rel)
    root = os.path.realpath(release_dir)
    real = os.path.realpath(os.path.join(root, rel))
    if os.path.commonpath([root, real]) != root:  # a symlink pointing out
        fail(2, "file_outside_release_dir: %s" % rel)
    if not os.path.isfile(real):
        fail(2, "file_not_found: %s" % rel)


def main():
    args = [a for a in sys.argv[1:] if a != "--json"]
    if len(args) < 2 or not os.path.isdir(args[0]):
        fail(2, USAGE)
    release_dir, files = args[0], args[1:]
    for rel in files:
        check_file(release_dir, rel)
    files = [f for f in files if is_audio(f)]
    if not files:
        fail(2, "no_audio_files")

    # Neither musicbrainzngs (beets 1.6's MusicBrainz client) nor beets sets a
    # socket timeout, so a stalled connection blocked the shim forever. With a
    # default one a stalled read raises socket.timeout, which musicbrainzngs
    # retries like other transient errors. Set before beets is imported. The
    # CLI also limits the whole run (structure.yaml assign.shim_timeout_s).
    socket.setdefaulttimeout(SOCKET_TIMEOUT_S)

    # Keep stdout pure JSON (beets and plugins may print), and make any
    # interactive prompt (e.g. discogs OAuth without a token) fail instead of
    # blocking or writing a token file.
    sys.stdin = open(os.devnull)
    with contextlib.redirect_stdout(sys.stderr):
        try:
            from beets import autotag, plugins
            from beets.library import Item
        except ImportError:
            fail(3, "beets_unavailable")

        try:
            items = [Item.from_path(os.fsencode(os.path.join(release_dir, f))) for f in files]
            rel_of = {item.path: f for item, f in zip(items, files)}
            load_metadata_plugins(plugins)
            out = serialize(album_candidates(autotag, items), rel_of)
        except Exception as exc:  # network failures, beets internals
            fail(3, "beets_error: %s" % exc)
    emit({"candidates": out})


if __name__ == "__main__":
    main()
