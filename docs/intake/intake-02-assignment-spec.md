# Intake 02 — Identification & Genre-Folder Assignment Engine

**Repo destination:** `docs/intake/intake-02-assignment-spec.md`
**Owner:** tools worker · **Depends on:** doc 1 (sidecars), doc 3 (contract)
**Status:** draft v1 — 2026-07-11

## Purpose

Two pure modules invoked after resolve:

1. **identify** — establish what the release *is* (canonical artist, title,
   year, label, cat#, Discogs/MB ids).
2. **assign** — decide *where it belongs*: ranked genre-collection folders
   with confidence. Target ≥90% top-1 accuracy on typical ingest.

`assign` is a standalone library export — consumed by intake, by the Tidal
cache feature in the tidal integration plugin, and by future downloaders.

## Identify

### Fast path (try first)
1. Parse folder name against known conventions (ordered grammar):
   `Artist [YYYY] Title (Label; Cat#)`, `Artist [YYYY] Title [Label, Cat#]`,
   Discogs-block variant, scene pattern `Artist-Title-(CAT)-WEB-YYYY-GRP`,
   underscore variants. Emit parsed fields + which grammar matched.
2. Merge with embedded tags (tags win for artist/title, folder wins for
   label/cat# when tags lack them).
3. Confirm against Discogs API (search by artist+title+cat#). One confirmed
   match → done (`identification.status: "fast_path"`).

### Hard path — beets shim
Python adapter `tools/intake/shim/beets_identify.py` (thin, ~100 lines):
uses beets internals (autotag candidate search, discogs plugin, chroma/fpcalc
fingerprinting) **without** the import flow. Interface:

```
beets_identify.py <release_dir> --json
→ { "candidates": [ { "source": "discogs|mb", "release_id": …,
     "artist": …, "album": …, "year": …, "label": …, "catno": …,
     "distance": 0.08, "track_mapping": {...} } ] }
```

Invoked as subprocess by the CLI only when fast path fails or its Discogs
confirmation is ambiguous. Distance ≤0.15 → accept top candidate; else attach
top 3 as `identification.candidates` and set `needs_review`.

## Tier routing (precedes collection choice)

Tiers are first-class in `structure.yaml`:

```yaml
tiers:
  music.uhq: { root: /volume1/music/music.uhq, gate: hires, growth: active }
  music.hq:  { root: /volume1/music/music.hq,  gate: lossless-first, growth: primary }
  music:     { root: /volume1/music/music,     gate: none, growth: frozen }  # never a target
```

`assign` receives `tier_eligible` from the sidecar (doc 1) and resolves the
tier root first; the collection scorer then picks the genre folder **within**
that tier. The genre map is tier-independent (one artist → one collection,
regardless of tier); cross-tier duplicates are expected and legal (uhq copy =
quality shadow of an hq release; distinct audio_hash, distinct journal rows).

## Assign — ranked evidence scorer

```
score(folder) = wa·P(folder|artist) + wl·P(folder|label)
              + ws·simVote(folder)  + wt·styleHint(folder)
```
Default weights `wa=0.5, wl=0.25, ws=0.15, wt=0.10` (config in
`structure.yaml`; tune after feedback data exists). Evaluation is lazy: if the
artist prior is unique and strong (single folder, ≥2 releases), short-circuit
with confidence 0.95+ and skip network tiers.

### Tier 1 — artist prior
From `genre-map.yaml`: P(folder|artist) = release-count distribution of the
artist across collections. Matching is normalized: casefold, strip diacritics,
`&`↔`and`, articles. Collab handling: try full string first (exceptions list
covers names containing separators); else split on `&, feat., ft., vs., x,
meets, with` — each known member votes with its own prior, averaged.
Alias expansion: on first miss, fetch Discogs artist aliases/ANVs + groups
once, cache into `genre-map.yaml` under `aliases:`.

### Tier 2 — label prior
From `label-map.yaml`: P(folder|label) from the label's release distribution
in the existing tree (labels are highly genre-coherent — Ultimae ⇒ Psychill).
Catches "new artist, known label".

### Tier 3 — similarity vote
- Last.fm `artist.getSimilar` (API client exists in the suite / scrobbler):
  intersect similar artists with genre-map; each known one votes for its
  folder weighted by Last.fm match score. Cache per artist, TTL 90d.
- Discogs styles/genres of the identified release mapped through
  `styles.yaml` (hand-curated style → folder hints).

### Output (into sidecar `proposal`)
```json
"proposal": {
  "engine_version": "0.1.0",
  "ranked": [
    { "collection": "[Psychill & Chillout & Psydub]", "score": 0.91,
      "evidence": { "artist_prior": 0.95, "label_prior": 0.88 } },
    { "collection": "[Ambient]", "score": 0.31, "evidence": { … } }
  ],
  "target_collection": "[Psychill & Chillout & Psydub]",
  "confidence": 0.91, "margin": 0.60,
  "target_path": "/volume1/music/music.hq/[Psychill & Chillout & Psydub]/Aes Dana/Aes Dana [2012] Pollen (Ultimae Records; inre042)",
  "structure_slot": "artist",        // artist | releases | compilations | singles
  "assigned_by": "engine",           // engine | user
  "alternates_shown": true
}
```
Confidence = top score; `margin` = top − second. `confidence <0.6` or
`margin <0.2` ⇒ `needs_review` (extension shows the picker prominently).
Naming/slot computation applies `structure.yaml` (threshold, templates —
values pending the five TBDs; implement behind config).

### Feedback loop
Every user override (`assign --collection X --by user`) appends to
`overrides.log.yaml` and increments the artist's count for X in
`genre-map.yaml` with `source: feedback`. Corrections are training signal;
priors sharpen with use.

## Bootstrap (one-off command)

`intake bootstrap --tree /volume1/music/music.hq [--tree …uhq]` — read-only
scan producing: `genre-map.yaml` (artist → per-collection release counts, from
artist dirs and parsed release-folder names in `[Releases]`/flat dirs),
`label-map.yaml` (from `(Label; Cat#)`/`[Label, Cat#]` parses), and
`naming-variants-report.md` (evidence for the TBD decisions).
Optional `--tree /volume1/music/music --prior-weight 0.3`: the legacy mp3
tree can contribute artist priors at reduced weight (hoarding-era assignments
are less curated) — **pending Jenda's decision**.

## Rules repo layout — Appendix A (private, Forgejo)

```
music-rules/
├── genre-map.yaml       # artist → {collection: count}, aliases, exceptions
├── label-map.yaml       # label → {collection: count}
├── styles.yaml          # discogs style/genre → collection hints
├── income.yaml          # income folders: path, source_type, handling opts
├── structure.yaml       # naming templates, tier gates, thresholds, weights
├── overrides.log.yaml   # append-only feedback events
└── docs/music.hq-structure.md
```
CLI locates it via `INTAKE_RULES_DIR` env or `~/.config/intake/config.toml`.
The public repo contains schema docs + fixtures only, never the real maps.

## Testing

- Priors unit-tested on a frozen genre-map fixture; collab/alias matrix.
- Accuracy harness: replay N already-placed releases (strip location, run
  assign, compare) → report top-1/top-3 accuracy; gate: top-1 ≥0.90.
- Network tiers mocked; caches deterministic in tests.
