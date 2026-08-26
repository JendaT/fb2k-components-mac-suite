# Intake 03 — CLI ⇄ Component Contract

**Repo destination:** `docs/intake/intake-03-contract-spec.md`
**Owner:** SHARED — tools worker and extension worker both comply.
Changes require repo-overseer sign-off; this document is the interface.
**Status:** v1.1 — 2026-08-26

## Boundary principle

The component **reads** state (sidecars + CLI `--json` output) and **mutates
only through CLI commands**. It never writes sidecars, tags, or the journal
itself. The CLI never renders UI and never depends on foobar2000.

## Status lifecycle (normative)

```
new → resolved → proposed → approved → placing → placed → gc_done
 │      │            │          │
 └──────┴────────────┴──────────┴──▶ rejected        (terminal)
resolved/proposed may carry needs_review: true (orthogonal flag)
```

Legal transitions only via CLI commands; `placing` is transient (crash
recovery: `intake execute --resume` re-verifies and completes or reverts to
`approved`). Every transition appends to sidecar `history[]`.

`rejected` is terminal: no command transitions out of it. Re-entry, if ever
wanted, is `resolve --force`, which rebuilds the sidecar from scratch.
Rejected roots remain listed in the default `status` inventory (consumers
need them to render the rejected state).

## CLI command surface (v1, semver)

All commands: `--json` (machine output, single JSON doc on stdout),
`--dry-run` where mutating, exit 0 ok / 1 partial / 2 error.

```
intake scan     [<income>|--all]
intake resolve  <path> [--force]
intake identify <root...>
intake assign   <root...> [--collection "<name>"] [--by user|engine]
intake propose  <root...>|--all-resolved      # identify+assign+naming
intake approve  <root...>|--batch <file>
intake reject   <root...>|--batch <file> [--reason "<text>"]
intake execute  <root...>|--approved [--resume]
intake gc       [<root...>] [--age <days>] [--relocate-dj]
intake status   [--filter k=v...]             # sidecar inventory
intake collections                            # genre map folder list (picker)
intake version                                # {cli, schema, engine} versions
intake bootstrap --tree <path>... [--prior-weight <w>] [--out <dir>] [--force]
                                              # human-only; not part of the
                                              # component-facing contract
```

`reject` semantics: legal from `new`, `resolved`, `proposed`, `approved`;
refused from `placing`, `placed`, `gc_done` with `E_BAD_STATUS` (a placed
release is in the library; withdrawing it is a different, un-specced
operation). Sets `status: "rejected"`, appends a `history[]` entry carrying
the `--reason` text (free-form, no vocabulary), writes no tags, touches no
audio, writes no journal record (nothing entered the library). Local files
are NOT deleted: reject is a state change only, and rejected roots are not
gc-eligible in v1.1 (`gc` touches only `placed` roots); disposal of rejected
local bytes is manual.

## JSON conventions

- **Envelope (universal).** Every `--json` invocation emits exactly one
  JSON object on stdout: `{ "ok": bool, "data": …, "errors": [{code, msg,
  path}] }`. The per-command shapes below describe the `data` member only.
  No command emits a bare array, string, or number at top level.
- `ok` is `true` iff the exit code is 0. On exit 1 (partial) `ok` is
  `false`, `data` carries the successful subset, and `errors[]` is
  non-empty. On exit 2 (error) `data` is `null` and `errors[]` is
  non-empty. `errors[]` is `[]` whenever `ok` is `true`.
- Roots are addressed by sidecar `id` OR absolute path (CLI accepts both).
- `status --json` → `data` is an array of sidecar summaries:
  `{id, root_path, status, needs_review, cluster:{albumartist,album},
  proposal:{target_collection, confidence, ranked:[{collection,
  confidence}]}, placed:{verified, target_path}}`.
- `proposal.ranked` is the assignment engine's ordered candidate list, best
  first, truncated to the top 5. Present when the sidecar has a proposal
  (status `proposed` or later); omitted or `[]` otherwise.
- `ranked[0]` is the engine's best candidate. For engine-chosen proposals
  `target_collection == ranked[0].collection`. After `intake assign --by
  user`, `target_collection` is the user's choice and MAY be absent from
  `ranked`, which retains engine order.
- `confidence` is a float in `[0,1]`, as elsewhere in this document.

## Versioning

- `intake version --json` → `data: {cli, schema, engine}`. `cli` and
  `engine` are semver strings (`engine` MAY be `null` when the beets shim
  is absent); **`schema` is an integer**, currently **1**.
- `schema` versions this document's JSON surface: the sidecar schema plus
  the `--json` `data` shapes specified here. It is bumped by the overseer
  in the amendment that makes a breaking change — removal, rename, type
  change, or semantic change. Additive fields do NOT bump it: within a
  schema version, fields may be added, and consumers MUST treat unknown
  fields as ignorable and newly-specified fields as optional
  (feature-detect, never assume presence).
- Consumers support one fixed `schema` value, MUST ignore unknown fields,
  MUST treat any field not present in the version they were built against
  as optional, and MUST refuse to operate on a different value. The
  component's supported schema for P4 is **1**.

## audio_hash (normative algorithm)

- FLAC: `"flacmd5:" + embedded STREAMINFO MD5` (via metaflac). If the
  STREAMINFO MD5 is unset (all-zero), the file is keyed
  `"fsha1:" + SHA1(whole file)` for life, with `flac_md5_unset` recorded in
  `quality.issues` as the permanent marker; no repair is performed at any
  stage (`resolve` never mutates inputs, `execute` never mutates audio
  bytes of copies).
- MP3: `"mp3sha1:" + SHA1(file bytes minus ID3v2 block(s) at head, minus
  ID3v1/APEv2 tail)`.
- WAV/AIFF: `"pcmsha1:" + SHA1(data/SSND chunk bytes)`.
- DSD (dsf): `"pcmsha1:" + SHA1(data chunk)`; dff and others (m4a/ogg):
  `"fsha1:" + SHA1(whole file)` v1 fallback (tag edits change it;
  acceptable, revisit).

Tag edits MUST NOT change audio_hash for flac/mp3/wav/aiff. This key links
sidecars ↔ journal ↔ future sync-base snapshots.

## Execute protocol (tools worker implements; component displays)

1. Freeze proposal → compute final tag set (identify result + provenance:
   `INTAKE_DATE`, `INTAKE_SOURCE`, `INTAKE_BATCH`; TXXX / VorbisComment).
2. Copy release to a temp dir on Amunet target volume → write final tags to
   the **copies** → fsync.
3. Verify: audio_hash of every copy == sidecar hash; file count match.
4. Atomic rename temp dir → `target_path`.
5. Append journal record; update genre-map counts; flip sidecar → `placed`
   with `placed:{target_path, verified: true, journal_seq}`.
6. Local originals untouched until `gc` (which re-verifies against journal
   before delete, or relocates into SSD dj/ zone with `--relocate-dj`).

Files marked `quality_shadow: true` in the sidecar are not placed. The
copy set, the hash verification of step 3, and the file-count match are
all over primary (non-shadow) files. Shadows remain local and are disposed
of by `gc` with the rest of the local original; with `--relocate-dj`,
shadows are relocated into the dj zone along with the primary files
(relocate means move, not delete — disposal by deletion is plain `gc`).

## Journal (Amunet)

`/volume1/music/music.meta/intake-journal.ndjson` *(location pending
confirmation)* — deliberately a sibling of ALL `music.*` tiers: one journal
for the whole share; the tier is encoded in each record's `target_path`.
Append-only, one JSON object per line:
`{seq, ts, event, sidecar_id, audio_hashes[], target_path, cli_version}`.
Journal is the authority for "is it in the library"; sidecars are working
copies; tags are projection.

## Component read patterns

- Component matches playlist row paths against sidecar roots obtained from
  `intake status --json`.
- Refresh: FSEvents watch on income roots for `.intake.json` changes +
  post-command refresh. No polling loops.
- Version gate: component calls `intake version` at init; refuses decoration
  (logs, stays inert) if `schema` major ≠ supported.

## Error surfaces

Error codes are of two kinds.

**CLI-emitted**, in the envelope's `errors[]`: `E_NO_RULES`,
`E_NO_JOURNAL`, and the other codes the CLI defines. The vocabulary is
**open** — consumers MUST render unrecognised codes generically from
`msg`/`path` rather than failing. The three codes named in this document
are the ones consumers must handle specifically; the current full
inventory stays discoverable in docs 01/02 without being frozen into this
contract.

**Host-synthesized**, produced by a consumer when no envelope can exist:
`E_NO_CLI` (binary not found, not executable, spawn failed, or stdout is
not a parseable envelope — a CLI that cannot be understood is functionally
absent) and `E_CLI_TIMEOUT` (no exit within the consumer's budget; the
component uses 10 s, `execute` excepted — it runs detached). The CLI MUST
NOT emit these two; they are reserved.

On any of these a consumer renders an inert state with an explanatory
tooltip, logs, and never blocks playback UI.

## v1.1 changes (amendment 002, 2026-08-26)

Applied by CR adjudication; decision table in `AMENDMENTS.md` entry 002.

- **CR-001.1** — `intake reject` added to the command surface with pinned
  semantics; `rejected` now reachable (also from `new` — lifecycle diagram
  updated); terminality, `resolve --force` re-entry, non-gc-eligibility,
  and visibility in the default `status` inventory stated.
- **CR-001.2** — `intake bootstrap` listed, marked human-only / not part of
  the component-facing contract.
- **CR-001.3** — `quality_shadow` handling in execute/gc made explicit
  (primary-files-only copy/verify/count; shadows relocated by
  `--relocate-dj`, current behavior confirmed).
- **CR-001.4** — FLAC unset-MD5 "recompute+fix" dropped (option B): such
  files stay keyed `fsha1:` with `flac_md5_unset` as permanent marker; no
  repair at any stage.
- **CR-001.5 / CR-002.4** — error surfaces rewritten: open CLI-emitted
  vocabulary; `E_NO_CLI` and `E_CLI_TIMEOUT` are host-synthesized and
  reserved (CLI MUST NOT emit); unparseable stdout folds into `E_NO_CLI`.
- **CR-002.1** — universal `--json` envelope made explicit; `ok` ↔
  exit-code relation and `data` on failure specified.
- **CR-002.2** — `proposal.ranked` added to the `status --json` summary
  (top 5, ordered, feature-detected by consumers).
- **CR-002.3** — Versioning section added (option A): `schema` is an
  integer, currently 1; additive changes do not bump it; consumers
  feature-detect and ignore unknown fields.

No accepted item is breaking; `schema` remains **1**.
