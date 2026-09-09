# CR-EXT-001 — Doc 03 change requests (extension worker)

**Raised by:** extension worker (`feature/intake-extension`)
**Date:** 2026-07-25 · **Target doc:** `docs/intake/intake-03-contract-spec.md` (v1)
**Decision:** repo overseer. Doc 03 is overseer-guarded; the extension worker
has not edited it.

Four requests, surfaced while implementing P4 Part A and drafting Part B
(doc 04 v1.1). None blocks Part A — Part A is generic and contract-free.
All four block or degrade Part B (`foo_jl_intake_mac`), which is the first
consumer of `intake status --json`.

If accepted, these land as a numbered amendment (`docs/intake/AMENDMENTS.md`)
per the amendment protocol. This file is a proposal record; the overseer may
delete it once the amendment lands.

| # | Request | Type | Semver impact | Tools-worker impact |
|---|---------|------|---------------|---------------------|
| 1 | Pin envelope vs. bare array for `status --json` | Clarification | none, unless CLI already emits bare arrays (then breaking) | Possibly breaking — check current implementation |
| 2 | Add `proposal.ranked` to the status summary | Additive | schema minor (1.0.0 → 1.1.0) | Small — data already computed by `assign` |
| 3 | Pin the starting schema version + compat rule | Clarification / new section | none (declares 1.0.0) | None |
| 4 | Split error codes into CLI-emitted vs host-synthesized | Clarification (+1 reserved code) | none, or minor if `E_CLI_TIMEOUT` counts | None (adds a MUST-NOT-emit rule) |

---

## CR-1 — Is `intake status --json` wrapped in the envelope, or a bare array?

**Section:** § JSON conventions

**Current text:**

> - Envelope: `{ "ok": bool, "data": …, "errors": [{code, msg, path}] }`.
> - Roots are addressed by sidecar `id` OR absolute path (CLI accepts both).
> - `status --json` returns an array of sidecar summaries: `{id, root_path, …}`.

**Problem:** the two bullets contradict each other for the one command the
component calls most. "Returns an array" reads as a bare top-level `[…]`;
the envelope bullet reads as `{ok, data: […], errors: []}`. A consumer
cannot write the parse without guessing, and guessing wrong is a silent
integration failure (the component would see zero intake rows and render an
empty, non-erroring state).

Two adjacent gaps in the same section, worth closing in the same edit:
`ok` is never related to the exit codes in § CLI command surface (`0 ok /
1 partial / 2 error`), and `data`'s shape on failure is unspecified.

**Proposed replacement for the section's first bullets:**

> - **Envelope (universal).** Every `--json` invocation emits exactly one
>   JSON object on stdout: `{ "ok": bool, "data": …, "errors": [{code, msg,
>   path}] }`. The per-command shapes below describe the `data` member only.
>   No command emits a bare array, string, or number at top level.
> - `ok` is `true` iff the exit code is 0. On exit 1 (partial) `ok` is
>   `false`, `data` carries the successful subset, and `errors[]` is
>   non-empty. On exit 2 (error) `data` is `null` and `errors[]` is
>   non-empty. `errors[]` is `[]` whenever `ok` is `true`.
> - Roots are addressed by sidecar `id` OR absolute path (CLI accepts both).
> - `status --json` → `data` is an array of sidecar summaries: `{id,
>   root_path, status, needs_review, cluster:{albumartist,album},
>   proposal:{…}, placed:{verified, target_path}}`.

**Recommendation:** envelope everywhere. It gives partial failures a place
to live (exit 1 is already in the spec — a bare array cannot report which
roots failed), and it gives every consumer one parse path.

**If the tools worker has already shipped bare arrays:** this is a breaking
change to a command the component has not consumed yet, so it is cheapest to
fix now. The alternative — declaring `status` the one enveloped-exempt
command — is acceptable to the extension worker but costs a special case in
every consumer.

**Fallback if rejected/deferred:** the component sniffs the first
non-whitespace byte (`{` vs `[`) and accepts both. Works, but it is
guesswork encoded as a permanent workaround, and it silently swallows the
disagreement rather than resolving it.

---

## CR-2 — Add `proposal.ranked` to the status summary

**Section:** § JSON conventions, `status --json` summary shape

**Current:** `proposal:{target_collection, confidence}`

**Requested:** `proposal:{target_collection, confidence, ranked:[{collection, confidence}]}`

with these rules added to the section:

> - `proposal.ranked` is the assignment engine's ordered candidate list (doc
>   2), best first, truncated to the top 5. Present when the sidecar has a
>   proposal (status `proposed` or later); omitted or `[]` otherwise.
> - `ranked[0]` is the engine's best candidate. For engine-chosen proposals
>   `target_collection == ranked[0].collection`. After `intake assign --by
>   user`, `target_collection` is the user's choice and MAY be absent from
>   `ranked`, which retains engine order.
> - `confidence` is a float in `[0,1]`, as elsewhere in this document.

**Why:** two specified consumers need ranked alternates, and neither can get
them from the contract today:

- Doc 04 § Part B / Context actions: "**Assign to \<top alternates\>** — the
  top ranked alternates from the sidecar as individual flat actions (max
  4)". Building that menu requires the ranking at menu-build time, on the
  main thread, for the current selection.
- Doc 05 (producer protocol) step 7: suggestion UI backed by the shared
  `assign` ranking.

Without this field both consumers must open and parse `.intake.json`
sidecars directly. Doc 03 § Boundary principle does permit the component to
read sidecars, so this is not a boundary violation — but it makes the
sidecar's internal layout a second, *unversioned* integration surface owned
by docs 01/02, in addition to the versioned one in doc 03. The schema
version gate (§ Component read patterns, and CR-3 below) then guards only
half of what the component actually depends on. One field in the summary
keeps the whole dependency inside the versioned contract.

**Cost:** the data already exists — `assign` produces ranked folders (doc 2,
decision 5 in the overview) and the sidecar stores them. This is
serialization of an existing value, not new computation.

**Truncation at 5** is a proposal, not a requirement: doc 04 shows at most 4
alternates plus the chosen target. If the tools worker prefers "all
candidates above a floor", the extension worker will take whatever is
specified as long as ordering is guaranteed.

**Fallback if rejected:** the component parses sidecar JSON for the ranked
list, and doc 04 Part B gains a note that it depends on the doc 01/02 sidecar
schema directly. Functional, but the coupling should then be acknowledged in
both docs rather than left implicit.

---

## CR-3 — Pin the starting schema version and the compatibility rule

**Section:** § Component read patterns (version gate) and § CLI command
surface (`intake version`)

**Current text:**

> `intake version   # {cli, schema, engine} versions`
>
> Version gate: component calls `intake version` at init; refuses decoration
> (logs, stays inert) if `schema` major ≠ supported.

**Problem:** the gate is specified but unimplementable as written. No schema
version number appears anywhere in the doc set, so there is no value for the
component to compile in as "supported", and nothing states what `schema`
counts (sidecar layout? `--json` shapes? both?) or what format the three
version strings take. "Refuses if major ≠ supported" also leaves the
minor/patch behaviour unstated — the component needs to know whether a minor
bump is guaranteed additive before it decides to tolerate unknown fields.

**Proposed new section (or expansion of § Component read patterns):**

> ## Versioning
>
> - `intake version --json` → `data: {cli, schema, engine}`. All three are
>   semver strings; `engine` MAY be `null` when the beets shim is absent.
>   `cli` versions the command surface, `engine` the identify backend.
> - `schema` versions this document's JSON surface: the sidecar schema plus
>   the `--json` `data` shapes specified here. It starts at **1.0.0** with
>   doc 03 v1 and is bumped by the overseer in the same amendment that
>   changes a shape: additive or newly-optional field → **minor**; removal,
>   rename, type change, or semantic change → **major**.
> - Compatibility rule: a consumer supports one fixed major. It MUST accept
>   any minor/patch within that major, ignoring unknown fields, and MUST
>   refuse to operate against a different major. Producers MUST NOT change
>   the meaning of an existing field within a major.
> - Current value: **schema 1.0.0**. The component's supported major for P4
>   is **1**.

**Note:** if CR-2 is accepted, the current value becomes **1.1.0** in the
same amendment (additive field), and the component still gates on major 1.

**Fallback if rejected:** the component treats a missing/unparseable `schema`
as "assume compatible, log a warning" — which is the opposite of what a gate
is for.

---

## CR-4 — `E_NO_CLI` is host-synthesized, not CLI-emitted (and timeouts need a code)

**Section:** § Error surfaces

**Current text:**

> CLI unavailable / rules repo missing / journal unreachable → distinct error
> codes (`E_NO_CLI`, `E_NO_RULES`, `E_NO_JOURNAL`); component renders inert
> state with tooltip, never blocks playback UI.

**Problem:** the three codes are listed as one set, implying they all arrive
the same way — in the envelope's `errors[]`. `E_NO_CLI` cannot: if the binary
is missing, not executable, or the spawn fails, there is no process to write
an envelope. The CLI cannot report its own absence. So `E_NO_CLI` is
necessarily synthesized by the consumer, and the contract should say so —
otherwise each consumer invents its own spelling for the same condition, and
the tools worker cannot tell whether it is expected to emit the code.

Second gap: doc 04 § Failure behavior sets a 10 s per-command budget
(execute excepted, since it runs detached). A timeout is a distinct
condition from "no CLI" — the binary exists and started — and there is no
code for it.

**Proposed replacement:**

> Error codes are of two kinds.
>
> **CLI-emitted**, appearing in the envelope's `errors[]`: `E_NO_RULES`
> (rules repo missing or unreadable), `E_NO_JOURNAL` (journal unreachable),
> plus further codes owned by the tools worker.
>
> **Host-synthesized**, produced by a consumer when no envelope can exist:
> `E_NO_CLI` (binary not found, not executable, spawn failed, or stdout is
> not a parseable envelope) and `E_CLI_TIMEOUT` (no exit within the
> consumer's budget; the component uses 10 s, `execute` excepted — it runs
> detached with progress observed via `status` polling of `placing`). The
> CLI MUST NOT emit these two codes; they are reserved.
>
> On any of these a consumer renders an inert state with an explanatory
> tooltip, logs, and never blocks playback UI.

**One decision needed:** whether "CLI ran but stdout is unparseable" belongs
under `E_NO_CLI` (folded in above — a CLI that cannot be understood is
functionally absent) or deserves its own `E_BAD_OUTPUT`. The extension worker
has no preference; it needs the answer to pick a tooltip string.

**Fallback if rejected:** the component synthesizes `E_NO_CLI` and
`E_CLI_TIMEOUT` locally anyway, since it has no alternative, and doc 04
documents them as component-local codes. That works until a second consumer
(doc 05 producers) invents different names for the same two conditions.

---

## Requested response

Per request: accept / accept-with-changes / reject. CR-1 and CR-3 are the
two that block Part B implementation outright — the component cannot write
its status parser or its version gate without them. CR-2 is a design
preference with a working (if uglier) fallback. CR-4 is documentation of what
will happen regardless; the value is in naming it once for all consumers.
