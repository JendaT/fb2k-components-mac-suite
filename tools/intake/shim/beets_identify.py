#!/usr/bin/env python3
"""Thin beets adapter for the intake CLI (doc 02, hard path).

Usage: beets_identify.py <release_dir> --json

Uses beets' autotag internals (candidate search across the sources configured
in the user's beets config: MusicBrainz, discogs plugin, chroma/fpcalc when
installed) WITHOUT the import flow. Prints one JSON document on stdout:

  {"candidates": [{"source": ..., "release_id": ..., "artist": ...,
    "album": ..., "year": ..., "label": ..., "catno": ..., "distance": ...,
    "track_mapping": {...}}]}

Exit codes: 0 ok, 2 bad invocation, 3 beets unavailable.
Never writes to the library or the release dir; pure read + network lookup.
"""

import json
import os
import sys

AUDIO_EXTS = {".flac", ".mp3", ".wav", ".aiff", ".aif", ".m4a", ".ogg", ".ape", ".wv", ".dsf", ".dff"}


def fail(code, error):
    print(json.dumps({"error": error}))
    sys.exit(code)


def main():
    args = [a for a in sys.argv[1:] if a != "--json"]
    if len(args) != 1 or not os.path.isdir(args[0]):
        fail(2, "usage: beets_identify.py <release_dir> --json")
    release_dir = args[0]

    try:
        from beets import autotag
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
        _artist, _album, proposal = autotag.tag_album(items)
        candidates = list(proposal.candidates)
    except Exception as exc:  # network failures, beets internals
        fail(3, "beets_error: %s" % exc)

    out = []
    for match in candidates[:5]:
        info = match.info
        mapping = {}
        for item, track in (match.mapping or {}).items():
            name = os.path.basename(item.path.decode("utf-8", "replace") if isinstance(item.path, bytes) else str(item.path))
            mapping[name] = track.title or ""
        out.append(
            {
                "source": "discogs" if (info.data_source or "").lower() == "discogs" else "mb",
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
    print(json.dumps({"candidates": out}))


if __name__ == "__main__":
    main()
