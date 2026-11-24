# Intake 04 — SimPlaylist Decorator API & foo_jl_intake_mac

**Repo destination:** `docs/intake/intake-04-extension-spec.md`
**Owner:** extension worker · **Depends on:** doc 3 v1.2 (contract, normative), schema 1
**Status:** v1.3 — 2026-11-16 (Part A implemented and review-hardened; Part B
built and accepted in-app on the mock, user acceptance pending). v1.3 applies CR-EXT-002 (`docs/intake/CR-EXT-002-doc04.md`):
Swap, Delete local copy, row colours, confirmations, cache gate, reload
triggers, watch filter, sheet window. v1.2 (2026-11-15) aligns Part B with doc
03 v1.2 (amendment 003), the Part B plan and the S0 path probe
(`docs/intake-mac-paths.md`); Part A is unchanged.

## Part A — SimPlaylist row/group decorator provider (generic)

A new suite-level extension point so SimPlaylist stays intake-agnostic and
renders decorations from any registered provider. Lives in `shared/`.

### Service interface (as implemented in `shared/jl_decorator_api.h`, v1)

```cpp
// shared/jl_decorator_api.h (header-only; GUID is a C++17 inline variable)
class NOVTABLE jl_row_decorator_provider : public service_base {
public:
  // Batched, called off-main-thread; must be fast or answer from cache.
  // out must be resized to items.get_count(), index-aligned; default-
  // constructed entries mean "no decoration".
  virtual void decorate(metadb_handle_list_cref items,
                        pfc::list_t<jl_row_decoration> &out) = 0;
  // Group-level decoration for SimPlaylist group headers (off-main-thread).
  virtual bool decorate_group(const jl_group_key &key,
                              metadb_handle_list_cref members,
                              jl_group_decoration &out) = 0;
  // Context menu contributions for current selection (main thread).
  virtual void context_actions(metadb_handle_list_cref sel,
                               pfc::list_t<jl_context_action> &out) = 0;
  // Invoke an action returned by context_actions() (main thread).
  virtual void execute_context_action(uint32_t action_id,
                                      metadb_handle_list_cref sel) = 0;
  // Invalidation callbacks (register/unregister on main thread; providers
  // may fire from any thread and must support multiple concurrent
  // callbacks -- one per host panel instance).
  virtual void register_invalidate_callback(jl_decoration_invalidate_callback *cb) = 0;
  virtual void unregister_invalidate_callback(jl_decoration_invalidate_callback *cb) = 0;
  FB2K_MAKE_SERVICE_INTERFACE_ENTRYPOINT(jl_row_decorator_provider);
};

typedef uint32_t jl_rgba_t;  // packed 0xRRGGBBAA; 0 = none / host default

struct jl_row_decoration  { jl_rgba_t bg_tint = 0; jl_icon_id icon = jl_icon_none;
                            jl_rgba_t icon_color = 0; pfc::string8 tooltip;
                            bool strikethrough = false; bool pending = false; };
struct jl_group_decoration{ pfc::string8 badge_text; jl_rgba_t badge_color = 0;
                            jl_icon_id icon = jl_icon_none; };
struct jl_group_key       { pfc::string8 header_text;
                            metadb_handle_ptr first_member; };
struct jl_context_action  { pfc::string8 title; uint32_t action_id = 0;
                            bool enabled = true; };

class NOVTABLE jl_decoration_invalidate_callback {
public:
  // Empty list = everything from this provider changed. Any thread.
  virtual void on_decorations_invalidated(metadb_handle_list_cref affected) = 0;
};
```

Deviations from the draft v1 sketch (resolved during implementation):
- `COLORREF bg_tint` + `float tint_alpha` merged into one packed
  `jl_rgba_t` (0xRRGGBBAA); 0 means none — no Windows types on mac.
- `const char* tooltip` became owned `pfc::string8` (no lifetime issues
  across the async cache).
- `set_invalidate_cb(cb)` became a register/unregister pair: multiple
  SimPlaylist panel instances each observe invalidation.
- Added `execute_context_action()` — the sketch listed actions but had no
  invocation path.
- Added `strikethrough` (rejected-row rendering) and `pending` (provider
  will answer later; host renders undecorated and re-queries after the
  invalidate callback) to `jl_row_decoration`.
- `jl_icon_id` is a fixed generic glyph enum (circle open/left-half/
  right-half/filled, warning, cross, check, arrow); values are stable ABI,
  append-only. Hosts render them as text glyphs.

Contract clarifications (adopted after the Part A code review; normative,
mirrored in the header):
- `decorate()`/`decorate_group()` may be called **concurrently** from
  multiple threads — each host panel runs its own serial query queue.
  Providers must be thread-safe.
- `unregister_invalidate_callback()` does **not** synchronize with in-flight
  callback invocations. Hosts must keep the callback object valid after
  unregistering (SimPlaylist intentionally never frees its adapter);
  providers should stop invoking promptly but need not block on in-flight
  deliveries.
- Multi-provider merge is host-defined: first-registered-provider-wins per
  row/group, whole-decoration (no field-wise merging); enumeration order is
  unspecified. v1 targets a single active provider.
- Hosts may truncate the `decorate_group()` member list for very large
  groups (SimPlaylist passes at most the first 64; `first_member` is always
  `members[0]`).
- Struct layouts are **frozen** for v1 (they cross the dylib boundary by
  value). Extensions require `jl_row_decorator_provider_v2` with its own
  GUID and new struct types; `jl_icon_id` is the one append-only exception.

### SimPlaylist changes (implemented)
- Enumerate providers at panel init; query `decorate()` in the existing
  virtual-scroll fill path (batch = visible range + overscan of 32 rows),
  cache per handle, invalidate on provider callback or metadb change.
  Cache/index model is the pure `Core/DecorationStore` (unit-tested,
  benchmarked); SDK bridging lives in `Integration/DecorationCoordinator`.
  In-flight query batches are dropped on any invalidation (generation
  counter), so stale answers never enter the cache.
- The gutter is presence-based, not activity-based: any registered provider
  (including one that is inert, e.g. after failing its own init gate) makes
  the 16 pt gutter appear.
- Render: row background tint under selection layer; status icon in a new
  optional leading gutter column (16 pt, laid out in both the view and the
  header bar only when a provider exists); group badge appended to group
  header; tooltips via a dynamic tooltip owner; strikethrough on track text.
- Zero providers registered ⇒ zero overhead (guard before batching): the
  coordinator factory returns nil and the draw path adds only dead branches.
  Verified against the pre-change scroll-fill benchmark (see the SimPlaylist
  DEVLOG entries of 2026-07-11): post-change numbers inside the baseline
  noise band on a 5k-row playlist.
- Providers must never block: decorate()/decorate_group() run on a
  background queue and must answer from the provider's own cache or return
  "pending"; pending rows re-request after the provider's invalidate
  callback fires.
- Decorations render in the sparse group model path (the default); the flat
  fallback mode for very large playlists and the legacy node path are
  intentionally untouched in Part A.

## Part B — foo_jl_intake_mac (first provider)

### Responsibilities
Read-only view over intake state + command trigger, built to doc 03 v1.2
(schema 1) and checked against SimPlaylist v2 (`dev/simplaylist`, same API).
Reads sidecars and CLI `--json` output, mutates only through `intake`
commands, never writes files, tags, sidecars or the journal.

### State acquisition
- **Version gate:** `intake version --json` passes only when `data.schema` is
  the integer 1 (`"1"`, `1.0`, `true`, `2` or a missing value fail).
- **Feature detection** through `data.commands`, else the `cli` semver: Reject
  when `reject` is listed (fallback ≥ 0.2.0); Resume by id needs ≥ 0.2.1
  (0.2.0 ignores ids with `--resume`); income watch only when `income` is
  listed. `proposal.ranked`, `assigned_by`, `target_path` by presence. When a
  CLI before 0.3.0 omits the last two they are unknown: no "· yours" mark
  and no slot-pending gating (execute's own refusal is shown instead). The
  component does not read sidecars to fill them in.
- **Load:** one full `intake status --json` into an immutable snapshot, swapped
  in under a short lock. Rows lacking `id`, `root_path` or `status` are dropped
  and logged; unknown statuses render nothing. State follows `status`.
- **Income-folder guard:** a root whose `root_path` is an income folder
  itself (a loose audio file at the folder's top level made `scan` write
  `<income>/.intake.json`) is ignored: no members, decoration, tooltip,
  badge or menu action, so stray rows under the folder do not act on it.
  Compared with the root-matching key (normalisation, NFC, mount aliases)
  against `intake income --json`; no guard when income is not offered or
  its last call failed. One Info line per root per session.
- **Members:** virtual roots and singles (named sidecar
  `<root_path>/.intake.<id>.json`, doc 01) match only their `files[]`; other
  roots match every file under `root_path`. A named sidecar that fails to
  parse (non-atomic writes) is retried once, then the old list is kept.
- **Row paths:** `file://` is stripped by hand; `mac-volume://<UUID>/…`
  (foobar2000's form for network-share tracks) converts with
  `filesystem::g_get_native_path` inline in `decorate()`: about 1 µs, no I/O,
  thread-safe (`docs/intake-mac-paths.md`). Other schemes never match. A path
  under a network mount becomes a share-relative key (`smbfs:<share>/<rest>`)
  from `getmntinfo(MNT_NOWAIT)` (no network I/O; user and host ignored), so
  two mounts of one SMB share (`/Volumes/<share>`, `/Volumes/<share>-1`)
  match each other. CLI root paths get the same mapping, rebuilt on mount and
  unmount. Then lexical normalisation and NFC; case-sensitive.
- **Decorate path:** in-memory lookups only; no CLI call, `stat`, `realpath`
  or other share access. An unmounted share means no tint, never a hang.

### Refresh and invalidation
- **Watch:** FSEvents on the income folders from `intake income --json` (when
  listed), the watched-folders preference and the parent of every known
  root. An event counts when it is a sidecar name (`.intake.json`,
  `.intake.<id>.json`, the CLI's `isSidecarName`), a folder renamed, moved
  or removed (its roots change without a sidecar event), or an FSEvents
  rescan, dropped-events, mount or unmount flag (everything counts as
  changed); other names are ignored.
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
- **Invalidation:** per-root fingerprints (match key, members, row visual,
  group badge) are diffed; any change or the first successful load fires one
  invalidate-all, never from inside `decorate()`. A colour change rebuilds
  the visuals from the last successful load on the loader queue, with no CLI
  call, and fires one invalidate-all only when a row or badge now renders
  differently and the provider is not inert (none when no root uses the
  changed colour). The page writes a colour 0.25 s after the well's last
  change, so a drag rebuilds once.
  A CLI, bun or rules change clears the view first (one invalidate-all when
  rows were shown); a library mapping change never invalidates (library
  rows decorate nothing).

### Row decorations (status → visual)
Covers the doc 03 lifecycle (new → resolved → proposed → approved → placing
→ placed → gc_done, plus rejected). `needs_review` may accompany new,
resolved or proposed and is sticky until `approve`.

| status | tint | icon | note |
|---|---|---|---|
| new/resolved | intake blue | ○ | |
| new + needs_review | intake blue | ○ | tooltip "needs review" |
| resolved + needs_review | amber | ⚠ | tooltip "needs review" |
| proposed | teal | ◐ | |
| proposed + needs_review | amber | ◐ | tooltip "needs review"; also when user-assigned |
| approved | teal | ◑ | |
| placing (transient, during execute) | teal | → | tooltip "placing — see intake status" |
| placed, `verified: true` | green | ● | |
| placed `verified: false`, gc_done, unknown | none | none | |
| rejected | grey | ✕ | strikethrough |

- **Amber** = `needs_review` on a resolved or proposed root, with or without a
  proposal; a user-assigned proposal keeps it while the flag is set.
- **Colours** come from the `tint_*` settings; defaults blue `0x4A90D938`,
  amber `0xE5A50A38`, teal `0x2AA19838` (proposed and approved), green
  `0x3FB95038`, grey `0x80808028`. The icons that take a colour (⚠ and ◐ on
  amber, ● on placed) draw it at full opacity, except on a tint whose alpha
  is `0x99` (60%) or more, where they use the host's label colour, as every
  other icon does. A tint of 0 draws no background and leaves its icon in
  the label colour; a colour with alpha 0 draws no background but still
  colours those icons.
- **Row tooltip (B13):** every row that gets a visual has a tooltip, one
  line each (joined with `\n`; SimPlaylist shows a plain string), a line
  left out when it has nothing to say:
  1. `Intake: <Status>` (New, Resolved, Proposed, Approved, Placing,
     Placed, Rejected), plus ` · needs review` when `needs_review` is set
     on a new, resolved or proposed root. `status --json` carries only the
     flag, so no reasons are shown; reasons need a contract change (doc 03).
  2. `placing — see intake status` on placing.
  3. The target: `Target: <tier>/<collection>/<rest>` from
     `proposal.target_path`, relative to the tier root's parent (e.g.
     `music.hq/[Psytrance & Goa]/Logic Bomb/Logic Bomb [2000] Headware`). The
     collection folder is found by `target_collection` (the folder name,
     bracketed or not; also the CLI's sanitized spelling), NFC on both
     sides; when it is not in the path, the last four components. A null
     `target_path` on new, resolved, proposed or approved: on a singles
     root `Target: <collection> · slot pending`; on any other root
     `Target: none, cannot be placed (see intake status)`, whoever assigned
     it (tier `reject`, no album name: a target that can never be built).
     No `target_path` member (CLI 0.2.1): `Target: <collection>`. A resolved root with no proposal:
     `No target yet: Propose (or Assign to a collection first)`.
  4. With a proposal: `Assigned by you` (`assigned_by` user), `Assigned by
     the engine (confidence 0.91)`, or `Confidence 0.91` when `assigned_by`
     is absent.
  5. The root's last per-command error, kept until its status changes.

  A root whose status renders nothing (placed unverified, gc_done,
  unknown) gets only its last error as a tooltip-only visual, if it has
  one; the inert state keeps its single line (see Failure behavior).
- `gc_done` renders nothing: the local copy is gone, and rows swapped to
  library paths match no income root (library rows are not intake rows).

Group header badge, when every mapped member (the host passes at most 64)
belongs to one `proposed` or `approved` root:
- `→ [Collection A] · 0.91` (target + confidence); user-assigned: `· yours`
  instead of the CLI's 1.00.
- Amber on the review rule or confidence below 0.6, with the first other
  `ranked` entry as a hint in the text (API v1 has no group tooltip), e.g.
  `→ [Collection A] · 0.61 (alt: [Collection B])`; no hint without `ranked`.
  The amber badge uses the review colour at full opacity at any tint alpha
  (the group header is not tinted); `tint_review` 0 gives the host's colour.
- Null `target_path`: on a singles root `→ [Collection A] · slot pending`,
  on any other root `→ [Collection A] · cannot be placed`; amber, no hint,
  whoever assigned it. From CLI 0.3.0 compilations get a target (amendment
  003), leaving the singles slot; tier `reject`, a missing album name and
  an unconfigured tier are null for good.
- **Root kind is the only signal:** `status --json` carries no tier,
  `structure_slot` or reason for a null target. A singles root is one whose
  named sidecar (`.intake.<id>.json`, read for its `files[]` anyway) has
  `"singles": true` (doc 01); a lone root whose sidecar is not read counts
  as singles when its `cluster.album` is null (singles always have none).
  The coordinator is requesting summary fields for amendment 004
  (`target_null_reason`, `quality.*`) through the overseer; with them the
  wording can name the reason.

### Title-formatting fields (B13)
Three global fields, usable in any title-formatting script (SimPlaylist
columns and group patterns included), from a
`metadb_display_field_provider_v2` (`process_field` and `process_field_v2`
answer alike):

| field | value | no value (false, nothing written) |
|---|---|---|
| `%intake_status%` | the doc 03 status id: `new`, `resolved`, `proposed`, `approved`, `placing`, `placed`, `rejected`, `gc_done`; an unknown status: the CLI's text | never, for a row under a known root |
| `%intake_target%` | `proposal.target_path` in the tooltip's form (from the tier folder on, see Row tooltip) | no proposal, a null target, or no `target_path` member (CLI 0.2.1) |
| `%intake_collection%` | `proposal.target_collection` | no proposal or no collection |

- **Which rows:** the same root mapping as the decorations (normalisation,
  NFC, mount aliases, members, deepest root). A row outside every known
  root, any row while the provider is inert or before the first load, and
  rows of other schemes have no value, so `[%intake_target%]` collapses.
  Roots that render nothing (placed unverified, gc_done, unknown) still
  give values where their rows map, i.e. whole-directory roots; a virtual
  one matches nothing, as its member list is not read (see Members).
- **Cost:** values are computed once per root when the snapshot is built;
  `process_field` does no I/O, takes no lock, makes no foobar2000 call but
  the handle's `get_path()`, and allocates nothing for an already-normal
  ASCII path. A path with a non-ASCII byte (names stored decomposed on an
  SMB share) goes through NFC only when its ASCII folder, the part before
  the segment with the first non-ASCII byte, is under a root or an ancestor
  of one; other rows are ruled out by that folder alone (also on the
  decorate path). The three fields of one row map it once: each thread
  remembers its last row.
- **mac-volume rows:** `process_field` may not call
  `filesystem::g_get_native_path`, so a volume table stands in for it:
  seeded per mount under `/Volumes` off the main thread
  (`g_get_canonical_path("<mount>/")` gives `mac-volume://<UUID>/`,
  `g_get_native_path` of that gives the root foobar2000 resolves it to),
  re-seeded on mount, unmount and Refresh, and learned from rows the
  decorate path converted, also before a field is first used (a stale
  volume id of a share that is still mounted is known only this way, once
  one of its rows was shown; SimPlaylist does not decorate rows again when
  a field comes into use). The
  remainder after `<UUID>/` is taken raw (S0, plorg). A row of a volume id
  the table does not know has no value.
- **Refresh:** foobar2000 caches field values until
  `metadb_io::dispatch_refresh`. Nothing is refreshed until a field was
  evaluated once. After that, each published view or volume table change
  marks the roots whose key, member list or values changed (all roots on an
  alias table change, a volume change or an inert switch), and at most once
  per second the main thread reads every playlist's items once, tests them
  off the main thread and refreshes the matching handles, each once
  (SimPlaylist re-lays out, and v2 regroups, on every refresh). Every row
  whose value a host may still hold differs is refreshed, also through
  states that came and went within the second; a few more may be. No call
  when nothing matched. Debug line: `fields: refreshed N of M playlist rows
  in X ms`.
- **Limits:** items in no playlist (a library viewer, the Properties
  dialog) are not refreshed: they show new values only when their host
  formats them again. Refresh lags a change by 0.25 to 1 s plus the time
  to read and test the playlist rows (tens of milliseconds for 80k rows);
  a change that arrives while a refresh runs waits for it to finish, then
  about 1 s, then a test of its own. Field names are fixed for the
  session.
- **Considered:** a `metadb_index` client, whose
  `dispatch_refresh(index, hashes)` also reaches library items, needs a
  registered index hashed from every track's record in the database and
  stored by foobar2000; not worth it for three display fields.

### Context actions (selection mapped to sidecar roots)
A flat `jl_context_action` list (API v1: no submenus, no tooltip);
`action_id` indexes a table captured at menu time.
- **Enable rule:** doc 03 v1.2's legal source statuses, narrowed as below. An
  action is enabled when at least one selected root qualifies, runs on those
  roots only, and shows "(n of m)" on a mixed selection. Roots go by `id`; no
  mutating command is spawned with zero ids or in an all-roots form
  (`--all-resolved`, `--approved`, `--all`).
- No items without a CLI path, else **Refresh intake status** is always there.
  `scan`, `resolve` and `identify` are not offered.

| Action | Enabled on roots in | Runs |
|---|---|---|
| Propose | `resolved` | `propose <ids>` |
| Assign to X (≤ 4 alternates) | one root: `new`, `resolved`, `proposed`, `approved`; non-empty `ranked` | `assign <id> --collection X --by user`, then `propose` (see below) |
| Assign to other collection… | `new`, `resolved`, `proposed`, `approved` | picker, then `assign`, then `propose` (see below) |
| Approve | `proposed`, non-null `target_path` | `approve <ids>` |
| Reject… | `new`, `resolved`, `proposed`, `approved`; if detected | `reject <ids> [--reason]` |
| Execute placement… | `approved`, non-null `target_path` | dry run, sheet, `execute <ids>` |
| Resume placement | `placing`, CLI ≥ 0.2.1, no live run on the root | `execute <ids> --resume` |
| Swap to library paths | `placed` with `placed.verified` | playlist operation |
| Delete local copy… | `placed` with `placed.verified` | `gc <ids>` |

- **Assign, then propose:** after a successful assign (either item),
  `propose <ids>` runs in the same lane run for the roots that were
  `resolved` at menu time and that the assign did not fail; new, proposed
  and approved roots are skipped (one Debug line), and an assign that fails
  entirely (exit 2) proposes nothing. The lane is held across both calls and
  released on every path; one reload after the last call.
- **Alternates** only from `ranked` minus the target (no sidecar fallback).
  **Assign to other collection…** (first when amber) opens a picker fed by
  `intake collections --json`: a search field over a list visible from
  the start, in sections "Suggested" (the selected roots' `ranked[0]`: one
  when they agree, else up to 3 distinct; omitted when none), "Recent"
  (last 5 chosen, hidden `recent_collections` key) and "All collections".
  Typing filters live into one ranked list (substring, ignoring case,
  diacritics and `[ ]`: "folk" finds `[Folktronica & Ezo techno]`; prefix
  and word-start matches first) and highlights the first match. Arrows or a
  click highlight a row and show its name in the field; the highlighted row
  is the choice, assigned by Return or a double-click; nothing is
  highlighted when the sheet opens. Assign is enabled while a name is
  highlighted or the field holds an exact listed name; Escape cancels.
  Approve over a multi-selection is the batch.
- **Execute**, describe then confirm: `execute <ids> --dry-run --json` (rows
  `{id, root_path, target_path, dry_run, files, artifacts, skipped_shadows}`,
  fields optional; refused roots only in `errors[]`); a sheet on the window
  the menu was opened in (the one under the pointer at the click; else the
  main, key or foobar2000 main window; else app-modal) lists up to 10
  "artist – album → target (n files, k shadows skipped)" and the excluded
  roots; on confirm `execute <ids> --json` runs detached, with its output
  and a run file (pid, start time, ids) in the cache folder. Progress comes
  from FSEvents; at init a live leftover run is adopted and a dead one
  finished. Confirm first leaves out roots that changed while the sheet was
  open (no longer `approved`, another target, or a null `target_path` now:
  "slot pending" on a singles root, "cannot be placed" on any other, the
  tooltip's rule), one Error line each.
- **Execute follow-ups** (user request 2026-11-21): the sheet has two
  checkboxes, "Swap playlist rows to the library copies when done" (default
  on) and "Then delete the local copies" (enabled only while the first is
  ticked, shown unticked while disabled). Swap opens as last confirmed (the
  hidden configInt `execute_swap_after`); delete opens unticked every time
  and is never saved (user answer 2026-11-24). The choice goes into the run
  file when the run starts (`swap_after`, `delete_after`), so it applies
  when the run ends, whoever finishes it: this session, a later one that
  adopts the live run, or one that finds it ended at init (both log one
  Info line "run <stem>:
  swap/delete as chosen at its start"). A run file without the fields (an
  older build, a resume) gets no follow-ups. When the run ends: its result
  as above, then the reload that follows (one that fails stops the
  follow-ups, one Info line). **Swap:** the run's roots now `placed` with
  `placed.verified`, their rows in every playlist, through the Swap path
  below (no lane). **Delete**, when ticked, after the swap: the lane is
  taken, the Delete census counts the playlist entries still on the income
  paths of those roots (swapped rows now count as library rows), and gc runs
  for the roots that pass the gc guard (re-checked against the reloaded
  records) and whose census is clear. The ticked checkbox is the
  `confirm_gc` confirmation for exactly those roots: no second sheet, and
  nothing modal appears. A root is kept, with one Info line and a tooltip
  (as a per-root error, baseline its status then), when it fails the guard,
  still has entries on its income paths (no library copy, a locked playlist,
  a swap that did not start), or when any entry anywhere could not be
  checked (slow volume: such entries cannot be attributed to a root, so
  every root is kept). A census that cannot run (inert, no data, the lane
  busy) keeps every root. The other roots go ahead. The lane is held only
  from the census to gc's exit and released on every path; one chain runs at
  a time. A quit between the run's end and its follow-ups drops them:
  nothing is deleted, and Swap and Delete local copy… stay in the menu. The
  run file is already gone then, so the next start cannot do them either:
  the quit logs one Info line per such run, waiting for its reload, queued
  or swapping ("execute: swap after run <stem> not finished: foobar2000 quit
  first (use Swap to library paths by hand)", or "swap, then delete … (nothing
  was deleted; use Swap to library paths, then Delete local copy… by
  hand)"). A gc already started gets no line: a quit never stops it.
- **Resume** on `placing` roots runs detached like execute (never killed,
  holds the lane). A root that ends `approved` (resume reverted it) counts as
  a per-root failure.
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
  verified). `confirm_gc` 0 skips the sheet: gc at once. The Execute
  follow-up's delete (above) has no sheet either: its checkbox confirms.

- **Reject…** (with `confirm_reject` on) confirms in a sheet listing the
  albums, with a reason pop-up above the free-text field: "Already in
  library", "Lower quality than library copy", "Not wanted", "Other…". A
  preset's text is the reason (`reject --reason`, unchanged contract) and
  shows in the disabled field; "Other…" enables the field (empty: no
  reason). The first sheet of a session starts on "Already in library";
  each later one on the session's last confirmed choice (no setting; user
  answer 2026-11-24). `confirm_reject` 0 skips the sheet: no reason.

The picker, Reject… and Delete local copy… sheets pick their window the same
way.

### Status bar (B14)
A `jl_status_provider` (`shared/jl_status_api.h`; user request: "a status
bar to see the list of ongoing operations ... bottom right in
simplaylist"). It reports what the component is doing; the host draws it.
SimPlaylist (status line host, c6ab4891) shows the line as a pill at the
bottom right of the panel with the active playlist, and the list in a
popover on click. Nothing shows while idle. Without a host the provider only
keeps its line up to date.

- **The line:** the operation begun last, plus " (+N more)" while N others
  run; when nothing runs, the newest result for 10 s (from its end); else no
  line (`status_line` false). Texts are UTF-8 with "…" (U+2026); one album
  shows its label "Artist – Album" in place of the count:

  | Operation | While it runs | Result |
  |---|---|---|
  | Propose | "Proposing 3 albums…", "Proposing Artist – Album…" | "Proposed 3 albums" |
  | Assign to X, Assign to other collection… | "Assigning 3 albums…", then "Proposing 2 albums…" for the propose after it | "Assigned 3 albums", "Assigned and proposed 2 albums" |
  | Approve, Reject… | "Approving 3 albums…", "Rejecting 3 albums…" | "Approved 3 albums", "Rejected 3 albums" |
  | Execute placement… dry run | "Checking placement of 3 albums…" | "Checked placement of 3 albums" |
  | Execute (own or adopted at start) | "Placing 40 albums…", then "Placing 12/40: Artist – Album" (12 placed, that album placing now) or "Placing 12/40" | "Placed 40 albums" |
  | Resume placement | "Resuming placement of 5 albums…", then "Resuming placement 2/5" | "Resumed placement of 5 albums" |
  | Delete local copy… (`gc`, the Execute follow-up's too) | "Deleting local copies of 3 albums…" | "Deleted local copies of 3 albums" |
  | Delete local copy…'s sidecar reads (`confirm_gc` on) | "Counting playlist rows for 3 albums…" | "Counted playlist rows for 3 albums" |
  | Swap to library paths (the Execute follow-up's too) | "Swapping 12 playlist rows…" | "Swapped 12 playlist rows" |

  A failure shows "Propose failed: <reason>" (Assign, Approve, Reject
  alike), "Placement check failed: …", "Execute failed: …", "Resume failed:
  …", "Delete failed: …", "Row count failed: …" or "Swap failed: …". The
  reason is the first root's error without its "<command>: " prefix when no
  root succeeded, "<k> of <n> albums" when some did. A result carries
  state succeeded with the check icon, or failed with the cross icon, and no
  progress. Labels are cut at 60 bytes and reasons at 120, on a character
  boundary (never between a letter and its combining accent), with "…".
  Loads, Refresh, Reload now, Test CLI and the picker's `collections` are
  not shown.
- **The list** (`status_items`, read only while the popover is open):
  running entries first, begun last first, then the results still inside
  their 10 s, newest first. Title: the line's text (an n/m entry: "Placing
  12/40"). Detail: the album placing now, else "<first album> and N more",
  empty for one album; a failure's detail is its console line. Ids are
  stable while the entry exists; started and ended are Unix epoch
  milliseconds (ended 0 while running).
- **Lifetimes:** an entry begins when its operation has what it needs (the
  mutation lane, the run, the swap) and ends on every path that lets it go:
  result, refusal, timeout. A dry run that outlives its 10 s report keeps
  showing "Checking placement…" until its late answer, though the lane is
  free again (user decision Q2); a refusal or quit ends it. The sidecar
  reads end with their replies or after 10 s ("Row count failed: no answer
  within 10 s").
- **Execute progress:** not from the CLI's output (written only at exit)
  but from the statuses each published load shows: done = the run's roots
  now `placed`, the album = the root that turned `placing` since the last
  load; a root reverted to `approved` or still `placing` does not count as
  done. Resume writes no `placing`, so it shows no album. A load runs when
  FSEvents reports the CLI's sidecar rewrites (1 s debounce, at most 3 s
  after the first event; see Refresh and invalidation), so the count moves
  in steps. **SMB caveat:** FSEvents on SMB shares is untested; without its
  events the count stays 0/n until a reload (Refresh), or until the run's
  result replaces it.
- **Threading and cost:** `status_line` answers from a `jl_status_line`
  kept on the main thread, taken from the model after every change: no I/O,
  no lock, no CLI. `status_items` maps the model's few entries. The
  callbacks fire on the main thread once per model change (begin, progress,
  rename, end, expiry, quit), from a copy of the list outside its lock,
  skipping one unregistered since that round began; several callbacks at
  once, each once; unregistering an unknown one does nothing. Coalescing is
  the host's (SimPlaylist reads about 4 times a second at most). The host
  has no timer, so the provider fires when a result's 10 s run out: one
  `dispatch_after` on the main queue at the earliest expiry, re-armed on
  every change, none while no result is shown. With no host registered a
  change costs the line's update and one uncontended lock.
- **Quit:** `on_quit` empties the model and fires once, so the pill goes;
  afterwards no hook adds an entry, no timer acts, nothing fires, and the
  provider answers false and an empty list. Its state is never destroyed: a
  host may still unregister after `on_quit`.
- **Testing on the mock** (`Tests/mock-cli/README.md`): `execute.mode`
  `per-root [SECONDS] [ID...]` walks a real execute root by root (`placing`,
  a pause of 4 s, then `placed`; a listed id fails with `E_VERIFY` and goes
  back to `approved`), so the n/m and a failed result can be watched;
  `slow-dry-run [SECONDS]` answers the dry run after 15 s, past the 10 s
  report. The `perf-200` scenario has 25 `approved` roots for both. FSEvents
  sees the mock's sidecar writes when its state folder is on a local disk.

### CLI invocation
- **Executable:** the CLI path preference (a `.ts` path runs as
  `<bun> <path>`); argv array, no shell; inherited environment plus bun and
  system bin directories on `PATH` and `INTAKE_RULES_DIR` from preferences.
  No API tokens are passed in v1. Own process group, only fds 0–2 inherited.
  Read-only calls use pipes and are killed on quit; mutating calls and
  execute write output to files in `~/Library/Caches/foo_jl_intake/`.
- **Mutation lane:** single-flight for every mutating call, dry runs
  included. A real mutating call holds the lane until it exits (or the
  15-minute cap). A dry run holds it until it exits or until its 10 s
  report, whichever comes first: a dry run writes nothing, so after the
  report the lane is released, the late result is discarded (the
  confirmation says the check did not finish in 10 s; an execute dry run
  raises no `E_CLI_TIMEOUT`, per doc 03) and the process runs on, unkilled.
  Mutating actions are disabled while busy ("(execute running)"
  while an execute holds it). The CLI has no locking, so Terminal runs are
  not protected by the lane.
- **Envelope:** one object with a boolean `ok`, an `errors` array and `data`,
  matching the exit code (0 ok; 1 partial: apply `data`, report `errors`; 2
  error: `data` null). A root succeeded when its `id` is in `data`. Anything
  else is `E_NO_CLI`.

### Preferences page
CLI path (empty by default: inert; a `.ts` path runs through bun), bun path
(auto-detected), rules folder, watched income folders (added to those from
`intake income`), library prefix mapping (one pair, for Swap), log level,
row colours: six configInts `tint_new` (new, resolved), `tint_review`
(amber), `tint_proposed`, `tint_approved` (approved, placing), `tint_placed`
(placed and verified) and `tint_rejected`, each a packed sRGB `0xRRGGBBAA`
(a colour well with opacity, a "No tint" checkbox, Reset colours); 0 = no
tint, absent = the default palette, a value outside 0..0xFFFFFFFF = the
default and one Debug line, confirmations: "Ask before Delete local copy"
(`confirm_gc`) and "Ask before Reject" (`confirm_reject`), configInts, on
unless 0, default on. Off runs the command at once with no sheet (Reject
then without a reason) and drops the item's ellipsis from the next menu.
Execute placement always asks (dry run, then its sheet). A status line
(state, CLI version, root count, last error) with Test CLI and Reload now,
and the income folders in use. configStore (`foo_jl_intake.`), cached;
never read on the decorate path.

### Failure behavior
- **Codes:** CLI codes in `errors[]` are an open set, shown from `msg`/`path`
  as per-command errors (`E_BAD_ARGS`, `E_INTERNAL` included); handled
  specifically: `E_NO_RULES` (see inert), `E_NO_JOURNAL`, `E_BAD_STATUS`.
  Host-synthesised: `E_NO_CLI` (binary missing or not executable, spawn
  failure, no valid envelope) and `E_CLI_TIMEOUT`.
- **Inert** only on a failed version gate, or while no `status` load has
  succeeded and `version` or `status` fails with `E_NO_CLI`, `E_NO_RULES` or
  `E_CLI_TIMEOUT` (doc 03 "Inert state"). Rows under last-known roots or
  watched folders get a tooltip naming the error, else a console line and the
  preferences status line explain. Retried on Refresh, Reload now, a change
  of the CLI path, bun path or rules folder, an FSEvents batch or a mount
  (other preference changes load nothing, see Reload).
- **Everything else is per command:** console line + per-root tooltip; never
  modal, never inert. A failed refresh keeps the last data.
- **Timeouts** (doc 03 v1.2), classified by command whatever its flags:

  | Class | At 10 s | Kill |
  |---|---|---|
  | read-only: `version`, `status`, `collections`, `income` | report `E_CLI_TIMEOUT` | allowed (SIGTERM to the group, SIGKILL 2 s later) |
  | mutating: `propose`, `assign`, `approve`, `reject`, `gc`, dry runs included | report, keep running, reload on exit | not before the 15-minute cap; terminated at it |
  | `execute`, dry run and `--resume` included | none (doc 03 exception) | never; detached, survives quitting foobar2000 |

  A dry run that outlives its 10 s report releases the mutation lane (see
  CLI invocation).
- An inert provider still triggers SimPlaylist's 16 pt gutter (provider
  presence enables it, see Part A); accepted.

### Build/layout
New `extensions/foo_jl_intake_mac/` following suite conventions
(generate_xcode_project.rb, Scripts/build.sh, knowledge_base patterns). No
layout element of its own in v1: it exists through SimPlaylist decorations
and the context menu. (v2 idea, out of scope: a dedicated intake queue panel.)

## Acceptance (P4 gate)
- SimPlaylist with no provider: rendering benchmarks unchanged.
- With the intake provider on a 5,000-row playlist holding intake rows (the
  synthetic corpus of
  `extensions/foo_jl_intake_mac/Tests/e2e/make_perf_corpus.sh`: 200 roots,
  175 rows, the rest filler): smooth scroll (no frame drops from the
  decoration path) and a host cache hit ≥99% in steady state. Measured
  provider-side with the hidden `decor_stats` option against SimPlaylist v2
  as it is (no SimPlaylist change, no Debug build): two full passes over the
  playlist with no invalidation between them (the `invalidations` figure
  unchanged); on pass 2 `since invalidation` grows by at most 1% of the
  rows, 50 items for 5,000. This counts host misses because v2 requests a
  row only when its store has no entry for it.
  Result 2026-11-16 (SimPlaylist v2 428f20c, foo_jl_intake eaaca27b): pass 1
  requested each of the 5,000 rows once, pass 2 requested 0; batch time max
  363 µs, average 5 µs. That run's passes were driven by a temporary sweep
  aid, no longer in the build; a re-run scrolls them by hand.
  The playlist must use the sparse group model (the default) — decorations
  intentionally do not render in the flat fallback mode for very large
  playlists (Part A scope note).
- Full flow demo on synthetic fixtures only (mock CLI, or the real CLI on a
  synthetic corpus): a release lands in an income folder → rows tint →
  propose → adjust one target via picker → approve → execute → green ● →
  swap to library paths → delete local.
