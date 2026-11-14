#!/usr/bin/env python3
"""Thin beets adapter for the intake CLI (doc 02, hard path).

Usage: beets_identify.py <release_dir> --json

Runs beets' autotag candidate search WITHOUT the import flow. Prints one JSON
document on stdout:

  {"candidates": [{"source": ..., "release_id": ..., "artist": ...,
    "album": ..., "year": ..., "label": ..., "catno": ..., "distance": ...,
    "track_mapping": {...}}]}

or {"error": "..."}. Exit codes: 0 ok, 2 bad invocation, 3 beets unavailable
or beets error.

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
import sys

AUDIO_EXTS = {".flac", ".mp3", ".wav", ".aiff", ".aif", ".m4a", ".ogg", ".ape", ".wv", ".dsf", ".dff"}
SOURCES = {"musicbrainz": "mb", "discogs": "discogs"}
MAX_CANDIDATES = 5

_STDOUT = sys.stdout


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


def serialize(candidates):
    out = []
    for match in candidates:
        info = match.info
        source = SOURCES.get((info.data_source or "").lower())
        if source is None:
            continue
        mapping = {}
        for item, track in (match.mapping or {}).items():
            name = os.path.basename(item.path.decode("utf-8", "replace") if isinstance(item.path, bytes) else str(item.path))
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


def main():
    args = [a for a in sys.argv[1:] if a != "--json"]
    if len(args) != 1 or not os.path.isdir(args[0]):
        fail(2, "usage: beets_identify.py <release_dir> --json")
    release_dir = args[0]

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

        paths = sorted(
            os.path.join(release_dir, n)
            for n in os.listdir(release_dir)
            if os.path.splitext(n)[1].lower() in AUDIO_EXTS and not n.startswith("._")
        )
        if not paths:
            fail(2, "no_audio_files")

        try:
            items = [Item.from_path(p.encode() if isinstance(p, str) else p) for p in paths]
            load_metadata_plugins(plugins)
            out = serialize(album_candidates(autotag, items))
        except Exception as exc:  # network failures, beets internals
            fail(3, "beets_error: %s" % exc)
    emit({"candidates": out})


if __name__ == "__main__":
    main()
