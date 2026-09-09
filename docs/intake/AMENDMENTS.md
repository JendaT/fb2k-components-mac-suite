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
