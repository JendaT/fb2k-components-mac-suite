# Intake 01 — Release-Root Resolver & Sidecar Schema

**Repo destination:** `docs/intake/intake-01-resolver-spec.md`
**Owner:** tools worker · **Depends on:** doc 3 (contract) for CLI conventions
**Status:** draft v1 — 2026-07-11

## Purpose

Given an income folder of arbitrary mess (flat soulseek dumps, Bandcamp zips,
nested artist folders, scene rips, multi-disc sets, loose singles, ISOs),
detect **release roots** — the directory unit that maps 1:1 to one release in
the canonical library — and persist findings as `.intake.json` sidecars.
`resolve` is **pure**: it never modifies, moves, or tags audio files.
Archives are the one exception: unpack happens in `scan` (pre-resolve) into a
sibling folder; originals kept until `gc`.

## Algorithm

### Pass 1 — candidate discovery (bottom-up)
Walk the tree depth-first. Every directory directly containing ≥1 audio file
(`flac,mp3,wav,aiff,m4a,ogg,ape,wv`) becomes a candidate unit. Read a tag
snapshot per file (ffprobe or music-metadata lib): albumartist, artist, album,
tracknumber, disc, date, plus codec/bitrate/samplerate/bitdepth.

### Pass 2 — merge upward (multi-disc)
Merge sibling candidates into their parent when:
- child dir names match the disc pattern: a prefix `cd|disc|disk|vinyl|side|lp`
  (any case) followed by a numeric index (`CD1`, `cd 2`, `disk-2`, `Disc 07`),
  optionally followed by a disc title after whitespace, a dash or a bracket
  (`CD1 - Disc Title`, `CD1 Disc Title`, `Disc 2 - X`); or by a single letter
  after a separator (`Side A`); or by a spelled-out number one–ten
  (`Disc One`). Any other word after the prefix is not a disc dir ("Disk
  Jockey", "Side Projects", "Discography"), AND
- children share one (albumartist, album) cluster (album name may differ only
  by a disc suffix), OR children are untagged but parent name parses as a
  release per the naming convention, OR the children's files (with the
  parent's own, if any) form one Various Artists release (below).

The disc number comes from the numeric or spelled index, else the files' disc
tags, else sibling order. Bootstrap (doc 2) uses the same disc-dir detector.

### Pass 3 — split downward (dump folders)
Within one candidate, cluster files by normalized (albumartist|artist, album).
If >1 cluster with ≥2 files each → split into virtual roots (sidecar per
cluster, files enumerated explicitly; no file moves). Files not fitting any
cluster (singletons) → `singles` queue entries. A candidate whose files form
one Various Artists release is not split: it is one root.

### Various Artists releases
Some compilations set each track's album artist to the track's own artist,
so the (albumartist, album) clusters split one release into per-artist roots
or singles. A file set is one VA release when all of these hold:
- every file has the same normalized album tag;
- the album-artist tags disagree (≥2 distinct values; a set whose album
  artist is absent or uniform already forms one cluster);
- ≥3 distinct lead credits (album artist, else artist, with a `feat.`/`ft.`/
  `featuring` guest suffix dropped), none on half the files or more, so an
  artist album with a few guest-credited tracks stays that artist's album;
- every file has a track position and no (disc, track) position is claimed
  twice, except by copies of the same track (same artist and title: quality
  shadows). This keeps two artists' same-titled albums apart (both have a
  track 1).

A VA root gets `cluster.albumartist` "Various Artists" and its purity signal
clusters by album alone. Doc 2 routes an artist of Various Artists (also
Various, VA, V.A., V/A) to `structure_slot: "compilations"`.

### Disc in the track number
When no file of a candidate has a disc tag, every file has a track number,
each is ≥101 and not a multiple of 100, and the hundreds present are 1..k
with no gap (101.., 201.., …), the resolver reads disc = ⌊n/100⌋, track =
n mod 100. Files merged from disc dirs must decode to their dir's disc
number, else the numbers stay plain. The decoded positions feed the track
sequence signal, the quality-shadow pairing and the VA position check only;
`files[].tags` keep the track numbers as read.

### Pass 4 — signals & confidence
Per root, compute confidence 0–1 from weighted signals:

| Signal | Weight (default) |
|---|---|
| tag cluster purity (share of files in majority cluster) | 0.35 |
| tracknumber sequence completeness (1..N, per disc) | 0.25 |
| release artifacts present (cue/log/nfo/m3u/cover.*/folder.*) | 0.15 |
| dir name parses as known naming convention (see doc 2 §naming) | 0.15 |
| codec/quality homogeneity | 0.10 |

Thresholds (config, `structure.yaml`): `≥0.80` → status `resolved`,
auto-eligible for propose; `0.50–0.79` → `resolved` + `needs_review: true`;
`<0.50` → status stays `new` + `needs_review: true` (doc 3 lifecycle has no
`unresolved` status; UIs render `new` roots as unresolved — manual action,
never auto-proposed).

### Untagged fallback chain
filename pattern parse (`NN - Title`, `NN. Title`, `Artist - Title`) →
parent dir name parse → fingerprint via identify stage (doc 2), not here.

### Cluster display values
`cluster.albumartist` and `cluster.album` come from tags (majority), the dir
name parse (doc 2 grammars) is the fallback. One narrow correction: a trailing
scene source token in the tag album (WEB, CD, VINYL, TAPE, FLAC, MP3, as in
"Album WEB") is dropped only when the dir name parse gives the same album
without it (normalized comparison). Any other tag album is kept as is. A
Various Artists release (above) is credited "Various Artists".
`files[].tags` record the tags as read, with one exception: a file merged
from a disc dir that has no disc tag gets the dir's disc number as `disc`.

## Edge cases (must-handle list)

- Archives (`zip,rar,7z`): `scan` unpacks to `<name>.unpacked/`; resolver
  treats unpacked dir; original archive referenced in sidecar `source.archive`.
  rar entries are verified against their header CRC32; encrypted,
  BLAKE2-only, multi-volume and solid RAR4 archives are refused.
- `iso/bin+cue`: flag `needs_review`, never auto-unpack.
- Mixed-quality duplicates in one dir (mp3 + flac of same tracks): cluster by
  (album, tracknumber); prefer lossless set as primary, mark each file of the
  other set with `"quality_shadow": true` in `files[]` and add a
  `quality_shadow_set:<codec>` entry to `quality.issues`. Signals are computed
  over primary (non-shadow) files.
- Nested artist dumps (artist dir containing many release dirs): each release
  dir is its own root; artist dir is never a root if ≥2 children resolved.
- Hidden/system junk: skip `@eaDir`, `.DS_Store`, `._*`, `Thumbs.db`.
- Pre-existing sidecar: re-resolve only with `--force`; otherwise trust it.
- FLAC with unset STREAMINFO MD5 (doc 3 v1.2, CR-003 option d): keyed
  `flacmd5:` + MD5 of the decoded audio (`flac -d --force-raw-format
  --endian=little --sign=signed`, streamed into the hasher), the value a
  correct STREAMINFO MD5 holds, so tag writes and a later repair keep the
  key. `flac_md5_unset` in `quality.issues` marks the value as computed. No
  repair at any stage: `resolve` never mutates inputs and `execute` never
  rewrites the audio of the copies. Without a usable decoder (`flac` not on
  PATH, or decoding fails, which often means a corrupt file) the file is
  keyed `fsha1:` (whole-file SHA1) with `flac_decoder_missing` or
  `flac_decode_failed` beside `flac_md5_unset`, the root gets
  `needs_review: true`, and execute writes no provenance tags to that file
  (issue `provenance_tags_skipped:flac_fsha1`). Verify re-checks each file
  against the key it was recorded with, so an `fsha1:` file still verifies
  after `flac` is installed. `flac` is a resolve-time dependency.

## Tier eligibility (normative)

`quality.tier_eligible` is computed per release from its file set
(rules configurable in `structure.yaml`, defaults below):

| Condition | tier_eligible |
|---|---|
| any DSD (dsf/dff) OR PCM above 16-bit/48 kHz | `uhq` |
| all lossless at ≤16/48, or tolerated high-bitrate lossy when marked unobtainable-lossless | `hq` |
| below lossy tolerance (e.g. <V0/~256 kbps) | `reject` (needs_review; never auto-proposed) |

Mixed sets (e.g. hi-res + redbook in one release) → highest tier of the
primary cluster; quality shadows noted in `quality.issues`.
`music` (legacy mp3 tree) is **never an intake target** — it is frozen;
it may serve as a low-weight prior source only (doc 2).

## Sidecar schema — `.intake.json` v1

Written at release root as `.intake.json`. Virtual/split roots have no
directory of their own: their sidecars are written in the candidate directory
(the dump dir) as `.intake.<id>.json`, one per cluster, with `"virtual": true`
and files enumerated explicitly. Singles-queue entries are per-file virtual
sidecars additionally marked `"singles": true` (their `cluster.album` is null;
they always carry `needs_review: true` until identify). `id` is deterministic
(hash of income folder, root path relative to it, and cluster file set), so
re-resolving reproduces the same id; `--force` re-resolve preserves the
existing id and appends a `re-resolved` history event. `files[].bitrate` is
integer kbps (lossy only, null for lossless); `discs` is
`[{ "dir": "CD1", "disc": 1 }, …]` for merged multi-disc roots, else null.

```json
{
  "schema": 1,
  "id": "itk_9f3ac2d1",
  "resolver_version": "0.1.0",
  "resolved_at": "2026-07-11T14:30:00+02:00",
  "source": { "income_folder": "slsk", "source_type": "soulseek",
              "archive": null },
  "virtual": false,
  "files": [
    { "path": "01 - Iliona.flac",
      "audio_hash": "flacmd5:af3e…",
      "codec": "flac", "sample_rate": 44100, "bit_depth": 16,
      "bitrate": null, "duration": 512.3,
      "tags": { "albumartist": "Aes Dana", "album": "Pollen",
                "tracknumber": 1, "date": "2012" } }
  ],
  "discs": null,
  "cluster": { "albumartist": "Aes Dana", "album": "Pollen",
               "confidence": 0.93, "needs_review": false,
               "signals": { "purity": 1.0, "seq": 1.0, "artifacts": 0.5,
                            "name_parse": 1.0, "quality_homog": 1.0 } },
  "quality": { "tier_eligible": "hq", "issues": [] },
  "identification": null,
  "proposal": null,
  "status": "resolved",
  "history": [
    { "ts": "2026-07-11T14:30:00+02:00", "event": "resolved",
      "by": "intake@0.1.0" } ]
}
```

`identification` and `proposal` objects are defined in doc 2; `status`
lifecycle and `audio_hash` algorithm are normative in doc 3.

`history[]` is append-only, one entry per transition or stage:
`{ "ts", "event", "by" }`. `by` is `intake@<CLI semver>`, the CLI that made
the transition (the resolver's own version is `resolver_version`, the
engine's is `proposal.engine_version`). A `rejected` entry (`intake reject`, doc 3) also
carries `"reason"` (free-form text) when `--reason` was given:
`{ "ts": "…", "event": "rejected", "by": "intake@0.2.0", "reason": "…" }`.

## CLI surface (this doc's commands)

```
intake scan   [<income>|--all]   # discover, unpack archives, then resolve
intake resolve <path> [--force]  # (re)detect roots, write sidecars
intake status [--json] [--filter status=…]
```

All commands support `--json` and `--dry-run` per doc 3 conventions.

## Testing

Fixture corpus: read-only copy of a `music.todo` slice (contains zips, ISO,
scene names, dumps). Golden tests: fixture tree → expected sidecar set.
Property: resolver idempotent (second run without `--force` = no-op).
Acceptance gate for P1: ≥90% of fixture roots correctly bounded; zero file
mutations (verified by tree hash before/after).
