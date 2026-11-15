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
**Status:** accepted (amendment 002, 2026-08-26, contract v1.1). CR-001.1
accepted with modification, CR-001.2 and CR-001.3 accepted, CR-001.4
option B accepted (superseded by CR-003 option d, amendment 003), CR-001.5
option (b). Implemented on this branch: `reject` (0533e25); CR-001.4 by
CR-003 (4cec147).

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
**Status:** closed (amendment 003, 2026-11-15). The CR-1, CR-2 and CR-4
positions were accepted in amendment 002 (CR-002.1, CR-002.2, CR-002.4);
the CR-3 schema-to-semver proposal is superseded by the integer `schema`
(CR-002.3 option A).

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

---

## CR-003 — unset-MD5 FLAC can never be placed: tag write breaks the `fsha1:` verify

**Filed:** 2026-11-14
**From:** tools worker (`feature/intake-cli`, HEAD `9fbcd2c`)
**Against:** `docs/intake/intake-03-contract-spec.md` v1.1 (2026-08-26)
**Spec basis:** main@c712783 + amendment 002
**Status:** accepted, option (d) (amendment 003, 2026-11-15, contract v1.2),
with the fallback chosen by the user: without a usable decoder `fsha1:` +
`flac_decoder_missing`/`flac_decode_failed`, `needs_review` on the root, no
provenance tags on that file. Implemented in 4cec147 with both regression
tests; 12/20-bit FLAC still to be checked against a re-encode on the first
real file.
**Severity:** A (the contract as written cannot be satisfied)

**Contract says.** Doc 03 "audio_hash": a FLAC whose STREAMINFO MD5 is unset
is keyed `"fsha1:" + SHA1(whole file)` for life, with `flac_md5_unset` as the
permanent marker and no repair at any stage (CR-001.4 option B). Execute
protocol step 2 writes the final tags (provenance `INTAKE_*`, VorbisComment)
into the copies; step 3 requires audio_hash of every copy == sidecar hash.
Doc 03 also says tag edits MUST NOT change audio_hash for flac.

**Implementation is.** Execute does exactly that: copy, `metaflac` tag write
(`src/provenance.ts`), then `verifyTree` re-hashes every copy
(`src/commands-p3.ts`). A tag write rewrites bytes inside the file, so the
whole-file SHA1 of an unset-MD5 FLAC changes by construction. Verify fails
and the release reverts to `approved`. Any release containing one such file
can never be placed.

**Repro (2026-11-14, synthetic fixture, metaflac 1.5.0).** Copies of the
three FLACs in the repo's unset-MD5 fixture root
(`fixtures/income/todo/Bluetech [2011] Cosmic Dubwise`), `writeProvenance`,
then `audioHash` again: both unset-MD5 files change hash, the normal FLAC
stays stable. `bun test` does not catch it.

**Correction to CR-001.4 / amendment 002.** CR-001.4 stated "today the file
lands in the library with its MD5 still unset", and amendment 002 accepted
option B partly on that premise. That holds only where `metaflac` is absent
(the tag write is then skipped with `metaflac_missing` and the hash stays
put). With `metaflac` installed, which is the normal setup, it does not land.

**Options considered.**

- **(a) Skip provenance tags on `fsha1:`-keyed files** and record an issue
  such as `provenance_tags_skipped:flac_md5_unset`. Keeps the for-life key.
  Conflicts with step 2 for those files, which then reach the library
  without `INTAKE_*` tags. Smallest code change.
- **(b) Hash the copy before tagging.** Rejected: the placed file no longer
  matches the sidecar/journal hash, so `gc` re-verify (which re-hashes the
  target) refuses to delete, and the journal key is wrong.
- **(c) A tag-immune fallback over the FLAC frame bytes** (e.g. SHA1 of the
  bytes after the last metadata block). A new hash kind that nothing else
  produces, and it changes if the file is ever re-encoded.
- **(d) Key unset-MD5 FLACs by the MD5 a correct STREAMINFO would hold:**
  `"flacmd5:" + MD5(decoded audio)`, computed as
  `flac -d --force-raw-format --endian=little --sign=signed` → MD5
  (interleaved samples, little-endian signed, whole bytes per sample).
  `flac_md5_unset` stays in `quality.issues` as the marker that the value
  was computed, not read. **Chosen.**

**Premise check for (d)** (user's condition: computed MD5 == embedded MD5
for normal FLACs, including at least one 24-bit file). Run 2026-11-14 on
copies of the repo fixtures, flac 1.5.0:
1. **Holds.** 28 of 28 normal FLACs: computed MD5 == embedded STREAMINFO MD5.
   25 are 16-bit and 3 are 24-bit.
2. **Tag-immune.** Both unset-MD5 copies decode to the same MD5 after the
   provenance tag write as before it.
3. **Repair-stable.** Re-encoding an unset-MD5 file with `flac -f` writes
   exactly the computed value into STREAMINFO, so the key survives a later
   repair.
4. **Not verified: bit depths that are not a multiple of 8** (12/20-bit).
   I tried to generate one with sox and ffmpeg; both stored 24-bit, so no
   true fixture exists. Such files are rare. The implementation treats them
   like any other depth (whole bytes per sample), and the first real sample
   should be checked against a re-encode.

**Decided in amendment 003, my proposals:**
- **Decoder missing or decode fails** (no `flac` on PATH, corrupt frames):
  fall back to `fsha1:` plus an issue (`flac_decoder_missing` /
  `flac_decode_failed`), and skip provenance tags on that file as in (a), so
  the release stays placeable. `flac` becomes a resolve-time dependency;
  today `audioHash` parses STREAMINFO itself and needs no binary.
- **Schema stays 1, CLI minor** (agreeing with the overseer's planned
  position). The shape and type of `audio_hash` are unchanged; only which
  algorithm produces the value for one rare file class changes. No consumer
  compares hashes: `feature/intake-extension` has no reference to
  `audio_hash`, `flacmd5` or `fsha1` (checked 2026-11-14), and doc 04 has
  none. Doc 05 step 1 mentions a "hash-metadata lookup" for the producer's
  in-collection marker. P5 is not built, and a tag-immune key only helps
  it.
- **Migration: none.** No sidecars or journal exist anywhere, production or
  test. The Amunet test environment (`music.intake-test`) has only ever seen
  a `scan --dry-run` (verified by the overseer, 2026-11-14).

**Regression gate.** A test that runs `execute` on a release containing an
unset-MD5 FLAC with `metaflac` on PATH. It asserts the release reaches
`placed` with `verified: true`, the copy carries the `INTAKE_*` tags, the
sidecar key is `flacmd5:` with `flac_md5_unset` present, and `gc`
re-verify passes. A second test runs with `flac` absent and asserts the
`fsha1:` fallback, the issue, and still `placed`. Both land with the
implementation commit; the first fails on the current code.

**Impact.** Doc 03 "audio_hash" (FLAC bullet), plus the fallback wording.
Doc 01 hash notes (worker-owned, with the implementation). CLI minor.
