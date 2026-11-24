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
| new with needs review | blue | ○ | "needs review" in the tooltip |
| resolved with needs review | amber | ⚠ | "needs review" in the tooltip |
| proposed | teal | ◐ | |
| proposed with needs review | amber | ◐ | "needs review" in the tooltip, also after your own Assign |
| approved | teal | ◑ | |
| placing (during Execute) | teal | → | "placing — see intake status" in the tooltip |
| placed and verified | green | ● | |
| placed unverified, gc_done | none | none | the local copy is gone or unconfirmed |
| rejected | grey | ✕ | struck through |

- **Row tooltip.** Hovering a tinted row shows, one line each: the status
  (`Intake: Proposed · needs review`), the target folder from the tier on
  (`Target: music.hq/[Collection A]/Artist/Release`), or for a single
  waiting for its slot `Target: [Collection A] · slot pending`, or for a
  release that can never be placed (for example graded tier reject)
  `Target: none, cannot be placed (see intake status)`, or, for a resolved
  release with no proposal, `No target yet: Propose (or Assign to a
  collection first)`;
  then who assigned it (`Assigned by you`, `Assigned by the engine
  (confidence 0.91)`). The CLI reports only that a release needs review,
  not why.
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

## Title-formatting fields

Three fields for any title-formatting script, such as a SimPlaylist column
or group pattern. A row gets the values of the release it belongs to,
matched as for the tints.

| Field | Value |
|---|---|
| `%intake_status%` | The status: `new`, `resolved`, `proposed`, `approved`, `placing`, `placed`, `rejected` or `gc_done`. |
| `%intake_target%` | The target folder from the tier on, as in the tooltip. |
| `%intake_collection%` | The target collection. |

- A row with no value gets nothing, so `[%intake_target%]` collapses: rows
  outside every release, every row while intake is inactive or before the
  first load, and a release without a target or collection.
- Rows on a network share need a volume foobar2000 resolves. An older
  volume id of a share that is still mounted gets values once SimPlaylist
  has shown one of its rows.
- When a value changes, playlist rows are updated within about a second.
  Items in no playlist (a library viewer, the Properties dialog) keep the
  old value until their viewer formats them again for another reason.

Details are in the spec,
[`docs/intake/intake-04-extension-spec.md`](../../docs/intake/intake-04-extension-spec.md).

## Context menu

Select rows and right-click. An item runs on the selected releases that
qualify. "(2 of 3)" in a title means it runs on only some of them.

| Item | Runs | Enabled on |
|---|---|---|
| Propose | `propose` | resolved |
| Assign to *X* | `assign --collection X --by user` | one release that has other candidates (up to 4 shown) |
| Assign to other collection… | `collections`, then `assign` with the collection picked | new, resolved, proposed, approved |
| Approve | `approve` | proposed with a target |
| Reject… | `reject`, with a reason picked from presets (Already in library, Lower quality than library copy, Not wanted) or typed under Other… | new, resolved, proposed, approved |
| Execute placement… | `execute --dry-run`, then a sheet, then `execute` in the background; when it ends, Swap to library paths and, if ticked in the sheet, `gc` | approved with a target |
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
  up again, with the swap and delete chosen in its sheet.

How commands are run, timed out and watched is described in
[`docs/runtime-notes.md`](docs/runtime-notes.md). The settings, including
the ones not on the preferences page, are in
[`docs/hidden-options.md`](docs/hidden-options.md).

## Status bar

While a command runs, SimPlaylist shows a line at the bottom right of the
panel with the active playlist, for example "Proposing 3 albums…" or
"Placing 12/40: Artist – Album". When it ends, the result stays for 10
seconds ("Proposed 3 albums", "Execute failed: 1 of 5 albums"), then the
line goes. Nothing shows while intake is idle. Click the line for the list
of running commands and those that ended in the last 10 seconds.

- Shown: Propose, Assign, Approve, Reject, Execute (its check, the
  placement, and a placement picked up at start), Resume, Delete local copy
  (and its file list reads), and Swap to library paths. Loads and Refresh
  are not.
- A command that failed for some albums shows as failed ("Assign failed: 1
  of 3 albums"), also when the propose after an assign succeeded. A
  placement check that never answers (a share that stopped responding)
  leaves the line after 15 minutes as "Placement check failed: no answer
  within 15 min".
- The placement count moves when a load sees the sidecars change, in steps
  of a few seconds. On a network share without file events (SMB is
  untested) it stays at 0/40 until you refresh or the placement ends.
- Needs a SimPlaylist build that hosts status lines (`jl_status_provider`,
  `shared/jl_status_api.h`). Older builds show no line; everything else
  works as before.

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
