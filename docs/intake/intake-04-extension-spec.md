# Intake 04 — SimPlaylist Decorator API & foo_jl_intake_mac

**Repo destination:** `docs/intake/intake-04-extension-spec.md`
**Owner:** extension worker · **Depends on:** doc 3 (contract, normative)
**Status:** draft v1 — 2026-07-11

## Part A — SimPlaylist row/group decorator provider (generic)

A new suite-level extension point so SimPlaylist stays intake-agnostic and
renders decorations from any registered provider. Lives in `shared/`.

### Service interface (sketch, ObjC++ against fb2k service pattern)

```cpp
// shared/jl_decorator_api.h
class NOVTABLE jl_row_decorator_provider : public service_base {
public:
  // Batched, called off-main-thread; must be fast or answer from cache.
  virtual void decorate(metadb_handle_list_cref items,
                        pfc::list_t<jl_row_decoration> &out) = 0;
  // Group-level decoration for SimPlaylist group headers.
  virtual bool decorate_group(const jl_group_key &key,
                              metadb_handle_list_cref members,
                              jl_group_decoration &out) = 0;
  // Context menu contributions for current selection.
  virtual void context_actions(metadb_handle_list_cref sel,
                               pfc::list_t<jl_context_action> &out) = 0;
  // Provider fires this callback to invalidate rows (async state changes).
  virtual void set_invalidate_cb(jl_invalidate_cb cb) = 0;
  FB2K_MAKE_SERVICE_INTERFACE_ENTRYPOINT(jl_row_decorator_provider);
};

struct jl_row_decoration  { COLORREF bg_tint; float tint_alpha;
                            jl_icon_id status_icon; const char* tooltip; };
struct jl_group_decoration{ pfc::string8 badge_text; COLORREF badge_color;
                            jl_icon_id icon; };
```

### SimPlaylist changes
- Enumerate providers at panel init; query `decorate()` in the existing
  virtual-scroll fill path (batch = visible range + overscan), cache per
  handle, invalidate on provider callback or metadb change.
- Render: row background tint under selection layer; status icon in a new
  optional leading gutter column; group badge appended to group header.
- Zero providers registered ⇒ zero overhead (guard before batching).
- Providers must never block: SimPlaylist enforces a soft budget (answer from
  cache or return "pending"; pending rows re-request on invalidate).

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
| status | tint | icon |
|---|---|---|
| new/resolved | intake blue | ○ |
| resolved + needs_review | amber | ⚠ |
| proposed | teal | ◐ |
| approved | teal | ◑ |
| placed (verified) | green | ● |
| rejected | grey strike | ✕ |

Group header badge: `→ [Psychill & Chillout & Psydub] · 0.91` (target +
confidence); low-confidence renders amber with alternates hint.

### Context actions (selection mapped to sidecar roots)
- **Propose** → `intake propose <roots>`
- **Assign to…** → submenu from `intake collections --json`
  (+ ranked alternates from the sidecar pinned on top) →
  `intake assign --collection X --by user`
- **Approve** / **Approve batch** → `intake approve`
- **Execute (copy to library)** → `intake execute` (confirmation sheet
  summarizing targets — describe-then-confirm in UI)
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
- Full flow demo: slsk dump lands → rows tint → propose → adjust one target
  via picker → approve → execute → green ● → swap to library paths →
  delete local.
