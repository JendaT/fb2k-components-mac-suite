# Intake 04 — SimPlaylist Decorator API & foo_jl_intake_mac

**Repo destination:** `docs/intake/intake-04-extension-spec.md`
**Owner:** extension worker · **Depends on:** doc 3 (contract, normative)
**Status:** v1.1 — 2026-07-16 (Part A implemented and review-hardened; Part B draft)

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
Read-only view over intake state + command trigger. All mutations via
`intake` CLI per doc 3. Never touches files/tags/sidecars directly.

### State acquisition
- On init: `intake version` gate, then `intake status --json` full load into
  an in-memory index keyed by root path and by member file path.
- FSEvents watch on income roots (from status results) for `.intake.json`
  mtime changes → partial reload → invalidate affected rows.
- After every triggered command: targeted `intake status --json --filter`.

### Row decorations (status → visual)
Covers the full doc 3 lifecycle (new → resolved → proposed → approved →
placing → placed → gc_done, plus rejected; needs_review may accompany
resolved/proposed):

| status | tint | icon |
|---|---|---|
| new/resolved | intake blue | ○ |
| resolved + needs_review | amber | ⚠ |
| proposed | teal | ◐ |
| proposed + needs_review | amber | ◐ |
| approved | teal | ◑ |
| placing (transient, during execute) | teal | → |
| placed (verified) | green | ● |
| gc_done | none | none |
| rejected | grey strike | ✕ |

`placing` rows carry a tooltip with the execute progress source ("placing —
see intake status"). `gc_done` renders no decoration: the local copy is gone,
and rows swapped to library paths no longer match any income sidecar root
(which is the desired end state — library rows are not intake rows).

Group header badge: `→ [Psychill & Chillout & Psydub] · 0.91` (target +
confidence). Low-confidence renders amber with the alternates hint carried
in the badge text itself (e.g. `→ [Psychill] · 0.61 (alt: Psydub)`) —
`jl_group_decoration` has no tooltip field in API v1.

### Context actions (selection mapped to sidecar roots)
`jl_context_action` is a flat list in API v1 — no submenus. Menu structure
below is expressed within that constraint:
- **Propose** → `intake propose <roots>`
- **Assign to <top alternates>** — the top ranked alternates from the
  sidecar as individual flat actions (max 4), plus **Assign to other
  collection…** which opens a provider-owned picker window fed by
  `intake collections --json`. Either path → `intake assign --collection X
  --by user`. (True submenus, if ever wanted, arrive via provider_v2.)
- **Approve** / **Approve batch** → `intake approve`
- **Execute (copy to library)** → `intake execute` (confirmation sheet
  summarizing targets — describe-then-confirm in UI; the API passes no
  window context, so the provider presents against the application's key
  window; execute_context_action runs on the main thread)
- **Delete local copy** → `intake gc <root>`; enabled **only** when
  journal-verified `placed` (per doc 3 §execute step 6)
- **Swap to library paths** → replace selected playlist entries' paths with
  `placed.target_path` equivalents (playlist survives local deletion). Pure
  playlist operation via fb2k API; files untouched.

### Preferences page
intake CLI path (default `tools` install location), income-root display,
tint colors, confirmation toggles, log verbosity.

### Failure behavior
Per doc 3 error codes: render inert (no tint, tooltip explains), log to
console, never modal-interrupt playback. CLI timeout budget 10s per command
(execute excepted: runs detached, progress via status polling of `placing`).
Note: an inert provider still triggers SimPlaylist's 16 pt gutter (provider
presence is what enables it — see Part A); acceptable, since the gutter is
the natural place for the "intake unavailable" tooltip.

### Build/layout
New `extensions/foo_jl_intake_mac/` following suite conventions
(generate_xcode_project.rb, Scripts/build.sh, knowledge_base patterns).
No layout element of its own in v1 — it exists through SimPlaylist
decorations + context menu. (v2 idea, out of scope: dedicated intake queue
panel reusing SimPlaylist rendering.)

## Acceptance (P4 gate)
- SimPlaylist with no provider: rendering benchmarks unchanged.
- With intake provider on a 5k-row playlist incl. 200 intake rows: smooth
  scroll (no frame drops from decoration path; cache hit ≥99% steady-state).
  The playlist must use the sparse group model (the default) — decorations
  intentionally do not render in the flat fallback mode for very large
  playlists (Part A scope note).
- Full flow demo: slsk dump lands → rows tint → propose → adjust one target
  via picker → approve → execute → green ● → swap to library paths →
  delete local.
