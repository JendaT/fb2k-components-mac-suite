# Intake Spec Change Requests

Requests from workers for changes to overseer-guarded specs (currently
`intake-03-contract-spec.md`). Workers MUST NOT edit guarded specs directly;
they file a numbered CR here. The overseer reviews, decides, and — if
accepted — lands the change on main as a numbered entry in `AMENDMENTS.md`
together with the schema/CLI semver bump the change implies.

Status values: `open` | `accepted` | `rejected` | `superseded`.

---

## CR-001 — doc 03 contract gaps found while implementing P1–P3

**Filed:** 2026-07-25
**From:** tools worker (`feature/intake-cli`, HEAD `6fb6d32`)
**Against:** `docs/intake/intake-03-contract-spec.md` (draft v1, 2026-07-11)
**Spec basis:** main@3d146d7 + amendment 001
**Status:** open

Five items surfaced by implementing docs 01–03 in `tools/intake/`. None of
them blocks the CLI today: the package is feature-complete against the
contract as written, all five are places where the contract is silent,
unreachable, or self-conflicting. Grouped as one CR because they all want the
same next contract bump.

Severity below is about the contract, not about the code:
**A** = the contract as written cannot be satisfied or describes something
unreachable; **B** = contract is silent and the implementation had to pick a
behavior; **C** = editorial/completeness.

---

### CR-001.1 — `rejected` status is unreachable (severity A)

**Contract says.** Doc 03 "Status lifecycle (normative)" makes `rejected` a
terminal state reachable from `resolved`, `proposed` and `approved`, and adds:
"Legal transitions only via CLI commands". Doc 04 line 70 already specifies a
rendering for it (grey strike, `✕`), so the component expects to see it.

**Implementation is.** `rejected` exists in the sidecar status union
(`src/types.ts:15`) and nothing else in the CLI references it — there is no
command that performs the transition. Since the component "mutates only
through CLI commands" (doc 03, boundary principle), `rejected` is currently
unreachable by any actor. A release that should be discarded can only be left
`resolved` with `needs_review: true`, which is not the same thing: it stays in
the propose/approve funnel forever.

**Why it matters.** This is the one lifecycle edge the extension worker can
build UI for and never trigger. It is also the natural end state for tier
`reject` releases (doc 01 tier table) and for user-discarded dumps.

**Requested change.** Add to the doc 03 command surface:

```
intake reject  <root...>|--batch <file> [--reason "<text>"]
```

Semantics I would implement, for the overseer to confirm or amend:

- Legal from `new`, `resolved`, `proposed`, `approved`. Refuse from
  `placing`, `placed`, `gc_done` with `E_BAD_STATUS` (a placed release is in
  the library; withdrawing it is a different, un-specced operation).
- Sets `status: "rejected"`, appends a `history[]` entry carrying the
  `--reason` text (free-form, no vocabulary), writes no tags, touches no
  audio, writes no journal record (nothing entered the library).
- Terminal: no command transitions out of `rejected`. Re-entry, if ever
  wanted, is `resolve --force`, which rebuilds the sidecar from scratch —
  worth stating explicitly in doc 03 either way.
- Local files are NOT deleted. Reject is a state change only; disposal of
  local bytes stays a `gc` concern, and `gc` currently only touches `placed`
  roots. If rejected roots should also become gc-eligible, that is a second
  decision — I have deliberately not assumed it.

**Impact.** CLI minor (new command), schema unchanged (the status value is
already in the schema), doc 04 unchanged (rendering already specced).
Affects the extension worker: the reject action becomes callable.

---

### CR-001.2 — `intake bootstrap` is absent from the command surface (severity C)

**Contract says.** Doc 03 "CLI command surface (v1, semver)" lists 11
commands; `bootstrap` is not among them.

**Implementation is.** `intake bootstrap` is specified in doc 02 ("Bootstrap
(one-off command)", doc 02:124–133), implemented (`src/bootstrap.ts`), and
already flagged as a known gap in doc 02:196–197. It is a human-only,
read-only command that generates the initial `genre-map.yaml` /
`label-map.yaml` / naming report from an existing tree; the component never
calls it.

**Why it matters.** Low. The risk is only that doc 03 reads as an exhaustive
surface, so a future reader may treat `bootstrap` as unsanctioned.

**Requested change.** Add to the doc 03 surface block, marked as not part of
the component-facing contract:

```
intake bootstrap --tree <path>... [--prior-weight <w>] [--out <dir>] [--force]   # human-only
```

Alternatively, state in doc 03 that the surface lists component-facing
commands only, and that human-only commands live in docs 01/02. Either
resolves it; the overseer's call which.

**Impact.** Editorial. No CLI or schema change (`bootstrap` already behaves
as documented in doc 02:191–195).

---

### CR-001.3 — execute/gc handling of `quality_shadow` files is unspecified (severity B)

**Contract says.** Doc 03 "Execute protocol" step 2 says "Copy release to a
temp dir", step 3 says "audio_hash of every copy == sidecar hash; file count
match", step 6 says local originals are untouched until `gc`. It never
mentions quality shadows. Doc 01 (mine) defines them: in a mixed-quality
directory the lossless set is primary and each file of the other set is
marked `"quality_shadow": true` in `files[]`, with a
`quality_shadow_set:<codec>` entry in `quality.issues`.

**Implementation is** (`planFiles`, `src/commands-p3.ts:170–192`, and gc at
`:397–425`):

- execute copies primary files only; shadow files are counted
  (`skippedShadows`) and excluded from the copy set and from verification.
- "file count match" is therefore interpreted as *primary* file count, not
  the sidecar's whole `files[]`.
- gc treats all local copies as disposable — shadows included
  (`src/commands-p3.ts:407`) — because the release is in the library in its
  lossless form.
- with `--relocate-dj`, shadows are relocated into the dj zone along with the
  primary files.

**Why it matters.** Two of those three are load-bearing and none is written
down. The verification wording in step 3 is the sharp edge: read literally
("every copy", "file count match") it is satisfiable, but only because the
implementation quietly redefines the file set it applies to. A second
implementer could read it as "copy the shadows too" and produce a library
with lossy duplicates in it.

**Requested change.** Make the shadow rule explicit in doc 03's execute
protocol — proposed wording:

> Files marked `quality_shadow: true` in the sidecar are not placed. The
> copy set, the hash verification of step 3, and the file-count match are all
> over primary (non-shadow) files. Shadows remain local and are disposed of
> by `gc` with the rest of the local original.

And confirm the `--relocate-dj` question, which I consider genuinely open:
should shadows be relocated into the dj zone, or dropped there? Relocating
them costs SSD space for lossy duplicates of material that is already in the
library losslessly; dropping them loses a DJ-usable mp3 that may be the
practical format for that zone. Current behavior is relocate — chosen because
`--relocate-dj` reads as "move, don't delete", not because it is obviously
right. Happy to switch.

**Impact.** No CLI or schema change if the overseer confirms current
behavior (this is documenting what ships). If shadows should be dropped at
relocate, that is a CLI patch on my side.

---

### CR-001.4 — FLAC "recompute+fix if unset" conflicts with the verify step (severity A)

**Contract says.** Doc 03 "audio_hash (normative algorithm)":

> FLAC: `"flacmd5:" + embedded STREAMINFO MD5` (via metaflac; recompute+fix
> if unset, flagged in quality.issues).

and, in the execute protocol, step 3: "Verify: audio_hash of every copy ==
sidecar hash".

**Implementation is.** `resolve` never mutates the input (P1 acceptance gate:
zero file mutations), so it cannot "fix" anything. For a FLAC with an unset
(all-zero) STREAMINFO MD5 it records `"fsha1:" + SHA1(whole file)` plus a
`flac_md5_unset` entry in `quality.issues` (`src/audioHash.ts:62`). Doc 01
was amended to say the fix belongs at execute, on the copies (doc 01:73–76).
**Execute does not currently implement that fix** — it copies, writes
provenance tags, and verifies; `metaflac --add-seekpoint`-style MD5 repair
never happens. So today the file lands in the library with its MD5 still
unset and an `fsha1:` key in the sidecar.

**Why it matters.** The two contract clauses cannot both hold as written:

1. Repairing the STREAMINFO MD5 rewrites bytes inside the file. For a file
   keyed `fsha1:` (whole-file SHA1) that changes the hash by construction, so
   step 3's "audio_hash of every copy == sidecar hash" fails for exactly the
   files the repair applies to.
2. The repaired file's identity key should really become
   `flacmd5:<computed>` — otherwise the release keeps a whole-file key that
   subsequent tag edits will invalidate, which is precisely what the
   contract's "tag edits MUST NOT change audio_hash" rule exists to prevent.

So the repair is not a local detail: it changes a file's hash *kind* mid-
lifecycle, and doc 03 has no notion of that.

**Requested change.** Pick one and write it into doc 03:

- **Option A (repair at execute, re-key).** Order within execute becomes:
  copy → verify copies against the sidecar (`fsha1:`) → repair MD5 on the
  copies → recompute `flacmd5:` → **rewrite the sidecar `files[].audio_hash`
  to the new key**, appending a `history[]` entry — and the journal record
  carries the post-repair hashes. Needs doc 03 to say that `audio_hash` is
  mutable exactly once, at execute, for `flac_md5_unset` files, and that the
  journal is authoritative for the post-placement value. Most correct
  long-term; the largest contract change (hash immutability gets an
  exception).
- **Option B (no repair).** Drop "recompute+fix if unset" from doc 03; such
  files stay keyed `fsha1:` for life, with `flac_md5_unset` in
  `quality.issues` as the permanent marker. Zero code change (this is what
  ships), zero new invariants, at the cost of a weaker identity key for a
  handful of files. Doc 01:73–76 would need a matching amendment.
- **Option C (repair before intake).** Treat MD5 repair as an out-of-band
  preparation step on the income side (a `flac --keep-foreign-metadata`
  re-encode or `metaflac` pass the human runs), and have `resolve` merely
  report it. Keeps both docs' invariants intact; pushes work onto the human.

My recommendation is **B** for the v1 bump and **A** later if unset-MD5 files
turn out to be common in the real income corpus, because A is the only option
that needs a hash-immutability exception and I would rather not spend that
before there is evidence it is needed. I have no data on how common unset MD5
is in the real corpus — the CLI has never run against it.

**Impact.** B: doc 03 wording + doc 01 amendment, no code. A: doc 03 wording
(hash mutability + step order), schema unchanged, CLI minor on my side.
C: doc 03 + doc 01 wording, no code.

---

### CR-001.5 — doc 03's error-code list is not the code inventory (severity C)

**Contract says.** Doc 03 "Error surfaces" names three codes: `E_NO_CLI`,
`E_NO_RULES`, `E_NO_JOURNAL`, in the context of "CLI unavailable / rules repo
missing / journal unreachable".

**Implementation is.** The CLI emits 13 distinct codes in the envelope's
`errors[].code`:

```
E_ARCHIVE  E_ARCHIVE_TOOL  E_BAD_ARGS  E_BAD_STATUS  E_EXISTS
E_NO_EVIDENCE  E_NO_JOURNAL  E_NO_RULES  E_NO_TARGET  E_NOT_FOUND
E_PARSE  E_TARGET_EXISTS  E_VERIFY
```

`E_NO_CLI` is not among them by design: the CLI cannot report its own
absence, so that code belongs to the component.

**Why it matters.** Low but real for the extension worker: doc 03 is where
they look to decide which codes get bespoke rendering and which fall through
to a generic error state. Three named codes read as "these are the codes".

**Requested change.** Either (a) add a code table to doc 03 as part of the
contract — in which case adding a code later becomes a contract bump, which I
would advise against for a CLI still finding its edges; or (b) state that
`errors[].code` is an open vocabulary, that the three named codes are the
ones the component must handle specifically, and that consumers must render
unknown codes generically using `msg`/`path`. I recommend (b), and I will
keep the full list current in doc 01/02 so it is discoverable without being
frozen.

**Impact.** Editorial either way. No code change for (b).

---

### Informational (no request)

- **`identification.status: "source_api"`** appears in doc 05:63 (producer
  protocol, P5). Doc 02's implementation notes define the enum as
  `fast_path | shim | unconfirmed | unidentified`, so `source_api` is a
  fifth value my code does not yet accept. Doc 02 is mine and amendment 001
  was informational, so no CR — I will note `source_api` as reserved for P5
  in doc 02 when P5 work starts, unless the overseer wants it accepted
  earlier.
- **Compliance status.** `status --json` matches the doc 03 summary shape
  field-for-field (`src/sidecar.ts:52–74`), `version` returns
  `{cli, schema, engine}`, and the envelope/exit-code conventions are
  implemented as specced. No other deviations known.

---

## CR-002 — doc 03 gaps found while implementing P4 Part A and drafting Part B

**Filed:** 2026-08-13
**From:** extension worker (`feature/intake-extension`, HEAD `a28cae3`)
**Against:** `docs/intake/intake-03-contract-spec.md` (draft v1, 2026-07-11)
**Spec basis:** main@a28cae3 (doc 03 unchanged since 3d146d7; amendment 001 only)
**Status:** open
**Supersedes:** `docs/intake/CR-EXT-001-doc03.md` (filed 2026-07-25 as a
standalone file, before this register existed; never triaged). Re-filed here
in register form, with three items revised against the CLI that has since
landed on main.

Four items. None affected P4 Part A — the decorator API is generic and
contract-free, and it is merged. **CR-002.1 and CR-002.3 block Part B**
(`foo_jl_intake_mac`): the component cannot write its `status --json` parser
or its version gate without them. CR-002.2 is a design request with a working
but uglier fallback. CR-002.4 duplicates CR-001.5 from the tools worker and
should be resolved once, for both.

Severity uses the same scale as CR-001: **A** = the contract as written
cannot be satisfied or describes something unreachable; **B** = contract is
silent and a consumer must pick a behavior; **C** = editorial.

---

### CR-002.1 — `status --json`: envelope or bare array? (severity A)

**Contract says.** Doc 03 "JSON conventions" states both, one bullet apart:

> - Envelope: `{ "ok": bool, "data": …, "errors": [{code, msg, path}] }`.
> - `status --json` returns an array of sidecar summaries: `{id, root_path, …}`.

"Returns an array" reads as a bare top-level `[…]`; the envelope bullet reads
as `{ok, data: […], errors: []}`. Both cannot hold.

**Implementation is.** Settled, and in the envelope's favour: `src/cli.ts:202`
builds `{ok, data, errors}` for every command and `:203` prints it whenever
`--json` is set. The unwrapped `JSON.stringify(data, …)` at `:149` is inside
`printHuman()`, i.e. the non-`--json` path only. No command emits a bare
array under `--json`.

**Why it matters.** Only the doc is ambiguous now, but it is the doc the next
consumer reads. Guessing wrong is a silent integration failure: the component
would parse `[]` from an envelope, see zero intake rows, and render an empty
non-erroring state.

*Correction to the superseded filing:* it warned this might be a breaking
change for the tools worker. It is not — the CLI already does exactly what is
requested. This is doc-only, zero code impact, and should be the cheapest of
the four to close.

**Requested change.** Replace the first bullets of "JSON conventions" with:

> - **Envelope (universal).** Every `--json` invocation emits exactly one
>   JSON object on stdout: `{ "ok": bool, "data": …, "errors": [{code, msg,
>   path}] }`. The per-command shapes below describe the `data` member only.
>   No command emits a bare array, string, or number at top level.
> - `ok` is `true` iff the exit code is 0. On exit 1 (partial) `ok` is
>   `false`, `data` carries the successful subset, and `errors[]` is
>   non-empty. On exit 2 (error) `data` is `null` and `errors[]` is
>   non-empty. `errors[]` is `[]` whenever `ok` is `true`.
> - `status --json` → `data` is an array of sidecar summaries: `{…}`.

The `ok` ↔ exit-code sentence is a second, smaller gap in the same section:
doc 03 gives exit codes (`0 ok / 1 partial / 2 error`) and an `ok` field but
never relates them, and never says what `data` holds on failure. Worth
closing in the same edit; the CLI's behaviour at `cli.ts:202` already matches
the wording above.

**Impact.** Doc only. No CLI change, no schema change.

---

### CR-002.2 — add `proposal.ranked` to the status summary (severity B)

**Contract says.** `proposal:{target_collection, confidence}`.

**Implementation is.** Exactly that — `SidecarSummary` in
`src/sidecar.ts:52–74` exposes `target_collection` and `confidence` and
nothing else. The ranked candidate list exists upstream (the `assign` engine
produces ranked folders; overview decision 5) and is kept in the sidecar, but
it does not reach the contract surface.

**Why it matters.** Two specified consumers need ranked alternates and
neither can get them from the contract:

- Doc 04 Part B, context actions: "**Assign to \<top alternates\>** — the top
  ranked alternates from the sidecar as individual flat actions (max 4)".
  The ranking is needed at menu-build time, on the main thread, for the
  current selection.
- Doc 05 step 7: suggestion UI backed by the shared `assign` ranking.

Without the field, both must open and parse `.intake.json` directly. Doc 03's
boundary principle permits reading sidecars, so this is not a violation — the
cost is structural: the sidecar's internal layout becomes a second,
*unversioned* integration surface owned by docs 01/02, alongside the
versioned one in doc 03. The schema gate then guards only half of what the
component actually depends on. One field keeps the whole dependency inside
the versioned contract.

**Requested change.** `proposal:{target_collection, confidence, ranked:[{collection, confidence}]}`, plus:

> - `proposal.ranked` is the assignment engine's ordered candidate list, best
>   first, truncated to the top 5. Present when the sidecar has a proposal
>   (status `proposed` or later); omitted or `[]` otherwise.
> - `ranked[0]` is the engine's best candidate. For engine-chosen proposals
>   `target_collection == ranked[0].collection`. After `intake assign --by
>   user`, `target_collection` is the user's choice and MAY be absent from
>   `ranked`, which retains engine order.
> - `confidence` is a float in `[0,1]`, as elsewhere in this document.

Truncation at 5 is a proposal, not a requirement (doc 04 shows at most 4
alternates plus the chosen target). "All candidates above a floor" is equally
fine as long as ordering is guaranteed.

**Impact.** Schema minor — but see CR-002.3: with `schema` currently an
integer there is no minor to bump, which is the reason those two items should
be decided together. Serialization of an existing value; no new computation
on the CLI side. If rejected, the component parses sidecars for the ranking
and doc 04 Part B gains an explicit note that it depends on the doc 01/02
sidecar layout — the coupling should then be acknowledged in both docs rather
than left implicit.

---

### CR-002.3 — the version gate has no version to check against (severity A)

**Contract says.** "`intake version   # {cli, schema, engine} versions`" and:

> Version gate: component calls `intake version` at init; refuses decoration
> (logs, stays inert) if `schema` major ≠ supported.

**Implementation is.** `cmdVersion` (`src/commands.ts:218–219`) returns
`{cli: "0.1.0", schema: 1, engine: "0.1.0"}` — `cli` and `engine` are semver
strings, **`schema` is an integer** (`SCHEMA_VERSION = 1`, `src/types.ts:4`),
and the same integer is written into each sidecar (`resolver.ts:283,463`).

**Why it matters.** The gate is unimplementable from the doc alone: no schema
version value appears anywhere in the doc set, so there is no constant for
the component to compile in as "supported", and the doc never says what
`schema` covers or what type the three fields are. The implementation has
since answered the type question — but in a way the superseded filing got
wrong, so this item is revised rather than repeated.

*Correction to the superseded filing:* it proposed all three fields be semver
strings with major/minor rules. That conflicts with what shipped. An integer
`schema` is defensible and simpler — with one consequence that needs a
decision, below.

**The consequence.** An integer version cannot express an additive change.
If CR-002.2 is accepted, `ranked` appears while `schema` stays `1` (it is
additive, so bumping to `2` would wrongly lock out every existing consumer).
A component built against "schema 1 with `ranked`" then cannot distinguish an
older schema-1 CLI without it. Three ways out, overseer's call:

- **A — keep the integer, make optionality the rule.** State that within a
  schema version, fields may be *added*, and consumers MUST treat unknown
  fields as ignorable and newly-specified fields as optional (feature-detect,
  never assume presence). Zero code change. The component feature-detects
  `ranked`. Simplest, and my recommendation.
- **B — `schema` becomes `major.minor`** (string `"1.1"` or a
  `{major, minor}` pair). Additive → minor bump; breaking → major. Precise,
  and the gate stays a major comparison. Costs a CLI change and a sidecar
  field type change, which is itself breaking.
- **C — capability list**, e.g. `version` also returns
  `features: ["proposal.ranked", …]`. Most flexible, most machinery; not
  worth it at this size.

**Requested change.** Add a Versioning section to doc 03 recording whichever
option is chosen, and in all cases pin the current value:

> - `intake version --json` → `data: {cli, schema, engine}`. `cli` and
>   `engine` are semver strings (`engine` MAY be `null` when the beets shim
>   is absent); **`schema` is an integer**, currently **1**.
> - `schema` versions this document's JSON surface: the sidecar schema plus
>   the `--json` `data` shapes specified here. It is bumped by the overseer
>   in the amendment that makes a breaking change — removal, rename, type
>   change, or semantic change. Additive fields do NOT bump it [option A].
> - Consumers support one fixed `schema` value, MUST ignore unknown fields,
>   MUST treat any field not present in the version they were built against
>   as optional, and MUST refuse to operate on a different value. The
>   component's supported schema for P4 is **1**.

**Impact.** Doc only under option A. Option B is a CLI + sidecar change and
would itself be breaking.

---

### CR-002.4 — `E_NO_CLI` is host-synthesized, and timeouts have no code (severity A)

**Duplicate of CR-001.5** (tools worker), from the other side of the boundary.
Resolve once; the two filings agree.

**Contract says.** "CLI unavailable / rules repo missing / journal
unreachable → distinct error codes (`E_NO_CLI`, `E_NO_RULES`,
`E_NO_JOURNAL`)" — one list, implying all three arrive the same way, in the
envelope's `errors[]`.

**Implementation is.** `E_NO_CLI` is emitted by nobody, deliberately. The
tools worker's CR-001.5 lists the 13 codes the CLI actually emits and states
it plainly: "the CLI cannot report its own absence, so that code belongs to
the component." Both workers reached this independently.

**Why it matters.** `E_NO_CLI` describes a condition in which no CLI process
exists to write an envelope, so a CLI-emitted `E_NO_CLI` is unreachable by
construction. Left as written, each consumer invents its own spelling for the
same condition and the tools worker cannot tell whether it is expected to
emit the code. Second gap: doc 04 sets a 10 s per-command budget (execute
excepted — it runs detached), and a timeout is a *different* condition from
"no CLI" (the binary exists and started) with no code at all.

**Requested change.** Replace "Error surfaces" with:

> Error codes are of two kinds.
>
> **CLI-emitted**, in the envelope's `errors[]`: `E_NO_RULES`,
> `E_NO_JOURNAL`, and the other codes the CLI defines. The vocabulary is
> **open** — consumers MUST render unrecognised codes generically from
> `msg`/`path` rather than failing. (Per CR-001.5(b); the current inventory
> stays discoverable in docs 01/02 without being frozen into this contract.)
>
> **Host-synthesized**, produced by a consumer when no envelope can exist:
> `E_NO_CLI` (binary not found, not executable, spawn failed, or stdout is
> not a parseable envelope) and `E_CLI_TIMEOUT` (no exit within the
> consumer's budget; the component uses 10 s, `execute` excepted). The CLI
> MUST NOT emit these two; they are reserved.
>
> On any of these a consumer renders an inert state with an explanatory
> tooltip, logs, and never blocks playback UI.

**One decision needed.** Whether "CLI ran but stdout is unparseable" belongs
under `E_NO_CLI` (folded in above — a CLI that cannot be understood is
functionally absent) or deserves its own `E_BAD_OUTPUT`. No preference; the
component needs the answer only to pick a tooltip string.

**Impact.** Doc only. Adds two reserved names and a MUST-NOT-emit rule; no
CLI change (this documents what already happens), no schema change.

---

### Informational (no request)

- **Support for CR-001.1 (`intake reject`).** As the consumer that would use
  it: doc 04 already specifies the rendering (grey strike, `✕`, doc 04 line
  70) for a state no actor can currently reach, which is the one lifecycle
  edge the component can draw and never trigger. The proposed semantics read
  correctly from this side. One detail worth pinning in the same edit if it
  is accepted: whether `rejected` roots stay visible to `status --json` — the
  component needs them listed to render the strike, so they must not be
  filtered out of the default inventory.
- **P4 Part A is merged** (main@a28cae3 contains it). The decorator API in
  `shared/jl_decorator_api.h` is generic and has no dependency on this
  contract; nothing in CR-002 affects it. All four items are about Part B.

---

## CR-004 — doc 03 gaps found while planning P4 Part B

**Filed:** 2026-11-14
**From:** extension worker (`feature/intake-extension`, HEAD `811579e`)
**Against:** `docs/intake/intake-03-contract-spec.md` (v1.1, amendment 002)
**Spec basis:** main@c712783. CLI facts checked at `feature/intake-cli`@9cc4393.
**Status:** open

Thirteen items. **None blocks Part B.** Each has a component-side fallback,
stated per item, and the Part B plan builds the fallback. They are filed now,
before building, so amendment 003 can take them together with CR-003.

Overlaps the overseer has already noted:
- CR-004.1: the "schema major" wording, already planned for 003.
- CR-004.12: the `E_BAD_STATUS` rules planned for 003.

Severity uses the CR-001 scale: **A** = unsatisfiable or unreachable as
written; **B** = silent, so the consumer has to pick a behaviour;
**C** = editorial. Citations `03:N` are doc 03 lines, and `*.ts:N` are
`tools/intake/src` lines on `feature/intake-cli`@9cc4393.

---

### CR-004.1 — version gate still says "schema major" (severity C)

**Problem.** 03:160-161 refuses decoration "if `schema` major ≠ supported".
That contradicts the integer `schema` at 03:93 and 03:101-104.

**Requested change.** "...if `schema` is not the supported integer."

**Impact.** Doc only.

### CR-004.2 — "the three codes named in this document" (severity C)

**Problem.** 03:170-171 refers to "the three codes named in this document".
Since `E_NO_CLI` moved to the host-synthesized group, it is unclear which
three codes are meant.

**Requested change.** Name them.

**Impact.** Doc only.

### CR-004.3 — scope of the inert state (severity B)

**Problem.** 03:182-183, "On any of these a consumer renders an inert state",
read literally makes a per-command error such as `E_BAD_STATUS` on one root
turn the whole provider inert.

**Requested change.** Inert applies only on a version-gate failure, or when no
`status` load has ever succeeded (`E_NO_CLI`, `E_NO_RULES` or `E_CLI_TIMEOUT`
on `version`/`status`). Every other error is reported per command. A failed
refresh after a good load keeps the last data.

**Component fallback.** Exactly the rule above.

### CR-004.4 — `collections --json` data shape (severity B)

**Problem.** 03:48 lists the command but gives no `data` shape. The CLI
returns `[{collection, artists, releases}]`, sorted by collection
(`commands-p2.ts:318-337`).

**Requested change.** Pin that shape. Additive, so schema stays 1.

**Component fallback.** Tolerant parsing; only `collection` is required.

### CR-004.5 — `--filter` keys (severity B)

**Problem.** 03:47 does not list the keys. The CLI accepts:
- `status`, `needs_review`, `income_folder`, `source_type`,
  `tier`/`tier_eligible`, `virtual`, `singles`, `albumartist`, `album`,
  `root_path` (`commands.ts:180-194`);
- unknown keys silently match nothing;
- one value per key (`cli.ts:85-88`);
- every filtered call still walks and parses every sidecar
  (`commands.ts:203-220`).

Doc 04's "targeted `status --json --filter`" refresh therefore costs as much
as a full load.

**Requested change.** Pin the key list, add `id`, and make an unknown key
`E_BAD_ARGS`.

**Component fallback.** A coalesced full reload, with no `--filter`.

### CR-004.6 — per-file layout at execute (severity B)

**Problem.** "Swap to library paths" needs a destination per file, but the
contract gives only the release-level `placed.target_path` (03:76-79). The
CLI keeps each file's path relative to the root (`commands-p3.ts:261,391`)
and does not place `quality_shadow` files (`skipped_shadows`, `:367`).

**Requested change.** Pin: "files are placed at
`target_path/<path relative to the root>`; `quality_shadow` files are not
placed".

**Component fallback.** Rely on today's behaviour, and `stat` every library
file before swapping a row.

### CR-004.7 — income folder paths are not exposed (severity B)

**Problem.** 03:158 has the component watch "income roots", but the summary
carries only `root_path` (03:76-77). A `scan` that creates roots in a folder
the component has never seen lands outside the watch set.

**Requested change.** An additive, read-only income list, e.g.
`intake income --json` → `[{name, path, exists}]`.

**Component fallback.** Watch the folders listed in preferences plus the
parents of known roots.

### CR-004.8 — `needs_review` on `new` (severity C)

**Problem.** Doc 01:49-52 keeps `<0.50` roots `new` with
`needs_review: true`, and singles always carry the flag (01:102-103). 03:20
allows the flag only on resolved and proposed.

**Requested change.** Allow it on `new`.

**Component fallback.** Render `new` with the flag as `new`, plus a "needs
review" tooltip.

### CR-004.9 — one 10 s budget for every command except execute (severity B)

**Problem.** The budget at 03:178-180 is too short for two commands:
- `propose` runs network lookups and the beets shim, which has no timeout
  (`providers.ts:176`);
- `gc` re-verifies against the journal and may relocate (03:134-135).

Killing a mutating command at 10 s risks a half-written, non-atomic sidecar.

**Requested change.** A long-running budget class (propose, gc, scan), or a
statement that consumers must not kill mutating commands at 10 s.

**Component fallback.** Report `E_CLI_TIMEOUT` at 10 s, keep the command
running and refresh when it exits; hard cap at 15 min.

### CR-004.10 — capability detection (severity B)

**Problem.** `version` has no command list (03:91-93), and an unknown command
returns `E_BAD_ARGS`, the same code as a usage error. Telling them apart by
`msg` text is not contractual.

**Requested change.** An additive `commands: [...]` in `version` data.
Schema stays 1 under the additive rule.

**Component fallback.** Reject is shown when `cli` semver is 0.2.0 or later.

### CR-004.11 — confidence and `needs_review` after `assign --by user` (severity B)

**Problem.** Their meaning after a user assignment is unspecified (03:83-87).
Today:
- the CLI writes `confidence: 1` (`commands-p2.ts:236`);
- it never clears `needs_review` (`:156,282`);
- the sidecar records `proposal.assigned_by: "user"` (`:240`), but the
  summary omits it (`sidecar.ts:92`).

**Requested change.**
- Pin what both fields mean after a user assignment.
- Add `proposal.assigned_by` to the summary. Additive.

**Component fallback.**
- It reads `assigned_by` from the sidecar and treats a user-assigned root as
  reviewed: no amber.
- The badge shows "yours" instead of `1.00`.

### CR-004.12 — legal source statuses and the `execute --dry-run` shape (severity B)

**Problem.**
- Legal source statuses are pinned only for `reject` (03:55-58).
- The `execute --dry-run` data shape is unspecified, though doc 04:175 needs
  it for describe-then-confirm.
- `proposal.target_path` exists in the sidecar (02:107) but not in the
  summary (03:78).

**Requested change.**
- Per-command legal source statuses, with `E_BAD_STATUS` otherwise. This
  overlaps the 003 plan.
- Pin the dry-run data `{id, root_path, target_path, dry_run, files,
  artifacts, skipped_shadows}` (`commands-p3.ts:364-367`).
- Optionally, `proposal.target_path` in the summary.

**Component fallback.** An explicit enable matrix, and tolerant dry-run
parsing in which every field is optional.

### CR-004.13 — does the sidecar survive `gc`? (severity C)

**Problem.** 03:17 lists `gc_done`, but 03:134-135 does not say whether the
sidecar survives `gc`, so it is unclear whether `gc_done` ever appears in
`status`. The CLI keeps the sidecar as a `gc_done` tombstone
(`commands-p3.ts:557`).

**Requested change.** Pin that.

**Impact.** Doc only.
