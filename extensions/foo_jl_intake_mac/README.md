# foo_jl_intake

foobar2000 macOS component for the music intake pipeline: review and approve
incoming releases without leaving SimPlaylist.

It is the first consumer of the suite's generic row decorator extension point
(`shared/jl_decorator_api.h`) — it registers a `jl_row_decorator_provider` and
SimPlaylist renders whatever it returns. SimPlaylist itself stays
intake-agnostic.

## Status: scaffold

The component builds, registers, and honours the decorator API contract, but
it has **no state source yet**, so it renders nothing. Installing it currently
adds an empty 16 pt gutter to SimPlaylist and nothing else — the gutter keys
off provider *presence*, not activity (intake doc 04, Part A). There is no
reason to install it yet.

What exists:

- `src/Core/IntakeRootIndex` — maps playlist file paths to intake sidecar
  roots (longest-match, path-boundary-safe). Pure Foundation, unit-tested.
- `src/Integration/IntakeDecoratorProvider.mm` — the provider service:
  thread-safe, non-blocking, multi-callback, answering "no decoration".
- `src/Integration/Main.mm` — component registration.

What is deliberately absent, and why:

| Missing | Blocked on |
|---|---|
| `intake status --json` parsing | CR-002.1 — is the payload enveloped or a bare array? |
| `intake version` gate | CR-002.3 — which schema value does it compare against? |
| "Assign to \<alternates\>" menu | CR-002.2 — `proposal.ranked` is not in the status summary |
| Error-state rendering | CR-002.4 — which codes are host-synthesized |

See `docs/intake/CHANGE-REQUESTS.md`. Building a parser against a guess would
be rework, so the scaffold stops at that boundary rather than guessing.

## Design constraints

- **Reads state, mutates nothing.** Every mutation goes through an `intake`
  CLI command (contract: `docs/intake/intake-03-contract-spec.md`). The
  component never writes sidecars, tags, or the journal.
- **Never block the decorate path.** `decorate()` / `decorate_group()` run off
  the main thread, may run concurrently across panels, and must answer from
  cache or return `pending`. No subprocess, no I/O.
- **No personal data in this repo.** Fixtures are synthetic; real maps and
  paths live in the private rules repo via `INTAKE_RULES_DIR`.

## Building

```bash
./Scripts/build.sh --install          # Release
./Scripts/build.sh --regenerate       # after adding/removing source files
./Scripts/run_tests.sh                # Core unit tests (ASan+UBSan)
```

Never call `xcodebuild` directly — it writes to DerivedData and `--install`
then copies a stale binary.

**Known issue (repo-wide, not specific to this component):** `--debug` fails
to link with `Undefined symbols: pfc::myassert`. The generated project points
its library search paths at the SDK's `build/Release` directories in every
configuration, so Debug objects (assertions enabled) link against
Release-built SDK libraries that compiled them out. Debug-built SDK libraries
do exist alongside them. Release builds are unaffected.

## Documentation

- `docs/intake/intake-04-extension-spec.md` — this component's spec
- `docs/intake/intake-03-contract-spec.md` — CLI ⇄ component contract
- `knowledge_base/14_INTAKE_SYSTEM_OVERVIEW.md` — system map

## License

MIT.
