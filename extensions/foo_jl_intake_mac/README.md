# foo_jl_intake

> Part of [foobar2000 macOS Components Suite](../../README.md)

**[Changelog](CHANGELOG.md)**

---

Shows music intake status on SimPlaylist rows and runs intake steps from
the context menu. New releases in your income folders can be reviewed,
assigned, approved, placed into the library and cleaned up without leaving
foobar2000.

The component has no layout element. It registers a row decorator provider
(`jl_row_decorator_provider`, `shared/jl_decorator_api.h`), and SimPlaylist
draws what it returns. SimPlaylist itself knows nothing about intake.

**Privacy and safety:** the component reads the intake sidecars
(`.intake.json`, `.intake.<id>.json`) and the CLI's JSON output. It changes
music files and sidecars only through the intake command-line tool. Swap
to library paths edits playlist entries, not files.

## Requirements

- foobar2000 for macOS, on macOS 12 or later.
- A SimPlaylist build that hosts row decorators (doc 04 Part A). Without
  it the component loads but shows no tints and adds no menu items.
- The intake command-line tool, answering `version --json` with
  `"schema": 1`. The component is written against CLI 0.3.0 and detects
  newer features by command. For example, Resume placement needs 0.2.1 or
  later, and the income folder list needs a CLI that offers `income`.
- bun, when the CLI path is the CLI's `cli.ts`.

## Setup

Open **Tools > Intake** in foobar2000's preferences. Every change applies
at once; nothing needs a restart.

| Field | What it does |
|---|---|
| CLI path | The intake CLI: an executable, or its `cli.ts` (run through bun). Empty: nothing runs and no row is tinted. |
| bun | The bun to run a `cli.ts` with. Empty: found in `~/.bun/bin`, `/opt/homebrew/bin` or `/usr/local/bin`. |
| Rules folder | Passed to the CLI as `INTAKE_RULES_DIR`. Empty: the CLI's own rules setting. |
| Watched folders | Extra folders to watch for sidecar changes, one absolute path per line. The income folders and the folders of known releases are always watched. |
| Library mapping | One prefix pair, NAS path prefix to Mac path prefix, for Swap to library paths when the CLI reports library paths as the NAS sees them. |
| Row colours | One colour per status, with opacity, a "No tint" switch for each, and Reset colours. |
| Confirmations | Ask before Delete local copy, Ask before Reject (both on by default). Execute placement always asks. |
| Log level | Error, Info or Debug. Lines appear in View > Console with an `[intake]` prefix. |

The Status block shows the state, the CLI version, the number of releases
and the last error. **Test CLI** runs `intake version`, and **Reload now**
reloads everything. The Income folders table lists the folders the CLI
reports, or the folders that hold the loaded releases.

## What the rows show

Rows are matched to intake releases (roots) by their file path.

| Status | Tint (default) | Icon | Notes |
|---|---|---|---|
| new, resolved | blue | ○ | |
| new with needs review | blue | ○ | tooltip "needs review" |
| resolved with needs review | amber | ⚠ | tooltip "needs review" |
| proposed | teal | ◐ | |
| proposed with needs review | amber | ◐ | tooltip "needs review", also after your own Assign |
| approved | teal | ◑ | |
| placing (during Execute) | teal | → | tooltip "placing — see intake status" |
| placed and verified | green | ● | |
| placed unverified, gc_done | none | none | the local copy is gone or unconfirmed |
| rejected | grey | ✕ | struck through |

- A proposal without a target slot adds the tooltip "slot pending".
- A failed command adds its error to the release's tooltip until the
  release's status changes.
- While intake is inactive (the CLI cannot run, or it reports an
  unsupported schema), rows of the last known releases show a tooltip
  naming the reason.
- **Group header badge.** When every row of a group belongs to one
  proposed or approved release, the header shows the target and the
  confidence, e.g. `→ [Collection A] · 0.91`, or `· yours` after your own
  Assign. The badge is amber when the release needs review or the
  confidence is below 0.6, with the next candidate as a hint:
  `→ [Collection A] · 0.61 (alt: [Collection B])`.

## Context menu

Select rows and right-click. An item runs on the selected releases that
qualify. "(2 of 3)" in a title means it runs on only some of them.

| Item | Runs | Enabled on |
|---|---|---|
| Propose | `propose` | resolved |
| Assign to *X* | `assign --collection X --by user` | one release that has other candidates (up to 4 shown) |
| Assign to other collection… | `collections`, then `assign` with the collection picked | new, resolved, proposed, approved |
| Approve | `approve` | proposed with a target |
| Reject… | `reject`, with an optional reason | new, resolved, proposed, approved |
| Execute placement… | `execute --dry-run`, then a sheet, then `execute` in the background | approved with a target |
| Resume placement | `execute --resume` in the background | placing, when no run is going on it |
| Swap to library paths | no CLI call: points the playlist rows at the library copies | placed and verified |
| Delete local copy… | `gc` | placed and verified |
| Refresh intake status | a full reload | always |

- An ellipsis means a dialog comes first. Reject and Delete local copy
  lose it when their confirmation is turned off.
- Only one command runs at a time. While one runs, the other command items
  are disabled; during an Execute their titles say "(execute running)".
  Swap to library paths and Refresh stay available.
- An Execute keeps running when foobar2000 quits. The next start picks it
  up again.

How commands are run, timed out and watched is described in
[`docs/runtime-notes.md`](docs/runtime-notes.md). The settings, including
the ones not on the preferences page, are in
[`docs/hidden-options.md`](docs/hidden-options.md).

## Building from Source

From this folder:

```bash
./Scripts/build.sh                # Release build; runs the unit tests first
./Scripts/build.sh --regenerate   # after adding or removing source files
./Scripts/build.sh --install      # build and install into foobar2000
./Scripts/run_tests.sh            # Core unit tests only (ASan and UBSan)
```

Never call `xcodebuild` directly: it builds into DerivedData, and
`--install` would then copy a stale binary.

## Documentation

- `docs/intake/intake-04-extension-spec.md`: this component's spec.
- `docs/intake/intake-03-contract-spec.md`: the CLI and component contract.
- `knowledge_base/14_INTAKE_SYSTEM_OVERVIEW.md`: the system map.
- [`docs/intake-mac-paths.md`](../../docs/intake-mac-paths.md): how
  foobar2000 stores paths on network shares.

## License

MIT.
