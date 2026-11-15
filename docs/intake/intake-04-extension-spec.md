# Intake 04 — SimPlaylist Decorator API & foo_jl_intake_mac

**Repo destination:** `docs/intake/intake-04-extension-spec.md`
**Owner:** extension worker · **Depends on:** doc 3 v1.2 (contract, normative), schema 1
**Status:** v1.2 — 2026-11-15 (Part A implemented and review-hardened; Part B in
implementation). v1.2 aligns Part B with doc 03 v1.2 (amendment 003), the Part B
plan and the S0 path probe (`docs/intake-mac-paths.md`); Part A is unchanged.

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
  listed), the watched-folders preference and the parent of every known root,
  filtered to sidecar names (`.intake.json`, `.intake.<id>.json`).
- **Reload:** an event batch (1 s debounce), the exit of a command the
  component started, a preferences change, a mount event or Refresh triggers
  one coalesced full `status --json` load, never a filtered one (doc 03 gives
  `--filter` no cost guarantee). FSEvents sees only changes made through this
  Mac (Terminal runs included); changes made on the NAS need Refresh. No polling.
- **Invalidation:** per-root visual fingerprints are diffed; any change, the
  first successful load or a colour/config change fires one invalidate-all,
  never from inside `decorate()`.

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
- A null `proposal.target_path` adds the tooltip "slot pending"; a
  per-command error adds the root's last error until its status changes.
- `gc_done` renders nothing: the local copy is gone, and rows swapped to
  library paths match no income root (library rows are not intake rows).

Group header badge, when every mapped member (the host passes at most 64)
belongs to one `proposed` or `approved` root:
- `→ [Collection A] · 0.91` (target + confidence); user-assigned: `· yours`
  instead of the CLI's 1.00.
- Amber on the review rule or confidence below 0.6, with the first other
  `ranked` entry as a hint in the text (API v1 has no group tooltip), e.g.
  `→ [Collection A] · 0.61 (alt: [Collection B])`; no hint without `ranked`.
- Null `target_path`: `→ [Collection A] · slot pending`, amber. From CLI
  0.3.0 compilations get a target (amendment 003), leaving the singles slot;
  tier `reject` is also null, and its wording is not specified.

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
| Assign to X (≤ 4 alternates) | one root: `new`, `resolved`, `proposed`, `approved`; non-empty `ranked` | `assign <id> --collection X --by user` |
| Assign to other collection… | `new`, `resolved`, `proposed`, `approved` | picker, then `assign` |
| Approve | `proposed`, non-null `target_path` | `approve <ids>` |
| Reject… | `new`, `resolved`, `proposed`, `approved`; if detected | `reject <ids> [--reason]` |
| Execute placement… | `approved`, non-null `target_path` | dry run, sheet, `execute <ids>` |
| Resume placement | `placing`, CLI ≥ 0.2.1, no live run on the root | `execute <ids> --resume` |
| Swap to library paths | `placed` with `placed.verified` | playlist operation |
| Delete local copy… | `placed` with `placed.verified` | `gc <ids>` |

- **Alternates** only from `ranked` minus the target (no sidecar fallback).
  **Assign to other collection…** (first when amber) opens a picker fed by
  `intake collections --json`. Approve over a multi-selection is the batch.
- **Execute**, describe then confirm: `execute <ids> --dry-run --json` (rows
  `{id, root_path, target_path, dry_run, files, artifacts, skipped_shadows}`,
  fields optional; refused roots only in `errors[]`); a sheet on the key
  window lists up to 10 "artist – album → target (n files, k shadows
  skipped)" and the excluded roots; on confirm `execute <ids> --json` runs
  detached, with its output and a run file (pid, start time, ids) in the
  cache folder. Progress comes from FSEvents; at init a live leftover run is
  adopted and a dead one finished.
- **Resume** on `placing` roots runs detached like execute (never killed,
  holds the lane). A root that ends `approved` (resume reverted it) counts as
  a per-root failure.
- **Swap to library paths** (files untouched): prefix mapping
  (`<nas-prefix>` → `/Volumes/<share>`) on `placed.target_path` plus the
  file's path relative to the root (doc 03 layout); only files that exist in
  the library, shadows untouched. Paths go through
  `filesystem::g_get_canonical_path` on the mount point whose canonical form
  matches the playlist's items, so no duplicate metadb entries; no match:
  skip and log.
- **Delete local copy** → `gc <ids>`: never `rejected`, never a root that is
  not `placed`, never `gc --all` (permanent guard). The confirmation lists the
  local paths and offers **Swap, then delete** while rows still point at
  income paths. A library index (library path → root) covers swapped rows.

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
`intake income`), library prefix mapping (one pair, for Swap), tint colours
(new, review, proposed, approved, placed, rejected; sRGB `0xRRGGBBAA`),
confirmation toggles (Delete, Reject; Execute always asks), log level. A
status line (state, CLI version, root count, last error) with Test CLI and
Reload now, and the income folders in use. configStore (`foo_jl_intake.`),
cached; never read on the decorate path.

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
  preferences status line explain. Retried on Refresh, preferences change,
  FSEvents batch or mount.
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
- With intake provider on a 5k-row playlist incl. 200 intake rows: smooth
  scroll (no frame drops from decoration path; cache hit ≥99% steady-state,
  measured provider-side: a second scroll pass with no invalidation between
  requests at most 1% of the rows).
  The playlist must use the sparse group model (the default) — decorations
  intentionally do not render in the flat fallback mode for very large
  playlists (Part A scope note).
- Full flow demo on synthetic fixtures only (mock CLI, or the real CLI on a
  synthetic corpus): a release lands in an income folder → rows tint →
  propose → adjust one target via picker → approve → execute → green ● →
  swap to library paths → delete local.
