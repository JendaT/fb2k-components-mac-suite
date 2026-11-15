# Intake Spec Amendments

Append-only log. Spec changes land on main only as numbered amendments
through the repo overseer, then propagate to worker branches by merging
main. Do not edit or delete existing entries.

---

## Amendment 001 — 2026-07-12

**Files touched:**
- `docs/intake/intake-05-producer-protocol.md` (new)
- `docs/intake/intake-02-assignment-spec.md` (edit)
- `knowledge_base/14_INTAKE_SYSTEM_OVERVIEW.md` (edit)

**Summary:** Doc 05 (producer protocol) added as the P5 spec: how trusted
source plugins (Tidal first) feed intake — single precache store with
ephemeral/promoted states, promotion via `.intake-hint.json` write,
suggestion UI backed by the shared `assign` ranking. Doc 02: `income.yaml`
schema comment extended (trust, handling; references doc 5). Overview:
doc-map row for doc 5, new decision 8 (producer protocol), P5 phrasing
updated.

**Affected workers:**
- Tools worker (`feature/intake-cli`): informational only — the doc 02 edit
  is a schema comment, no scope change.
- Extension worker (`feature/intake-extension`): none.
- `dev/tidal-integration`: future P5 basis; not active yet, not notified.

---

## Amendment 002 — 2026-08-26

**Files touched:**
- `docs/intake/intake-03-contract-spec.md` (edit — bumped to v1.1)

**Scope:** doc 03 v1.1 via adjudication of CR-001 (tools worker,
2026-07-25), CR-EXT-001 (extension worker, 2026-07-25, superseded), and
CR-002 (extension worker, 2026-08-13, which re-files CR-EXT-001's items in
register form). CR-EXT-001 is adjudicated through its CR-002 successor.

Branch-side updates to docs 01/02/04 are **NOT** part of this amendment;
they land with the `feature/intake-extension` branch merge as a future
amendment. In particular, the doc 01 amendment that CR-001.4 option B
requires (doc 01:73–76 currently places the MD5 fix at execute) is owed by
the tools worker in that future amendment.

**Decision table:**

| CR item | Decision | Rationale |
|---|---|---|
| CR-001.1 (`rejected` unreachable) | **Accept with modification** | Both consumers already declare/render the state; proposed semantics adopted, plus pinned: legal also from `new`; re-entry only via `resolve --force`; rejected roots NOT gc-eligible in v1.1; rejected roots remain in the default `status` inventory (extension's informational request). CLI minor, schema unchanged. |
| CR-001.2 (`bootstrap` absent) | **Accept** | Listed in the surface marked human-only / not component-facing — keeps doc 03 readable as exhaustive. Editorial. |
| CR-001.3 (`quality_shadow` unspecified) | **Accept** | Proposed wording adopted; documents shipped behavior both consumers rely on. Open question decided: `--relocate-dj` RELOCATES shadows (relocate means move, not delete; deletion stays plain `gc`). Doc-only, no code change. |
| CR-001.4 (FLAC fix vs verify conflict) | **Accept — option B** (no repair) | Matches shipped behavior of the CLI (resolve never mutates; execute never repairs); only option needing no hash-immutability exception; revisit toward option A only with corpus evidence of common unset MD5. Doc 03 wording only; doc 01 amendment owed at branch merge. |
| CR-001.5 (error-code list ≠ inventory) | **Accept — option (b)** | Open vocabulary; consumers render unknown codes generically; full inventory stays discoverable in docs 01/02. Resolved jointly with CR-002.4. Editorial. |
| CR-002.1 (envelope vs bare array) | **Accept** | Proposed wording adopted verbatim — matches shipped CLI (`cli.ts:202`); also closes the `ok` ↔ exit-code gap in the same edit. Doc-only. |
| CR-002.2 (`proposal.ranked`) | **Accept** | The one field that keeps the component's ranking dependency inside the versioned contract (needed by doc 04 Part B context actions and doc 05 step 7). Top 5, ordered, present from `proposed` onward; consumers feature-detect. Additive → no schema bump under CR-002.3 option A. CLI minor on the tools side (serialization of an existing value). |
| CR-002.3 (version gate has no version) | **Accept — option A** (integer + additive-optional rule) | Zero code change; matches shipped `{cli: semver, schema: 1, engine: semver\|null}`; Versioning section added pinning schema **1** and the feature-detect rule. Option B rejected as itself breaking; option C as over-machinery. |
| CR-002.4 (`E_NO_CLI` host-synthesized; timeouts) | **Accept with modification** | Proposed two-kind rewrite adopted; `E_NO_CLI` and `E_CLI_TIMEOUT` reserved, CLI MUST NOT emit. Open decision decided: unparseable stdout FOLDS INTO `E_NO_CLI` (a CLI that cannot be understood is functionally absent) — no `E_BAD_OUTPUT`. Doc-only. |

**Breaking changes: none.** All accepted items either document shipped
behavior or are additive; per doc 03's own semver rules no schema major
bump is required — `schema` remains **1**.

**Affected workers:**
- Tools worker: two follow-ups — implement `intake reject` (CLI minor,
  CR-001.1) and serialize `proposal.ranked` into the status summary (CLI
  minor, CR-002.2); plus the doc 01 amendment owed for CR-001.4 option B.
- Extension worker (`feature/intake-extension`, Part B in progress):
  unblocked — CR-002.1 and CR-002.3 resolved as the implementation ships;
  parser targets the universal envelope, version gate compares integer
  `schema == 1` and feature-detects `ranked`.

---

## Amendment 003 — 2026-11-15

**Files touched:**
- `docs/intake/intake-03-contract-spec.md` (edit — bumped to v1.2)
- `docs/intake/intake-02-assignment-spec.md` (edit — new section "Library
  layout and credit rules (amendment 003)")
- `knowledge_base/14_INTAKE_SYSTEM_OVERVIEW.md` (edit — Open TBDs)

**Summary:** Doc 03 v1.2 via adjudication of CR-003 (tools worker,
2026-11-14) and CR-004 (extension worker, 2026-11-14, 14 items); TR-001
closed. Doc 02 gains the Various Artists and no-label credit rules and the
library layout for new placements (artist folder, `[Releases]`,
`[Compilations]`), which decides the artist-folder threshold and
compilations slot TBDs; restructuring existing library folders and
converting old flat collections are deferred to amendment 004. Overview
Open TBDs updated to match.

`CHANGE-REQUESTS.md` and `CR-EXT-001-doc03.md` live on the worker branches
and are not edited here; each worker updates its CR status lines after
merging main. The doc 02 rules sit in a new section so they merge cleanly
with the tools worker's Implementation-notes edits; that worker aligns its
own bullets after the merge.

**Decision table:**

| Item | Decision | Rationale |
|---|---|---|
| CR-003 (unset-MD5 FLAC can never be placed) | **Accept — option (d)** | User's choice, 2026-11-14. Key = `flacmd5:` + MD5 of the decoded audio, equal to what a correctly set STREAMINFO MD5 holds (premise checked: 28/28 normal FLACs incl. three 24-bit; tag-immune; stable across a later repair). Fallback when the `flac` decoder is missing or decoding fails: `fsha1:` + `flac_decoder_missing`/`flac_decode_failed`, no provenance tag write on that file, and `needs_review: true` on the root (user: a decode failure often means a corrupt file, and that must be visible). `flac` becomes a resolve-time dependency. Supersedes amendment 002's acceptance of CR-001.4 option B, whose premise held only where `metaflac` is absent. Migration: none (no sidecars or journal exist, production or test). |
| CR-004.1 (version gate "schema major") | **Accept** | Wording as requested. Doc-only. |
| CR-004.2 ("the three codes") | **Accept** | Named: `E_NO_RULES`, `E_NO_JOURNAL`, `E_BAD_STATUS` (the codes doc 03 v1.1 named outside the host-synthesized pair); every other code, `E_BAD_ARGS` included, is rendered generically. Doc-only. |
| CR-004.3 (scope of the inert state) | **Accept** | As requested: inert only on a failed version gate or when no `status` load has succeeded (`E_NO_CLI`/`E_NO_RULES`/`E_CLI_TIMEOUT` on `version`/`status`); other errors per command; a failed refresh keeps the last data. Doc-only. |
| CR-004.4 (`collections` shape) | **Accept** | `[{collection, artists, releases}]` sorted by `collection`, as shipped. Doc-only. |
| CR-004.5 (`--filter` keys) | **Accept** | Shipped key list pinned plus `id`; unknown key → `E_BAD_ARGS`; one value per key; no promise that a filtered call is cheaper than a full load. CLI minor. |
| CR-004.6 (per-file layout at execute) | **Accept** | Files land at `target_path/<path relative to the root>`; `quality_shadow` files are not placed. Matches shipped behavior. Doc-only. |
| CR-004.7 (income paths not exposed) | **Accept** | New read-only `intake income --json` → `[{name, path, exists}]` from `income.yaml`. CLI minor. |
| CR-004.8 (`needs_review` on `new`) | **Accept** | Lifecycle note extended; matches doc 01 and shipped behavior. Doc-only. |
| CR-004.9 (one 10 s budget) | **Accept with modification** | Consumers report `E_CLI_TIMEOUT` at 10 s for every command except `execute`; read-only commands (`status`, `collections`, `income`, `version`) may be killed then; mutating commands (write sidecars or the journal: `scan`, `resolve`, `identify`, `assign`, `propose`, `approve`, `reject`, `execute`, `gc`) must not be killed before a 15-minute cap; `execute` is never killed (detached; interrupted runs are resumed). No separate budget class. Doc-only. |
| CR-004.10 (capability detection) | **Accept** | Additive `commands: [...]` in `version` data. CLI minor. |
| CR-004.11 (state after `assign --by user`) | **Accept with modification** | `confidence` 1, `proposal.assigned_by` `"user"`, `assigned_by` added to the summary (additive). `needs_review` is NOT cleared: it is sticky, only `approve` clears it, and it may carry other reasons (e.g. the CR-003 fallback). Consumers show user-assigned distinctly but still show `needs_review` — the CR's fallback of treating user-assigned as reviewed is not adopted. |
| CR-004.12 (legal source statuses; dry-run shape) | **Accept** | Per-command matrix in doc 03 with `E_BAD_STATUS` otherwise, including `identify`/`assign` on `rejected`/`placing`/`placed`/`gc_done` and `gc` on a ref that is not `placed`, and `resolve --force` on `placing`/`placed`/`gc_done` (overseer: a rebuild would drop the placement record and its journal link). `execute --dry-run` data `{id, root_path, target_path, dry_run, files, artifacts, skipped_shadows}` pinned as shipped. `proposal.target_path` added to the summary (additive). CLI minor. |
| CR-004.13 (sidecar after `gc`) | **Accept** | The sidecar survives as a `gc_done` tombstone, so `gc_done` appears in `status`. Matches shipped behavior. Doc-only. |
| CR-004.14 (no-argument `gc`) | **Accept** | `gc` without roots requires `--all`, else `E_BAD_ARGS`; combined with the CR-004.12 rule for refs that are not `placed`. CLI minor (surface change). |
| `proposal.ranked` presence | **Clarify** | Present whenever the summary has a `proposal` (a proposal can exist before status `proposed`); `[]` for a user-only proposal. Matches shipped behavior. |
| TR-001 (tools-worker response to CR-EXT-001) | **Closed** | Its CR-1, CR-2 (`ranked`) and CR-4 positions were accepted in amendment 002 (CR-002.1, CR-002.2, CR-002.4). Its CR-3 schema-to-semver proposal is superseded by amendment 002's integer `schema` (CR-002.3 option A). |

**Doc 02 decisions (user and overseer, no CR):**
- Various Artists credits: in assign the artist and similar tiers are
  unavailable (no prior, no short-circuit, weights out of the denominator);
  a user override on a VA root logs to `overrides.log.yaml` without
  feedback; execute's genre-map count update skips a VA credit; bootstrap
  never records a VA-like name (VA credit or VA token
  prefix) as an artist.
- No-label credits (self-released spellings, `No Label`, `Not On Label…`):
  never a `label-map.yaml` key; absent, not evidence, in assign.
- Library layout for new placements: `<Collection>/<Artist>/…` when the
  artist already has a release in that collection (read from disk at
  propose time, per collection within one tier), else
  `<Collection>/[Releases]/…`; VA releases go to
  `<Collection>/[Compilations]/…`, so compilations get a `target_path`.
  Applies to every collection, old flat ones included; existing
  `[Releases]`/`[Compilations]` dirs reused whatever their case; other
  bracketed dirs (curated selections) are never targets.
- Existing library folders are never moved by `propose` or `execute`;
  moving an artist's earlier releases into an artist folder and converting
  old flat collections are separate, approvable actions, specified in
  amendment 004.
- Still pending: singles slot, collab handling, name normalization, bracket
  style, and the folder name for a no-label credit with catno `none`.

**Versioning:** `schema` remains **1**. Every `data` change is additive
(`commands`, `proposal.assigned_by`, `proposal.target_path`, the `income`
payload). CR-003 changes which algorithm produces `audio_hash` for one rare
file class but not its shape or type; no consumer compares hashes and
nothing needs migrating. CLI minor bump to **0.3.0** for the surface
changes: `gc --all`, the unknown filter key error, the new `E_BAD_STATUS`
cases, and the `income` command.

**Affected workers:**
- Tools worker (`feature/intake-cli`), CLI 0.3.0:
  - CR-003: decoded-audio MD5 for unset-MD5 FLAC; `fsha1:` fallback with
    `flac_decoder_missing`/`flac_decode_failed`, `needs_review`, and no
    provenance tag write on that file; the two regression tests named in
    CR-003; check the first real 12/20-bit FLAC against a re-encode.
  - `intake income`; `commands` in `version`; `proposal.assigned_by` and
    `proposal.target_path` in the status summary.
  - `--filter`: add `id`; unknown key → `E_BAD_ARGS`.
  - `E_BAD_STATUS` from `identify`/`assign` on `rejected`, `placing`,
    `placed`, `gc_done`; from `resolve --force` on `placing`,
    `placed`, `gc_done`; from `gc` on a named ref that is not `placed`.
  - `gc` without roots → `E_BAD_ARGS` unless `--all`.
  - `approve` clears `needs_review`.
  - Execute's genre-map count update (`recordPlacement`) skips a VA credit.
  - Library layout in target-path building: artist folder vs `[Releases]`
    vs `[Compilations]` from the collection dir on disk; reuse existing
    slot dirs whatever their case; never other bracketed dirs; artist names
    compared with the map-key normalization (interim); propose no longer
    refuses compilations as "slot pending".
  - Docs after merging main: doc 01 FLAC hash notes; doc 02
    Implementation-notes bullets (Compilations, Singles, the CR-001.2
    bootstrap note) aligned with the new section; CR-003 and TR-001
    status lines.
- Extension worker (`feature/intake-extension`, Part B):
  - Build to the doc 03 v1.2 rules: legal-status matrix as the enable
    matrix, inert scope, timeout and kill rule, `execute --dry-run` shape.
  - Feature-detect `commands`, `proposal.assigned_by`,
    `proposal.target_path` and `income`; watch income roots from
    `intake income` when present.
  - Show user-assigned proposals distinctly but keep showing
    `needs_review` (drop the "user-assigned = reviewed" fallback).
  - Doc 04 (worker-owned): state acquisition (income watch; filtered
    refresh carries no cost guarantee), decorations (`needs_review` on
    `new`), failure behavior (inert scope, timeout rule). CR-004 status
    line.
