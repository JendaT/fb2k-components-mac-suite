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

## TR-001 — tools-worker response to CR-EXT-001

**Filed:** 2026-08-13
**From:** tools worker (`feature/intake-cli`)
**Re:** `docs/intake/CR-EXT-001-doc03.md` (extension worker, 2026-07-25)
**Status:** open — for the overseer's decision, not a decision itself

CR-EXT-001 asks the tools worker one direct question (CR-1: "check current
implementation") and three that carry implementation consequences. Answers
below are from the shipped CLI at `tools/intake/`, verified by running it, not
from reading the spec.

Summary of positions: **CR-1 accept** (nothing to change — one correction to
the proposed text, already implemented), **CR-2 accept** (cheap; four
precision notes), **CR-3 accept-with-changes** (as written it conflicts with
what `intake version` emits today, in two ways), **CR-4 accept** (no tools
work; one preference offered).

### On CR-1 — envelope vs. bare array

**No bare arrays exist.** `src/cli.ts` wraps every `--json` invocation in
`{ok, data, errors}` and prints exactly one line; `status --json` has always
returned the array under `data`. The "if the tools worker has already shipped
bare arrays" branch does not apply, and the sniff-the-first-byte fallback is
unnecessary. Envelope-everywhere can be pinned at zero cost to this side.

Two notes on the proposed replacement text:

- *"`ok` is `true` iff the exit code is 0"* — holds today at every return
  site. `ok` is computed as `errors.length === 0`, and every command's exit
  code is 0 exactly when it has no errors. Safe to pin.
- *"On exit 2 `data` is `null`"* — did **not** hold. `fail()` emitted `null`,
  but the "nothing matched" paths emitted `[]` (`identify`/`assign`/`propose`/
  `approve`/`execute`/`gc` with no resolvable refs, `scan` with every income
  path missing). Same exit code, two payload types. This was a defect on our
  side regardless of how doc 03 is worded, so it is **fixed** (commit
  `04a9a1d`): a shared `finish()` now yields 0 + rows, 1 + subset, or 2 +
  `null`. The proposed sentence can therefore stand as written.

Suggested addition while this section is open, since it is what a consumer
actually needs to detect "no envelope": **in `--json` mode the CLI writes
exactly one JSON object to stdout and nothing else** — human-readable output
is only produced without `--json`, and diagnostics go to stderr. A crash
yields empty stdout with a non-zero exit, which CR-4's `E_NO_CLI` definition
already covers.

`test/envelope.test.ts` now pins all of the above across 11 invocations, so a
future change cannot silently break the component's parser.

### On CR-2 — `proposal.ranked` in the status summary

Accept. The data exists and needs no recomputation; the summary is built by
`summarize()` in `src/sidecar.ts` and this is one field. Four points of
precision for the amendment text:

1. **`score`, not `confidence`, is the stored name.** The sidecar holds
   `ranked: [{collection, score, evidence:{artist_prior, label_prior,
   similar_vote, style_hint}}]`. It is the same quantity on the same scale:
   the proposal's top-level `confidence` *is* `ranked[0].score`, both floats
   in `[0,1]` rounded to 2 decimals. Exposing it as `confidence` in the
   summary is a rename, not a conversion — worth stating so nobody later
   assumes two different numbers.
2. **Ordering is deterministic**: score descending, ties broken by collection
   name ascending. Guaranteeing "best first" in the spec is safe.
3. **Membership**: `ranked` holds only collections with at least one piece of
   evidence (artist prior, label prior, similar-artist vote, or style hint),
   so it is normally short. Two shapes worth knowing: when the engine
   short-circuits on a strong single-folder artist prior, `ranked` has exactly
   one entry; when there is no evidence at all there is no proposal, so the
   `proposal` member is `null` and the question does not arise.
4. **After `assign --by user`**: if an engine proposal existed, `ranked`
   retains engine order and the user's pick may be absent — exactly as the
   proposed rule says. If the user assigned a release the engine could not
   rank, `ranked` is `[{collection: <user's pick>, score: 1}]`. So `ranked` is
   never empty when a proposal exists, and `alternates_shown` (already in the
   sidecar) records whether there was more than one candidate.

Truncation at 5 is fine. We will emit `min(5, n)` in stored order.

### On CR-3 — schema version

Accept the intent; the current text cannot be adopted verbatim because
`intake version --json` today emits:

```json
{"ok":true,"data":{"cli":"0.1.0","schema":1,"engine":"0.1.0"},"errors":[]}
```

Two conflicts:

1. **`schema` is an integer, not a semver string.** Adopting "all three are
   semver strings, starting at 1.0.0" changes the type of a field doc 03
   already specifies. It is the right change and now is the moment — no
   consumer parses it yet — but it should be called out in the amendment as a
   type change rather than a clarification, and it is a CLI change on our
   side.
2. **The sidecar carries its own `"schema": 1`** (integer, doc 01). If doc
   03's `schema` becomes semver, the two must be related explicitly or they
   will drift. Proposal: the sidecar's integer stays and is defined as *the
   major*; `version.schema`'s major MUST equal it. Doc 01 is worker-owned and
   we will state that there once the amendment lands.

Also: `engine` is currently a hardcoded `"0.1.0"` and does not reflect whether
the beets shim is actually present. CR-3's "`engine` MAY be `null` when the
beets shim is absent" is the better contract; we will implement probe-based
reporting with it. Note the shim remains **untested against a real beets
install** — only against a fake shim in tests — so whatever `engine` reports
is the adapter's version, not a verified backend.

### On CR-4 — reserved host-synthesized codes

Accept; no tools work. The CLI emits 13 codes and neither `E_NO_CLI` nor
`E_CLI_TIMEOUT` is among them (full list in CR-001.5). The MUST-NOT-emit rule
is now enforced mechanically by `test/envelope.test.ts`, which fails if either
string appears as an emitted code anywhere in `src/`.

On the open question — "CLI ran but stdout is unparseable": weak preference
for folding it into `E_NO_CLI` rather than adding `E_BAD_OUTPUT`. A CLI whose
output cannot be understood is functionally absent, the consumer's remedy is
identical, and it keeps the reserved set at two.

**Overlap:** CR-4 and our CR-001.5 are the same section from opposite sides —
they want the two host codes named and fenced off, we want the CLI-emitted
vocabulary declared open rather than frozen as a table. The two are
compatible and would be cleanest resolved in one amendment.
