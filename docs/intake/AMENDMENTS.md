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
