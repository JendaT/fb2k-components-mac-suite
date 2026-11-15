# Intake 03 — CLI ⇄ Component Contract

**Repo destination:** `docs/intake/intake-03-contract-spec.md`
**Owner:** SHARED — tools worker and extension worker both comply.
Changes require repo-overseer sign-off; this document is the interface.
**Status:** v1.2 — 2026-11-15

## Boundary principle

The component **reads** state (sidecars + CLI `--json` output) and **mutates
only through CLI commands**. It never writes sidecars, tags, or the journal
itself. The CLI never renders UI and never depends on foobar2000.

## Status lifecycle (normative)

```
new → resolved → proposed → approved → placing → placed → gc_done
 │      │            │          │
 └──────┴────────────┴──────────┴──▶ rejected        (terminal)
new/resolved/proposed may carry needs_review: true (orthogonal flag)
```

Legal transitions only via CLI commands; `placing` is transient (crash
recovery: `intake execute --resume` re-verifies and completes or reverts to
`approved`). Every transition appends to sidecar `history[]`.

`needs_review` is sticky: commands may raise it, and only `approve` clears
it (a `resolve --force` rebuild starts from scratch).

`rejected` is terminal: no command transitions out of it. Re-entry, if ever
wanted, is `resolve --force`, which rebuilds the sidecar from scratch.
Rejected roots remain listed in the default `status` inventory (consumers
need them to render the rejected state).

`gc_done` is a tombstone: `gc` keeps the sidecar, with status `gc_done`,
after it disposes of the local files, so `gc_done` roots stay listed in
`status`.

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
intake gc       <root...>|--all [--age <days>] [--relocate-dj]
intake status   [--filter k=v...]             # sidecar inventory
intake collections                            # genre map folder list (picker)
intake income                                 # income folders (income.yaml)
intake version                                # {cli, schema, engine, commands}
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

`gc` semantics: takes roots or `--all`; with neither it returns
`E_BAD_ARGS` (an empty ref list never means every root). `--all` collects
every `placed` root in every income folder.

### Legal source statuses (normative)

A command applied to a root whose status is not legal for it reports
`E_BAD_STATUS` for that root in `errors[]`; the other roots proceed (exit 1
if some succeeded, 2 if none did). The all-roots forms (`propose
--all-resolved`, `execute --approved`, `execute --resume` without roots,
`gc --all`) select only roots in a legal status and skip the rest without
an error.

| Command | Legal source status | `E_BAD_STATUS` on |
|---|---|---|
| `scan`, `resolve` | any status (an existing sidecar is kept); `resolve --force` (rebuild): `new`, `resolved`, `proposed`, `approved`, `rejected` | `resolve --force` on `placing`, `placed`, `gc_done` (a rebuild would drop the placement record and its journal link) |
| `identify` | `new`, `resolved`, `proposed`, `approved` | `rejected`, `placing`, `placed`, `gc_done` |
| `assign` | `new`, `resolved`, `proposed`, `approved` | `rejected`, `placing`, `placed`, `gc_done` |
| `propose` | `resolved` | every other status |
| `approve` | `proposed` | every other status |
| `reject` | `new`, `resolved`, `proposed`, `approved` | `rejected`, `placing`, `placed`, `gc_done` |
| `execute` | `approved` | every other status |
| `execute --resume` | `placing` | every other status |
| `gc` | `placed` | every other status (`rejected` included) |
| `status`, `collections`, `income`, `version` | read-only, no root status | — |

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
  confidence}], assigned_by, target_path}, placed:{verified,
  target_path}}`. `proposal` and `placed` are `null` when the sidecar has
  none. `proposal.assigned_by` is `"engine"` or `"user"`.
  `proposal.target_path` is the planned placement (doc 02), `null` when no
  target can be built (e.g. the singles slot, tier `reject`).
- `proposal.ranked` is the assignment engine's ordered candidate list, best
  first, truncated to the top 5. Present whenever the summary has a
  `proposal`; `[]` when the engine produced no candidates (a proposal made
  only by `assign --by user`).
- `ranked[0]` is the engine's best candidate. For engine-chosen proposals
  `target_collection == ranked[0].collection`. After `intake assign --by
  user`, `target_collection` is the user's choice and MAY be absent from
  `ranked`, which retains engine order; `confidence` is 1; `assigned_by` is
  `"user"`; `needs_review` is NOT cleared (it is sticky, and may carry other
  reasons, such as the FLAC decoder fallback). Consumers show a
  user-assigned proposal distinctly, and still show `needs_review`.
- `confidence` is a float in `[0,1]`, as elsewhere in this document.
- `status --filter k=v` keys: `id`, `status`, `needs_review`,
  `income_folder`, `source_type`, `tier` (alias `tier_eligible`),
  `virtual`, `singles`, `albumartist`, `album`, `root_path`. A value matches
  the sidecar's value as a string, exactly (`true`/`false` for the flags; an
  absent value matches the empty string). One value per key; filters on
  different keys must all match. An unknown key returns `E_BAD_ARGS`. A
  filtered call is not guaranteed to cost less than a full load.
- `collections --json` → `data` is an array `[{collection, artists,
  releases}]`, sorted by `collection` ascending. `collection` is a folder
  name usable with `assign --collection`; `artists` and `releases` are
  informational counts from the genre map (`releases` MAY be fractional:
  weighted priors).
- `income --json` → `data` is an array `[{name, path, exists}]`, one entry
  per income folder in `income.yaml`, in file order: `name` as configured,
  `path` absolute, `exists` true when `path` is an existing directory.
  Read-only. With no income folder configured it returns `E_NO_RULES`, as
  `status` does.
- `execute --dry-run --json` (without `--resume`) → `data` is an array with
  one row per root that passed the pre-checks (status, target):
  `{id, root_path, target_path, dry_run, files, artifacts,
  skipped_shadows}`. `dry_run` is `true`; `files` counts the primary audio
  files to place, `artifacts` the other files copied with a whole-dir root,
  `skipped_shadows` the `quality_shadow` files not placed. A root that fails
  a pre-check appears in `errors[]` only.

## Versioning

- `intake version --json` → `data: {cli, schema, engine, commands}`. `cli`
  and `engine` are semver strings (`engine` MAY be `null` when the beets
  shim is absent); **`schema` is an integer**, currently **1**. `commands`
  is an array of the command names this CLI accepts; consumers detect
  optional commands (e.g. `reject`, `income`) with it, not from
  `E_BAD_ARGS` text.
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

- FLAC: `"flacmd5:" + MD5`. The MD5 is the embedded STREAMINFO MD5 when it
  is set. When it is unset (all zeros), the MD5 is computed from the decoded
  audio with the `flac` decoder: interleaved samples, little-endian, signed,
  whole bytes per sample (`flac -d --force-raw-format --endian=little
  --sign=signed` → MD5). That is the value a correctly set STREAMINFO MD5
  holds, so the key is stable: tag edits do not change it, and neither does
  a later repair of the file. `flac_md5_unset` is recorded in
  `quality.issues` as the marker that the value was computed, not read. No
  repair is performed at any stage (`resolve` never mutates inputs,
  `execute` never mutates audio bytes of copies).
  - Fallback, when the decoder is missing or decoding fails: the file is
    keyed `"fsha1:" + SHA1(whole file)`, with `flac_decoder_missing` or
    `flac_decode_failed` in `quality.issues` (beside `flac_md5_unset`); the
    root gets
    `needs_review: true` (a decode failure often means a corrupt file); and
    execute writes no provenance tags to that file.
  - `flac` is a resolve-time dependency of the CLI.
- MP3: `"mp3sha1:" + SHA1(file bytes minus ID3v2 block(s) at head, minus
  ID3v1/APEv2 tail)`.
- WAV/AIFF: `"pcmsha1:" + SHA1(data/SSND chunk bytes)`.
- DSD (dsf): `"pcmsha1:" + SHA1(data chunk)`; dff and others (m4a/ogg):
  `"fsha1:" + SHA1(whole file)` v1 fallback (tag edits change it;
  acceptable, revisit).

Tag edits MUST NOT change audio_hash for flac/mp3/wav/aiff (a FLAC keyed by
the `fsha1:` fallback is protected by writing no tags to it). This key links
sidecars ↔ journal ↔ future sync-base snapshots.

## Execute protocol (tools worker implements; component displays)

1. Freeze proposal → compute final tag set (identify result + provenance:
   `INTAKE_DATE`, `INTAKE_SOURCE`, `INTAKE_BATCH`; TXXX / VorbisComment).
2. Copy release to a temp dir on Amunet target volume → write final tags to
   the **copies** (none to a FLAC keyed by the `fsha1:` fallback, see
   audio_hash) → fsync.
3. Verify: audio_hash of every copy == sidecar hash; file count match.
4. Atomic rename temp dir → `target_path`.
5. Append journal record; update genre-map counts; flip sidecar → `placed`
   with `placed:{target_path, verified: true, journal_seq}`.
6. Local originals untouched until `gc` (which re-verifies against journal
   before delete, or relocates into SSD dj/ zone with `--relocate-dj`).

Each placed file lands at `target_path/<path relative to the root>` (its
sidecar `files[].path`, disc subdirectories kept); a whole-dir (non-virtual)
root's other files (artifacts: covers, cues, logs) are copied the same way.

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
- Refresh: FSEvents watch on income roots (`intake income --json`) for
  `.intake.json` changes + post-command refresh. No polling loops.
- Version gate: component calls `intake version` at init; refuses decoration
  (logs, stays inert) if `schema` is not the supported integer.

## Error surfaces

Error codes are of two kinds.

**CLI-emitted**, in the envelope's `errors[]`: `E_NO_RULES`,
`E_NO_JOURNAL`, and the other codes the CLI defines. The vocabulary is
**open** — consumers MUST render unrecognised codes generically from
`msg`/`path` rather than failing. Consumers must handle three codes
specifically: `E_NO_RULES`, `E_NO_JOURNAL` and `E_BAD_STATUS`. Any other
code, `E_BAD_ARGS` included, is rendered generically. The current full
inventory stays discoverable in docs 01/02 without being frozen into this
contract.

**Host-synthesized**, produced by a consumer when no envelope can exist:
`E_NO_CLI` (binary not found, not executable, spawn failed, or stdout is
not a parseable envelope — a CLI that cannot be understood is functionally
absent) and `E_CLI_TIMEOUT` (no exit within the report budget below). The
CLI MUST NOT emit these two; they are reserved.

**Timeouts.** A consumer reports `E_CLI_TIMEOUT` when a command has not
exited after 10 s; `execute` is excepted (it runs detached). Reporting the
timeout does not end the command. A read-only command (`status`,
`collections`, `income`, `version`) MAY be killed at that point. A
mutating command, one that writes sidecars or the journal (`scan`,
`resolve`, `identify`, `assign`, `propose`, `approve`, `reject`,
`execute`, `gc`; classified by command, whatever its flags), MUST NOT be
killed before a 15-minute cap; the consumer lets it run and refreshes when
it exits. `execute` is never killed by a consumer: it runs detached and
survives the consumer quitting; an interrupted run leaves `placing` roots
for `execute --resume`.

**Inert state.** A consumer renders an inert state (explanatory tooltip)
only when the version gate fails, or when no `status` load has succeeded
yet and `version` or `status` fails with `E_NO_CLI`, `E_NO_RULES` or
`E_CLI_TIMEOUT`. Every other error is reported for the command that
produced it (e.g. `E_BAD_STATUS` on one root) and does not make the
consumer inert. A failed refresh after a successful load keeps the last
loaded data. In every case a consumer logs and never blocks playback UI.

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

## v1.2 changes (amendment 003, 2026-11-15)

Applied by CR adjudication; decision table in `AMENDMENTS.md` entry 003.

- **CR-003** — FLAC with unset STREAMINFO MD5 keyed `flacmd5:` + MD5 of
  the decoded audio (option d). When the `flac` decoder is missing or
  decoding fails: `fsha1:` fallback, `flac_decoder_missing` /
  `flac_decode_failed` issue, `needs_review` on the root, no provenance tag
  write for that file. `flac` is a resolve-time dependency. Supersedes the
  v1.1 CR-001.4 option B wording. Migration: none — no sidecars or journal
  exist, production or test (the Amunet test environment
  `music.intake-test` has only seen a `scan --dry-run`).
- **CR-004.1** — version gate compares the integer `schema`.
- **CR-004.2** — the three specifically handled codes named: `E_NO_RULES`,
  `E_NO_JOURNAL`, `E_BAD_STATUS`.
- **CR-004.3** — inert state limited to a failed version gate or no
  successful `status` load; other errors are per command; a failed refresh
  keeps the last data.
- **CR-004.4** — `collections --json` data shape pinned.
- **CR-004.5** — `--filter` keys pinned, `id` added, unknown key →
  `E_BAD_ARGS`, no cost guarantee for filtered calls.
- **CR-004.6** — per-file placement layout under `target_path` pinned.
- **CR-004.7** — `intake income` added (read-only).
- **CR-004.8** — `needs_review` allowed on `new`.
- **CR-004.9** — timeouts: 10 s report budget (`execute` excepted);
  read-only commands may be killed; mutating commands not before a
  15-minute cap; `execute` never.
- **CR-004.10** — `commands` added to `version` data.
- **CR-004.11** — state after `assign --by user` pinned;
  `proposal.assigned_by` added to the summary; `needs_review` stays set
  until `approve`.
- **CR-004.12** — legal source statuses per command; `execute --dry-run`
  data shape pinned; `proposal.target_path` added to the summary.
- **CR-004.13** — the sidecar survives `gc` as a `gc_done` tombstone.
- **CR-004.14** — `gc` takes roots or `--all` (`E_BAD_ARGS` otherwise); a
  named ref that is not `placed` gets `E_BAD_STATUS`.
- `proposal.ranked` is present whenever the summary has a `proposal`.

`schema` remains **1**: every `data` shape change is additive, and the
CR-003 key keeps the shape and type of `audio_hash`. CLI minor bump to
**0.3.0** for the surface changes: `gc --all`, the unknown filter key
error, the new `E_BAD_STATUS` cases (`identify`/`assign` on `rejected`,
`placing`, `placed`, `gc_done`; `resolve --force` on `placing`,
`placed`, `gc_done`; `gc` on a ref that is not `placed`), and the `income`
command.
