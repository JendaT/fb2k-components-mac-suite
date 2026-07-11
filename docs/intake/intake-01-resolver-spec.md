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
- child dir names match disc patterns: `/^(cd|disc|disk|vinyl|side|lp)\s*[-_ ]?\w+$/i`, AND
- children share one (albumartist, album) cluster (album name may differ only
  by a disc suffix), OR children are untagged but parent name parses as a
  release per the naming convention.

### Pass 3 — split downward (dump folders)
Within one candidate, cluster files by normalized (albumartist|artist, album).
If >1 cluster with ≥2 files each → split into virtual roots (sidecar per
cluster, files enumerated explicitly; no file moves). Files not fitting any
cluster (singletons) → `singles` queue entries.

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
`<0.50` → `unresolved` (rendered for manual action, never auto-proposed).

### Untagged fallback chain
filename pattern parse (`NN - Title`, `NN. Title`, `Artist - Title`) →
parent dir name parse → fingerprint via identify stage (doc 2), not here.

## Edge cases (must-handle list)

- Archives (`zip,rar,7z`): `scan` unpacks to `<name>.unpacked/`; resolver
  treats unpacked dir; original archive referenced in sidecar `source.archive`.
- `iso/bin+cue`: flag `needs_review`, never auto-unpack.
- Mixed-quality duplicates in one dir (mp3 + flac of same tracks): cluster by
  (album, tracknumber); prefer lossless set as primary, mark other set
  `quality_shadow` in sidecar.
- Nested artist dumps (artist dir containing many release dirs): each release
  dir is its own root; artist dir is never a root if ≥2 children resolved.
- Hidden/system junk: skip `@eaDir`, `.DS_Store`, `._*`, `Thumbs.db`.
- Pre-existing sidecar: re-resolve only with `--force`; otherwise trust it.

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

Written at release root (or income-folder root for virtual/split roots).

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
