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
   dash variants (`Artist - Title`, `(YYYY) Artist - Title`), underscore
   variants. Emit parsed fields + which grammar matched (order and rules under
   Implementation notes, "Folder-name grammars").
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
`label-map.yaml` (from `(Label; Cat#)`/`[Label, Cat#]` parses, label-block
rules under Implementation notes), and
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
├── income.yaml          # income folders: path, source_type, trust, handling (doc 5)
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

## Implementation notes (v1, tools/intake)

Decisions made during implementation; normative for schema v1 consumers.

- **`identification` object** (sidecar): `{ status, source, release_id,
  artist, album, year, label, catno, styles[], genres[], distance, grammar,
  candidates, identified_at }`. `status` ∈ `fast_path` (Discogs-confirmed) |
  `shim` (beets candidate accepted, distance ≤ threshold) | `unconfirmed`
  (parse+tags merged, no external confirmation — offline or ambiguous;
  ambiguous Discogs hits and rejected shim candidates land in `candidates`,
  max 3) | `unidentified` (no usable artist/album). Anything except
  `fast_path`/`shim` sets `needs_review`. `needs_review` is sticky: identify/
  assign can raise it, never clear it (clearing is approve's job, P3).
- **Score normalization**: `score = Σ wᵢ·eᵢ / Σ wᵢ over available tiers`, so
  absent network tiers don't deflate confidence. Artist/label tiers count as
  available whenever the input carries a value (an unknown artist is evidence
  of absence); similar/style tiers only when they produced votes.
- **Ties** break deterministically by collection name (ascending) after score.
- **Feedback** lives in a separate `feedback:` section of `genre-map.yaml`
  (same artist→{collection: count} shape, merged with `artists:` at prior
  computation). Programmatic writes (feedback, learned `aliases:`) rewrite the
  file via YAML serializer — hand comments are not preserved; keep curated
  notes in the rules repo's git history instead.
- **Singles**: `structure_slot: "singles"`, `target_path: null` — the singles
  slot layout is one of the five pending structure TBDs; propose (P3) fills it
  once decided. Tier `reject` likewise gets `target_path: null`.
- **Config** (`structure.yaml`): `assign.weights{artist,label,similar,style}`,
  `assign.short_circuit{min_releases,confidence}`,
  `assign.needs_review{confidence,margin}`, `assign.shim_accept_distance`,
  `naming.release`/`naming.release_no_label` templates, `tiers.*` as specced.
- **Providers**: Discogs via `DISCOGS_TOKEN`, Last.fm via `LASTFM_API_KEY`
  (similar-artist cache in `INTAKE_CACHE_DIR`, default `~/.cache/intake`,
  TTL 90 d), shim command override via `INTAKE_BEETS_SHIM`. Without
  credentials the engine runs fully offline on priors alone.
- **Bootstrap**: `--tree <path>` repeatable, `--prior-weight <w>` applies to
  the most recent `--tree`, `--out <dir>` (default: rules dir), refuses to
  overwrite existing maps without `--force`. Collection dirs are the tree
  root's children; inside them, release-grammar dirs are flat releases,
  `[Slot]`-style dirs hold flat releases, a dir whose subdirs are mostly disc
  dirs (doc 1 pass 2 pattern, e.g. `Title/CD1`…`CD8`, extras such as `Scans`
  tolerated) is one release with no artist level, and anything else is an
  artist dir (its subdirs are releases; disc dirs inside those are not
  looked at). A release with no artist level gets its artist only from a name
  parse, never from its dir name; unparsed, it counts as a release with no
  artist and is listed in the report. `releases` in the stats counts every
  release dir, with or without an artist.
- **Folder-name grammars**, tried in order, first match wins (score = the
  resolver's `name_parse` signal):
  `bracket_year_paren_label` `Artist [YYYY] Title (Label; Cat#)` 1.0;
  `bracket_year_bracket_label` `Artist [YYYY] Title [Label, Cat#]` 1.0;
  `bracket_year` `Artist [YYYY] Title` 0.75;
  `scene` `Artist_Name-Album_Title[-(CAT)]-WEB-YYYY-GRP` 1.0 ("-" separates
  fields, "_" separates words inside a field, the catno field is optional,
  source token WEB/CD/VINYL/TAPE/FLAC/MP3, extra fields may follow it, the
  group may be mixed case);
  `paren_year_dash` `(YYYY) Artist - Title` 0.75;
  `dash_year` `Artist - Title (YYYY)` / `[YYYY]` 0.75;
  `dash` `Artist - Title` 0.5;
  `paren_year` `(YYYY) Title` 0.5 (no artist; the artist sits in a parent
  dir, as in discography dumps).
  The dash grammars accept a spaced hyphen, en dash (U+2013) or em dash
  (U+2014) between artist and title. A name with no spaces that contains
  `_-_` is read with underscores as spaces by the dash grammars (after the
  scene grammar was tried on the original), so `VA_-_Compilation_Title` gives
  artist "VA". Whitespace runs inside every parsed field collapse to one
  space.
- **Label blocks** (`(…; …)` after `[YYYY] Title`, `[…, …]` likewise): the
  block is split into fields; fields that are a 4-digit year, a format token
  (WEB, CD, 2CD, 2xLP, Vinyl, Cass, Cassette, DVD, SACD, File, FLAC, MP3, 12"
  …), a release descriptor (Comp, RM, RE, Ltd, Promo, EP, Single, Album, Mixed
  …) or a country (US, UK, Europe, Germany, Japan …) are skipped. The first
  remaining field is the label; a `#CAT` suffix on it is the catno, otherwise
  the fields after it are. So `(1984; Label; CAT01)` and `[1984, Label]` give label
  "Label", and Discogs-style `[2CD, Comp, RM, US, Label #CAT290]` gives label
  "Label", catno "CAT290". Nothing left: label and catno are null. A
  single-field block (`[LABEL CD 97]`) is not split (label and catno cannot be
  told apart safely); the name parses as `bracket_year` with the block kept
  in the title.
- `intake bootstrap` is not (yet) in the doc 03 command surface — filed as
  CR-001.2 in `CHANGE-REQUESTS.md` for the next contract bump; the component
  never calls it.
