# Intake System — Overview & Decision Log

**Repo destination:** `knowledge_base/14_INTAKE_SYSTEM_OVERVIEW.md` (fb2k-components-mac-suite)
**Owner:** repo overseer
**Status:** draft v1 — 2026-07-11

## What this is

An end-to-end pipeline for ingesting new music (bought, downloaded, friend-shared)
into the canonical library on Amunet (`/volume1/music/music.hq` et al.), operated
primarily from foobar2000 via SimPlaylist, powered by a Bun CLI.

```
income folders ──▶ intake CLI ──▶ proposals (.intake.json sidecars)
 (downloads,        resolve            │
  slsk, todo…)      identify           ▼
                    assign        SimPlaylist + foo_jl_intake_mac
                                   (review, adjust, approve)
                                        │
                                        ▼
                              intake execute (copy → Amunet,
                              verify, tag, journal) → intake gc
```

## Document map & worker assignment

| Doc | File | Owner |
|-----|------|-------|
| 0 | `knowledge_base/14_INTAKE_SYSTEM_OVERVIEW.md` (this) | repo overseer |
| 1 | `docs/intake/intake-01-resolver-spec.md` | tools worker |
| 2 | `docs/intake/intake-02-assignment-spec.md` | tools worker |
| 3 | `docs/intake/intake-03-contract-spec.md` | **shared** — both workers comply; overseer guards changes |
| 4 | `docs/intake/intake-04-extension-spec.md` | extension worker |

Development order: doc 1 first (pure, testable against a music.todo copy);
doc 4 part A (decorator API) can proceed in parallel once doc 3 is accepted;
doc 2 second for the tools worker.

## Decisions (with rationale)

1. **CLI lives in `tools/intake/` in this repo.** Self-contained Bun package,
   own build. Zero personal data — all paths/maps/priors come from the private
   rules repo (Forgejo). Split-out later is a `git mv` because the boundary is
   the contract (doc 3), not the directory.
2. **beets: yes, as engine behind an adapter.** A thin Python shim exposes
   `identify <dir> → JSON candidates` using beets' autotag/discogs/chroma
   internals. Bun CLI orchestrates; beets never owns the flow. Fast path
   (own-naming-convention parse + Discogs API) is tried before the shim.
3. **Sidecar-first, files untouched until approval.** Working state lives in
   `.intake.json` per release root. Audio files get permanent provenance tags
   only at execute.
4. **Copy + verified GC, never move.** Execute copies to Amunet, verifies by
   audio hash, marks `placed`. `intake gc` deletes local copies later, after
   re-verification; may relocate into the SSD `dj/` zone instead when the
   target collection is DJ-mirrored.
5. **Assignment engine is a shared pure module.** `assign(artist, meta, rules)
   → ranked folders` serves intake, the Tidal cache feature, and any future
   downloader. One brain, N consumers.
6. **GUI = SimPlaylist decorator-provider extension point** (generic), with
   `foo_jl_intake_mac` as first provider. SimPlaylist stays intake-agnostic.
7. **Sync (later phase): field-level three-way tag merge** with base snapshots
   keyed by audio hash; no side-ownership discipline required. Out of scope for
   the intake milestone; journal design (doc 3) is forward-compatible with it.

## External state (private, rules repo on Forgejo)

`genre-map.yaml`, `label-map.yaml`, `styles.yaml`, `income.yaml`,
`structure.yaml`, `overrides.log.yaml` — layout specified in doc 2, appendix A.
Canonical structure doc: `music.hq-structure.md` (drafted; lives in the rules
repo, NOT here — it contains personal collection data).

## Amunet-side state (proposal)

New sibling `/volume1/music/music.meta/` holding `intake-journal.ndjson`
(append-only) and future sync-base snapshots. Deliberately a sibling of ALL
`music.*` tiers — one journal for the whole share. Follows the existing
`music.*` naming convention. **Needs Jenda's confirmation.**

## Open TBDs (block execute stage, not resolver development)

- The five structure decisions from `music.hq-structure.md` (artist-folder
  threshold, collabs, name normalization, singles slot, bracket style).
- music.todo processed via Mac mount vs on-NAS container run of the same CLI.
- Whether provenance tags are kept permanently or stripped after N months.
- Legacy `music` tree as low-weight prior source: yes/no.

## Phases

P1 resolver + sidecars (read-only) → P2 assignment engine + rules bootstrap →
P3 propose/approve/execute/gc → P4 extension (decorator API + intake component)
→ P5 Tidal-cache adoption of `assign` → P6 sync engine (separate milestone).
