# Intake 05 — Producer Protocol (Tidal & Future Source Plugins)

**Repo destination:** `docs/intake/intake-05-producer-protocol.md`
**Owner:** unassigned (P5; tidal plugin work) · **Depends on:** docs 1–3
**Status:** draft v1 — 2026-07-12

## Purpose

How trusted source plugins ("producers" — Tidal first; any future
Bandcamp/Qobuz fetcher) feed acquisitions into the intake pipeline.
Producers never place files into the music tree directly; they download,
hint, and trigger. All naming/genre/structure logic stays in the intake
brain (docs 1–3).

## Cache model — one store, two logical states

The plugin's precache directory is a single physical store, registered as an
income folder (`income.yaml`: `source_type: tidal, trust: api,
handling: promoted_only`).

| State | Meaning | Managed by |
|---|---|---|
| ephemeral | precached during streaming; no hint file present | plugin LRU |
| promoted | user chose "save to library"; `.intake-hint.json` present | intake CLI |

- Precache stores **untranscoded, library-quality** files (else promotion
  would require re-download).
- **Promotion = writing the hint file.** Nothing else. Atomic, instant,
  offline-safe (a later `intake scan` sweep finds it even if the CLI wasn't
  running).
- LRU MUST NOT evict any directory containing `.intake-hint.json` or
  `.intake.json` — those belong to intake (`gc` owns post-placement cleanup
  per doc 3).
- `scan` with `handling: promoted_only` ignores hint-less (ephemeral) dirs.

## Hint schema — `.intake-hint.json` v1

Hints are producer **input**, not intake state — the doc 3 boundary holds
(sidecars remain CLI-owned; the producer never writes them).

```json
{
  "schema": 1,
  "source": "tidal",
  "promoted_at": "2026-07-12T10:00:00+02:00",
  "source_ids": { "album": 12345678, "tracks": [111, 112, 113] },
  "meta": {
    "albumartist": "Aes Dana", "album": "(a) period.", "year": 2021,
    "label": "Ultimae Records",
    "quality": { "codec": "flac", "bit_depth": 24, "sample_rate": 96000 }
  }
}
```

## Flow

1. **Browse/stream** — plugin queries intake (journal via `intake status
   --json` / hash-metadata lookup) and renders an "in collection" marker;
   already-placed releases need no precache.
2. **Precache** — full-quality download alongside streaming (ephemeral).
3. **Save** — plugin writes the hint, then triggers `intake scan <dir>`.
4. **Resolve** — hint gives cluster confidence 1.0; no guessing.
5. **Identify** — short-circuits to `identification.status: "source_api"`;
   optional Discogs enrichment (label/cat#) may still run.
6. **Assign** — same ranked scorer (doc 2). Tier gates route 16/44 → hq,
   hi-res → uhq automatically.
7. **Suggest** — the plugin's existing folder-suggestion UI renders
   `proposal.ranked` (+ `intake collections` for the full picker). A manual
   pick = `intake assign --collection X --by user` → feedback loop.
8. **Approve/execute** — per income policy: `auto_approve: true` sends
   confident proposals straight to execute (verify + journal + canonical
   naming preserved); default `false`.

## Producer obligations (complete list)

1. Download untranscoded into its registered income folder.
2. Write `.intake-hint.json` on user save-intent.
3. Trigger `intake scan` (best effort; sweep is the fallback).
4. Render suggestions from `assign` output; report picks via CLI.
5. Never write into `/volume1/music/*` or mutate sidecars/tags/journal.

## Migration note (Tidal plugin, current behavior)

Current direct save into existing music folders is replaced by promotion.
UX stays: same suggestion dialog, now backed by ranked priors; with
`auto_approve` the perceived latency is unchanged, but every save gains
verification, journaling, and canonical naming.
