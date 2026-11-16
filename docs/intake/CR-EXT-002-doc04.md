# CR-EXT-002 — doc 04 changes for Swap, Delete local copy, row colours and the cache gate

**Filed:** 2026-11-16
**From:** extension worker (`feature/intake-extension`, HEAD `15d2c4d9`)
**Against:** `docs/intake/intake-04-extension-spec.md` v1.2 (2026-11-15,
`4d17519b` on this branch; main still carries v1.1)
**Spec basis:** main@ee7aee15 + amendment 003 (merged here as `1dcd3859`)
**Route:** doc 04 is worker-owned, but spec changes reach main only as
numbered amendments: the overseer folds this CR into amendment 004. Doc 04 is
not edited on this branch. Filed as its own file, like CR-EXT-001, because
`CHANGE-REQUESTS.md` registers requests against the guarded doc 03.
**Status:** open

Eight items. B9 (Swap to library paths, Delete local copy), B10 (row colours,
confirmations) and the P4 cache gate were built and accepted in-app after doc
04 v1.2 was written. Where they settled something doc 04 leaves open, or do
something other than it says, the doc now trails the code. Items 1–5 are the
B9/B10/gate changes; items 6–8 are further contradictions found while checking
doc 04 v1.2 against HEAD. Each item quotes doc 04 verbatim, gives the proposed
text and one line of rationale citing the implementing code.

**Contract impact: none.** Doc 03 v1.2 is unchanged, `schema` stays 1, and no
CLI change is requested. Item 2 refers to a `gc --dry-run` reply that is
proposed separately for amendment 004; nothing here depends on it.

Severity, the CR-001 scale adapted to a worker spec checked against its code:
**A** = doc 04 says something the code does not do; **B** = doc 04 is silent
where the code had to choose; **C** = editorial. Citations `04:N` are doc 04
v1.2 lines; `src/…` and `Tests/…` are relative to `extensions/foo_jl_intake_mac/`
at `15d2c4d9`.

---

### CR-EXT-002.1 — Swap to library paths (B9) (severity A)

**Doc 04 v1.2, "Context actions", 04:249-255:**

```text
- **Swap to library paths** (files untouched): prefix mapping
  (`<nas-prefix>` → `/Volumes/<share>`) on `placed.target_path` plus the
  file's path relative to the root (doc 03 layout); only files that exist in
  the library, shadows untouched. Paths go through
  `filesystem::g_get_canonical_path` on the mount point whose canonical form
  matches the playlist's items, so no duplicate metadb entries; no match:
  skip and log.
```

**Proposed:**

```text
- **Swap to library paths** (files untouched; no CLI call and not on the
  mutation lane, so it stays enabled while an execute runs): the selected
  rows of the active playlist that map by income path to a qualifying root.
  Each root's sidecar is read afresh. A row is swapped only when its file is
  a `files[]` entry that is not a `quality_shadow` and has a library copy;
  shadow rows and rows the sidecar does not list (a whole-folder root's
  covers, cues, logs) are left alone. Library path = `placed.target_path` +
  `/` + `files[].path` (doc 03 layout), then the library prefix pair
  (`swap_prefix_from` → `swap_prefix_to`) rewrites it when it lies under
  `swap_prefix_from`, whole components only. A `target_path` outside a
  usable pair is used unchanged, logged at Debug (user decision 2026-11-16:
  the CLI may already report Mac paths). The copy must exist as a regular
  file: the sidecar's spelling, then the other Unicode form, under each
  mount of the share. It is converted with `filesystem::g_get_canonical_path`
  on a mount whose volume form an item of the playlist already uses, else on
  the mount whose form foobar2000 resolves back to that mount, so no
  duplicate metadb entries; neither: the row is skipped ("no matching
  mount"). Main-thread conversions stop at 200 ms; later rows are skipped. A
  playlist locked against replacing items (`playlist_lock::filter_replace`)
  is refused whole. One undo backup, every occurrence of each handle
  replaced, one console line with the count and the skip reasons.
```

**Rationale:** `src/Integration/IntakeActions.mm:1503-1529` (selected rows,
active playlist) and `src/Core/IntakeActionTable.mm:80-82,157-159` (not
mutating; `placed` with `placed.verified`); `src/Core/IntakeSwapPlanner.mm:251-272`
(unlisted and shadow skipped), `:238-249` and `:190-201` (target +
`files[].path`, prefix rewrite, outside the pair unchanged at `:196`);
`src/Integration/IntakeSwap.mm:138-141` (Debug line), `:146-166` (stat),
`src/Core/IntakeSwapPlanner.mm:398-409` (mount choice with the round-trip
fallback that 04:254-255 omits), `src/Integration/IntakeSwap.mm:33,346-352,400-411`
(200 ms budget, lock refusal, undo backup and replace).

### CR-EXT-002.2 — Delete local copy… (B9) (severity A)

**Doc 04 v1.2, "Context actions", 04:256-259:**

```text
- **Delete local copy** → `gc <ids>`: never `rejected`, never a root that is
  not `placed`, never `gc --all` (permanent guard). The confirmation lists the
  local paths and offers **Swap, then delete** while rows still point at
  income paths. A library index (library path → root) covers swapped rows.
```

**Proposed:**

```text
- **Delete local copy…** → `gc <ids> --json` on the mutation lane, only for
  roots captured as `placed` with `placed.verified` true and a non-empty
  `id`, each once: a permanent component-side guard that stays after
  CR-004.14. No mutating call is spawned with zero ids and there is no
  all-roots form (never `gc --all`, never a bare `gc`); never while inert. A
  library index (library path → root) adds rows already swapped, for Delete
  only. With `confirm_gc` on (default) the roots' sidecars are read afresh
  (no answer in 10 s: one Error line, nothing deleted) and the confirmation
  lists the local files from each sidecar's `files[]` as
  `root_path/<files[].path>`, shadows included, up to 10 then "and N more",
  notes that a whole-folder root's other files go too, and names roots whose
  sidecar could not be read (user decision 2026-11-16: the list comes from
  `files[]`, not `gc --dry-run`, for which doc 03 v1.2 pins no reply; a
  `gc --dry-run` reply is proposed separately in amendment 004, and the
  sheet may switch to it only after 004 lands). It counts the entries in
  every playlist that still play these files; a mac-volume entry whose path
  could not be converted counts as unchecked, never as clear. **Swap, then
  delete** is offered only when such entries exist and every one has a
  library copy, i.e. is a `files[]` entry that is not a shadow (rows of a
  root whose sidecar could not be read count as movable). With shadow or
  unlisted rows it is not offered: the sheet says Delete leaves them as dead
  entries, and plain Delete stays available (user decision 2026-11-16).
  Swap, then delete swaps in the playlist the menu came from, then in every
  other playlist holding such rows, and runs gc only when afterwards no
  entry anywhere points at an income path and none is unchecked (slow
  volume); otherwise one Error line and nothing is deleted. On confirm the
  roots are rechecked against the current snapshot (still `placed` and
  verified). `confirm_gc` 0 skips the sheet: gc at once.
```

**Rationale:** `src/Core/IntakeActionTable.mm:303-312,326-330` (guard: status,
`placed.verified`, non-empty `id`, each once), `src/Core/IntakeCommandArgs.mm:86-88`
(zero ids refused; the argv at `:248-271` has no `--all`),
`src/Integration/IntakeActions.mm:1531-1585` (inert refusal, `confirm_gc` 0 at
`:1550-1553`, 10 s read limit), `src/Core/IntakeGcPlan.mm:21-26,52-101` (list
and sheet text), `src/Integration/IntakeSwap.mm:546` (census over every
playlist), `src/Integration/IntakeActions.mm:1112-1125` with
`src/Core/IntakeGcPlan.h:61-63` (offer rule, no library stat before the sheet),
`:1257-1271` and `:1197-1220` (swap everywhere, then the clear check),
`:1161-1192` (recheck), `src/Core/IntakeActionTable.mm:267-272` (library roots:
Delete only); 04:258-259 offers the button whenever rows remain, which the
code does not.

### CR-EXT-002.3 — Row colours (B10) (severity A)

**Doc 04 v1.2, "Preferences page", the fragment in 04:286-287:**

```text
`intake income`), library prefix mapping (one pair, for Swap), tint colours
(new, review, proposed, approved, placed, rejected; sRGB `0xRRGGBBAA`),
```

**Proposed** (replaces only `tint colours (new, review, proposed, approved,
placed, rejected; sRGB `0xRRGGBBAA`),`):

```text
row colours: six configInts `tint_new` (new, resolved), `tint_review`
(amber), `tint_proposed`, `tint_approved` (approved, placing), `tint_placed`
(placed and verified) and `tint_rejected`, each a packed sRGB `0xRRGGBBAA`
(a colour well with opacity, a "No tint" checkbox, Reset colours); 0 = no
tint, absent = the default palette, a value outside 0..0xFFFFFFFF = the
default and one Debug line,
```

**Doc 04 v1.2, "Row decorations", 04:194-195** (anchor; add a bullet after it):

```text
- **Amber** = `needs_review` on a resolved or proposed root, with or without a
  proposal; a user-assigned proposal keeps it while the flag is set.
```

**Proposed** (new bullet):

```text
- **Colours** come from the `tint_*` settings; defaults blue `0x4A90D938`,
  amber `0xE5A50A38`, teal `0x2AA19838` (proposed and approved), green
  `0x3FB95038`, grey `0x80808028`. The icons that take a colour (⚠ and ◐ on
  amber, ● on placed) draw it at full opacity, except on a tint whose alpha
  is `0x99` (60%) or more, where they use the host's label colour, as every
  other icon does. A tint of 0 draws no background and leaves its icon in
  the label colour; a colour with alpha 0 draws no background but still
  colours those icons.
```

**Doc 04 v1.2, "Group header badge", 04:205-207** (append to this bullet):

```text
- Amber on the review rule or confidence below 0.6, with the first other
  `ranked` entry as a hint in the text (API v1 has no group tooltip), e.g.
  `→ [Collection A] · 0.61 (alt: [Collection B])`; no hint without `ranked`.
```

**Proposed** (appended sentence):

```text
  The amber badge uses the review colour at full opacity at any tint alpha
  (the group header is not tinted); `tint_review` 0 gives the host's colour.
```

**Doc 04 v1.2, "Refresh and invalidation", 04:172-174:**

```text
- **Invalidation:** per-root visual fingerprints are diffed; any change, the
  first successful load or a colour/config change fires one invalidate-all,
  never from inside `decorate()`.
```

**Proposed:**

```text
- **Invalidation:** per-root fingerprints (match key, members, row visual,
  group badge) are diffed; any change or the first successful load fires one
  invalidate-all, never from inside `decorate()`. A colour change rebuilds
  the visuals from the last successful load on the loader queue, with no CLI
  call, and fires one invalidate-all only when a row or badge now renders
  differently and the provider is not inert (none when no root uses the
  changed colour). The page writes a colour 0.25 s after the well's last
  change, so a drag rebuilds once.
```

**Rationale:** `src/Core/IntakeTint.h:5-28` and `src/Core/IntakeTint.mm:97-113`
(keys, storage, absent/0/malformed), `src/Core/IntakeDecorationMap.h:79-88`
(defaults) and `:123-139` with `src/Core/IntakeDecorationMap.mm:68,80,101`
(icon colour rule), `src/Core/IntakeGroupBadge.mm:80` (badge at full opacity),
`src/Core/IntakeLoader.mm:592-610` with `src/Core/IntakeLoadPolicy.mm:80-89`
(rebuild from the last load, invalidate only on a rendered change and not
inert), `src/Integration/IntakeService.mm:259,272-274` (no CLI call on a colour
change), `src/UI/IntakePreferencesController.mm:96,518-524` (0.25 s write, the
page's hint); 04:173 promises an invalidate-all on every colour change.

### CR-EXT-002.4 — Confirmations (B10) (severity C)

**Doc 04 v1.2, "Preferences page", 04:288:**

```text
confirmation toggles (Delete, Reject; Execute always asks), log level. A
```

**Proposed** (replaces `confirmation toggles (Delete, Reject; Execute always
asks),`):

```text
confirmations: "Ask before Delete local copy" (`confirm_gc`) and "Ask
before Reject" (`confirm_reject`), configInts, on unless 0, default on.
Off runs the command at once with no sheet (Reject then without a reason)
and drops the item's ellipsis from the next menu. Execute placement always
asks (dry run, then its sheet).
```

**Rationale:** `src/UI/IntakePreferencesController.mm:540-557,1209,1214` (both
checkboxes and the Execute note), `src/Integration/IntakeConfig.h:88-89` with
`src/Core/IntakeSettingsParse.h:161-167` (keys, default on, 0 = off),
`src/Core/IntakeActionTable.mm:116-124,280` (ellipsis follows the setting,
Execute always), `src/Integration/IntakeActions.mm:1550-1553,1707-1716` (off:
gc at once, Reject without a reason).

### CR-EXT-002.5 — Acceptance: the Part A cache-hit gate (P4) (severity B)

**Doc 04 v1.2, "Acceptance (P4 gate)", 04:328-334:**

```text
- With intake provider on a 5k-row playlist incl. 200 intake rows: smooth
  scroll (no frame drops from decoration path; cache hit ≥99% steady-state,
  measured provider-side: a second scroll pass with no invalidation between
  requests at most 1% of the rows).
  The playlist must use the sparse group model (the default) — decorations
  intentionally do not render in the flat fallback mode for very large
  playlists (Part A scope note).
```

**Proposed:**

```text
- With the intake provider on a 5,000-row playlist holding intake rows (the
  synthetic corpus of `Tests/e2e/make_perf_corpus.sh`: 200 roots, 175 rows,
  the rest filler): smooth scroll (no frame drops from the decoration path)
  and a host cache hit ≥99% in steady state. Measured provider-side with the
  hidden `decor_stats` option against SimPlaylist v2 as it is (no SimPlaylist
  change, no Debug build): two full passes over the playlist with no
  invalidation between them (the `invalidations` figure unchanged); on pass
  2 `since invalidation` grows by at most 1% of the rows, 50 items for 5,000.
  This counts host misses because v2 requests a row only when its store has
  no entry for it.
  Result 2026-11-16 (SimPlaylist v2 428f20c, foo_jl_intake eaaca27b): pass 1
  requested each of the 5,000 rows once, pass 2 requested 0; batch time max
  363 µs, average 5 µs.
  The playlist must use the sparse group model (the default) — decorations
  intentionally do not render in the flat fallback mode for very large
  playlists (Part A scope note).
```

**Rationale:** `src/Core/IntakeDecorStats.h:5-18` (provider-side counters,
the host-miss argument, the 50-item gate), `src/Integration/IntakeDecoratorProvider.mm:109,140,162-165`
(invalidations, batch timing, the unfiltered line), `Tests/e2e/make_perf_corpus.sh:10-14,52,175`
(5,000 files, 200 roots, 175 intake rows); 04:328 says 200 intake rows. Doc
04 v1.2 has no wording that needs a Debug SimPlaylist build; the proposed
text excludes one explicitly, since SimPlaylist's debug-only counter
(3a412ee) was reverted in `6b7a9226`. The two passes of the recorded run were
driven by a temporary focus-sweep aid (`eaaca27b`, removed in `fe22ded7`); at
HEAD the passes are scrolled by hand. The result was not re-run for this CR.

### CR-EXT-002.6 — preference changes that reload (severity A)

**Doc 04 v1.2, "Refresh and invalidation", 04:167-171:**

```text
- **Reload:** an event batch (1 s debounce), the exit of a command the
  component started, a preferences change, a mount event or Refresh triggers
  one coalesced full `status --json` load, never a filtered one (doc 03 gives
  `--filter` no cost guarantee). FSEvents sees only changes made through this
  Mac (Terminal runs included); changes made on the NAS need Refresh. No polling.
```

**Proposed:**

```text
- **Reload:** an event batch (1 s debounce), the exit of a command the
  component started, a change of the CLI path, bun path or rules folder
  (with `version` first), a mount event, Refresh or the page's Reload now
  triggers one coalesced full `status --json` load, never a filtered one
  (doc 03 gives `--filter` no cost guarantee). Other preference changes
  load nothing: watched folders rebuild the watch set, the library mapping
  rebuilds the library index, colours rebuild from the last load (see
  Invalidation), the log level and the confirmations apply at once.
  FSEvents sees only changes made through this Mac (Terminal runs
  included); changes made on the NAS need Refresh. No polling.
```

And append to the Invalidation bullet as rewritten in item 3:

```text
  A CLI, bun or rules change clears the view first (one invalidate-all when
  rows were shown); a library mapping change never invalidates (library
  rows decorate nothing).
```

**Rationale:** `src/Integration/IntakeService.mm:247-275` (only `cliChanged`
reaches `reconfigure`), `src/Core/IntakeLoader.mm:741-779` (reconfigure:
cleared view at `:766`, then a load), `:782-787` (watch folders: watch set
only), `:581-589` (library mapping: index rebuilt, publish without
invalidation), `src/UI/IntakePreferencesController.mm:1337` (Reload now).

### CR-EXT-002.7 — what the watcher reacts to (severity A)

**Doc 04 v1.2, "Refresh and invalidation", 04:164-166:**

```text
- **Watch:** FSEvents on the income folders from `intake income --json` (when
  listed), the watched-folders preference and the parent of every known root,
  filtered to sidecar names (`.intake.json`, `.intake.<id>.json`).
```

**Proposed:**

```text
- **Watch:** FSEvents on the income folders from `intake income --json` (when
  listed), the watched-folders preference and the parent of every known
  root. An event counts when it is a sidecar name (`.intake.json`,
  `.intake.<id>.json`, the CLI's `isSidecarName`), a folder renamed, moved
  or removed (its roots change without a sidecar event), or an FSEvents
  rescan, dropped-events, mount or unmount flag (everything counts as
  changed); other names are ignored.
```

**Rationale:** `src/Core/IntakeWatchFilter.h:16-24` and
`src/Core/IntakeWatcher.mm:31-39,231-240` (rescan flags, directory moves,
sidecar paths); 04:166 names sidecars only.

### CR-EXT-002.8 — which window a sheet opens on (severity A)

**Doc 04 v1.2, "Context actions", 04:240-242:**

```text
  fields optional; refused roots only in `errors[]`); a sheet on the key
  window lists up to 10 "artist – album → target (n files, k shadows
  skipped)" and the excluded roots; on confirm `execute <ids> --json` runs
```

**Proposed** (replaces `a sheet on the key window`):

```text
a sheet on the window the menu was opened in (the one under the pointer
at the click; else the main, key or foobar2000 main window; else
app-modal)
```

and add, after the Context actions table notes: "The picker, Reject… and
Delete local copy… sheets pick their window the same way."

**Rationale:** `src/Integration/IntakeActions.mm:407-417` (`sheetHostWindow`:
under the pointer, then `activeSheetHost`), `:958-972` (Execute sheet,
app-modal fallback), `:1476` (window captured at the click), `:451-455`,
`:1440`, `:1563` (Reject, picker and Delete use the same choice); right-clicking
a window that is not key does not make it key, so "the key window" can be the
wrong one.
