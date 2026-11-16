# Settings and hidden options (config store)

foo_jl_intake keeps its settings in foobar2000 v2's config store, a SQLite
database:

```
~/Library/foobar2000-v2/config.sqlite
```

Strings live in the `configStrings` table and integers in `configInts`. Every
key starts with `foo_jl_intake.`, so this lists them all:

```bash
sqlite3 ~/Library/foobar2000-v2/config.sqlite \
  "SELECT name,value FROM configStrings WHERE name LIKE 'foo_jl_intake.%'
   UNION ALL
   SELECT name,value FROM configInts WHERE name LIKE 'foo_jl_intake.%';"
```

A key with no row uses its default.

**Quit foobar2000 before editing.** It keeps the configuration in memory and
writes it back when it quits, so an edit made while it runs is overwritten.
The component reads every key at startup.

**On the preferences page (Tools > Intake, B5):** `cli_path`, `bun_path`,
`rules_dir`, `watch_folders`, `swap_prefix_from`, `swap_prefix_to`,
the row colours `tint_new`, `tint_review`, `tint_proposed`, `tint_approved`,
`tint_placed` and `tint_rejected` (B10), `confirm_gc` (B9, on the page since
B10), `confirm_reject` (B6) and `log_level`. These are no longer hidden: the
page writes them and they apply at once, with no restart (a CLI, bun or rules
change reloads with `version`; a watched-folders change rebuilds the watch
set; a colour change rebuilds the rows' decorations from the last load, with
at most one invalidate-all and no CLI call; the log level and the two
confirmations apply immediately, from the next context menu). They are
described below because in-app checks set them with `sqlite3` while
foobar2000 is quit.

**Hidden (config store only):** `decor_stats`, `log_file` and the temporary
acceptance aids `test_playlist`, `test_playlist_dir`, `test_open_prefs` and
`test_actions`.

# Keys on the preferences page

## foo_jl_intake.cli_path

`configStrings`. The absolute path of the intake CLI. A path ending in `.ts`
runs through bun (`bun_path`). Default: empty.

While it is empty the component is **not configured**. It starts no process,
writes one console line (`[intake] not configured: ...`, at `log_level` 1 or
higher) and decorates no row. This is not an error state.

```bash
# quit foobar2000 first
sqlite3 ~/Library/foobar2000-v2/config.sqlite \
  "INSERT INTO configStrings(name,value) VALUES('foo_jl_intake.cli_path','/absolute/path/to/intake')
   ON CONFLICT(name) DO UPDATE SET value=excluded.value;"
```

## foo_jl_intake.bun_path

`configStrings`. The bun executable for a `.ts` CLI. Default: empty, which
means bun is looked for in `~/.bun/bin`, `/opt/homebrew/bin` and
`/usr/local/bin`.

## foo_jl_intake.rules_dir

`configStrings`. Passed to the CLI as `INTAKE_RULES_DIR`. Default: empty, which
leaves an inherited `INTAKE_RULES_DIR` alone. Without either variable the CLI
falls back to its own `config.toml`. At log level 2 the console names the
source in use (`[intake] load: rules from ...`).

## foo_jl_intake.log_level

`configInts`. `0` errors only, `1` also information (default), `2` also debug.
Debug lines show each CLI call's arguments, how it ended (outcome, exit code,
duration, error codes) and the member-list I/O. They never show the CLI's
output. The `decor_stats` lines ignore this setting.

## foo_jl_intake.watch_folders

`configStrings`. Extra folders to watch for sidecar changes, one absolute path
per line (newline-separated; blank lines skipped, surrounding spaces trimmed,
a line that does not start with `/` is ignored with one console line).
Default: empty.

The component always watches the income folders that `intake income --json`
lists (CLI 0.3.0 and later) and the parent folder of every known root; this
key adds to them. Watching is FSEvents, recursive, with no polling. A change
to a sidecar (`.intake.json`, `.intake.<id>.json`), or a folder renamed,
moved or trashed under a watched folder, made through this Mac, Terminal
runs included, reloads the colours about 2 s later. A watch stream starts
from the moment of the last `status` call: macOS replays what changed in
between, so a change made just before the stream started still reloads,
and a start with nothing to replay costs no reload (on a network share
macOS may keep nothing to replay). Changes made on the NAS itself are not
reported by macOS and need Refresh (B6) or a mount event.

```bash
# quit foobar2000 first; the value may hold several lines
sqlite3 ~/Library/foobar2000-v2/config.sqlite \
  "INSERT INTO configStrings(name,value) VALUES('foo_jl_intake.watch_folders','/abs/folder/one' || char(10) || '/abs/folder/two')
   ON CONFLICT(name) DO UPDATE SET value=excluded.value;"
```

At `log_level` 1 the console shows `[intake] watching N folder(s) for sidecar
changes` whenever the watch set changes; at 2 also the folders (`watch: ...`)
and one line per change batch (`watch: changes in N folder(s) ...`).

## foo_jl_intake.swap_prefix_from and swap_prefix_to

`configStrings`. The library mapping for "Swap to library paths" (B9): one
prefix pair, the library's path prefix as the intake CLI reports it on the
NAS (`swap_prefix_from`) and the same folder as this Mac mounts it
(`swap_prefix_to`), e.g. `/share/library` and `/Volumes/library`. Both must be
absolute paths, or both empty (the default: no mapping). The page flags a
half-filled or relative pair.

How it is used: a placed file's library path is `placed.target_path` + `/` +
its sidecar `files[].path`; when that path is `swap_prefix_from` or lies under
it (whole path components: `/share/library` does not match
`/share/library2`), that part is replaced by `swap_prefix_to`. A pair that is
empty or not usable maps nothing, and a target path outside a usable pair is
used as it is (the CLI may already report Mac paths); either way only library
files that exist are swapped. The same rule builds the library index that lets
**Delete local copy…** find rows already swapped. A change applies at once:
the index is rebuilt (no reload), and the next Swap uses the new pair.

## foo_jl_intake.tint_new, tint_review, tint_proposed, tint_approved, tint_placed, tint_rejected

`configInts`. The row colours, each a packed sRGB `0xRRGGBBAA` (red, green,
blue, alpha; the format SimPlaylist draws decoration colours in). The page's
Row colours section: one colour well per status, a "No tint" checkbox
beside each, and Reset colours (which deletes the six rows).

| Key | Rows | Default |
|---|---|---|
| `tint_new` | new and resolved roots (intake blue) | `0x4A90D938` |
| `tint_review` | resolved or proposed roots that need review (amber), and the amber group badge | `0xE5A50A38` |
| `tint_proposed` | proposed (teal) | `0x2AA19838` |
| `tint_approved` | approved and placing (teal) | `0x2AA19838` |
| `tint_placed` | placed with `placed.verified` (green) | `0x3FB95038` |
| `tint_rejected` | rejected (grey) | `0x80808028` |

A key with no row uses its default. `0` means no tint for that status: the
row keeps its normal background, an icon that takes the tint's colour (the
review warning and half circle, the placed filled circle) uses the label
colour instead, and with `tint_review` 0 the amber group badge uses
SimPlaylist's normal header text colour; icons and tooltips stay.
The icons that take a colour use it at full alpha. An alpha of `00` with a
colour (`0xRRGGBB00`) draws no background but keeps the icon colour. A
value that is negative or wider than 32 bits is malformed: the default is
used, and one Debug line names it (`[intake] tint_placed: -5 is not 0 or a
0xRRGGBBAA colour; using the default 0x3FB95038`). At `log_level` 2 the
component also logs the colours that differ from the defaults when it
starts and after each change (nothing when all are default):
`[intake] row colours: placed 0xFF00FFFF; the rest default`.

The values are read at startup and whenever the page saves a setting, and
kept in memory; the decorate path never reads them. SQLite takes a hex
literal for the integer:

```bash
# quit foobar2000 first
sqlite3 ~/Library/foobar2000-v2/config.sqlite \
  "INSERT INTO configInts(name,value) VALUES('foo_jl_intake.tint_placed',0xFF00FFFF)
   ON CONFLICT(name) DO UPDATE SET value=excluded.value;"
# read them back as hex
sqlite3 ~/Library/foobar2000-v2/config.sqlite \
  "SELECT name, printf('0x%08X', value) FROM configInts WHERE name LIKE 'foo_jl_intake.tint_%';"
```

## foo_jl_intake.confirm_gc

`configInts`, `1` (default) or `0`. The page's "Ask before Delete local
copy" checkbox (Confirmations). With `1`, the
context menu's **Delete local copy…** first shows a confirmation (a sheet on
the window the menu was opened in) that lists the local files it deletes (the
sidecar's `files[]` under `root_path`, shadows included: up to 10, then "and
N more"), notes that a whole-folder root's other files go too, and offers
**Swap, then delete** while rows of those releases in any playlist still
point at their income files and Swap can move every one of them (rows that
play a quality shadow or a file the sidecar does not list have no library
copy: they are named instead, and the button is not offered). "Swap, then
delete" swaps them in the playlist the menu was opened in, then in every
other playlist, and runs gc only when no row anywhere still points at an
income file (a row on a slow volume that could not be checked also stops
it). With `0`, the item reads **Delete local copy** (no ellipsis) and runs
`gc <ids> --json` at once. Either way gc runs only on roots that are
`placed` with `placed.verified`, and never while intake is inert.

```bash
# quit foobar2000 first
sqlite3 ~/Library/foobar2000-v2/config.sqlite \
  "INSERT INTO configInts(name,value) VALUES('foo_jl_intake.confirm_gc',0)
   ON CONFLICT(name) DO UPDATE SET value=excluded.value;"
```

## foo_jl_intake.confirm_reject

`configInts`, `1` (default) or `0`. The page's "Ask before Reject"
checkbox (Confirmations). With `1`, the context menu's **Reject…** first
shows a confirmation (a sheet on the key window) that lists the albums it
affects (up to 10, then "and N more") and has an optional reason field; the
reason is passed as `--reason`. With `0`, Reject runs at once, without a
reason. Approve, Propose and Resume never ask. Execute always asks (B8): its
dry run, then a sheet listing what it will place.

# Hidden keys

## foo_jl_intake.decor_stats

`configInts`, `0` (default) or `1`. Decorate counters on the provider side
(PLAN.md B3, "INTAKE_DECOR_STATS"). They work with SimPlaylist v2 as it is, and
the Release build has them.

With it on, every decorate batch writes one console line, whatever
`log_level` is set to:

```
[intake] decor_stats: batch 64 items 210 us; since invalidation 128 items; totals 3 batches, 192 items, avg 180 us, max 260 us; loads 1, invalidations 1
```

- **batch**: the items in this batch and how long the batch took.
- **since invalidation**: the items requested since the provider last fired
  invalidate-all. SimPlaylist v2 asks for a row only when its store has no
  entry for it, which happens after an invalidation, an index remap or a
  metadb change. So each item counted here is one host cache miss.
- **totals**: batches, items, average and maximum batch time since startup.
- **loads**: successful `status` loads. **invalidations**: invalidate-alls
  fired.

**The cache-hit gate (≥99%):** open a playlist of about 5,000 rows and scroll
it from top to bottom twice, with no invalidation in between (the
`invalidations` figure must not change). On the second pass, `since
invalidation` may grow by at most 1% of the rows, so 50 items for 5,000 rows.

With it off, a batch costs one relaxed atomic load and nothing is logged.

Enable:

```bash
# quit foobar2000 first
sqlite3 ~/Library/foobar2000-v2/config.sqlite \
  "INSERT INTO configInts(name,value) VALUES('foo_jl_intake.decor_stats',1)
   ON CONFLICT(name) DO UPDATE SET value=1;"
```

Disable (or delete the row to fall back to the default):

```bash
sqlite3 ~/Library/foobar2000-v2/config.sqlite \
  "UPDATE configInts SET value=0 WHERE name='foo_jl_intake.decor_stats';"
```

## foo_jl_intake.log_file

`configInts`, default `0`. When `1`, every `[intake]` line that reaches the
console (after the `log_level` filter, plus the `decor_stats` lines) is also
appended, timestamped, to `~/Library/Logs/foobar2000/jl_intake.log`. For
in-app checks that cannot open the console window. The file is never
truncated or rotated; delete it by hand.

## foo_jl_intake.test_playlist and test_playlist_dir

Temporary acceptance aid, removed before the merge to main. It lets an
in-app check against the mock CLI build its own playlist, since nobody clicks
through foobar2000 during those runs.

`foo_jl_intake.test_playlist` (`configInts`), read at startup:

| Value | Meaning |
|---|---|
| `0` | Off (default). |
| `1` | About 4 s after start: remove every playlist named `JL intake test`, create a fresh one holding the `.wav`, `.flac` and `.mp3` files under `test_playlist_dir` (sorted, at most 10,000), and make it active. |
| `2` | About 4 s after start: remove every playlist named `JL intake test`. |

The component sets the value back to `0` after acting, and foobar2000 writes
that back when it quits. One console line reports what happened. After a
build it also reads the files' tags in the background (SimPlaylist does not,
and without `%album%` every row lands in one group with no header or badge);
a second line, `test playlist: tags read for N files (success)`, reports when
that is done.

`foo_jl_intake.test_playlist_dir` (`configStrings`): an absolute local
folder, e.g. the mock's `$INTAKE_MOCK_STATE/root`. A path under `/Volumes` or
`/volume1`, a relative path or one containing `..` is refused with a console
line, so the switch can never read a network share.

Only playlists with that exact name are created or removed; no other playlist
is touched. Playlist Organizer may keep a stale `JL intake test` node after
the playlist is removed; delete it by hand.

```bash
# quit foobar2000 first
sqlite3 ~/Library/foobar2000-v2/config.sqlite \
  "INSERT INTO configStrings(name,value) VALUES('foo_jl_intake.test_playlist_dir','/abs/local/folder')
     ON CONFLICT(name) DO UPDATE SET value=excluded.value;
   INSERT INTO configInts(name,value) VALUES('foo_jl_intake.test_playlist',1)
     ON CONFLICT(name) DO UPDATE SET value=1;"
```

## foo_jl_intake.test_open_prefs

Temporary acceptance aid, removed before the merge to main, like
`test_playlist`. It lets an in-app check take a screenshot of the
preferences page without clicking.

`configInts`, read at startup: `1` opens the Tools > Intake preferences page
about 5 s after start (`ui_control::show_preferences` with the page's GUID)
and brings the preferences window to the front; `0` (default) does nothing.
The component sets the value back to `0` before acting, and foobar2000
writes that back when it quits. One console line reports it
(`[intake] test_open_prefs: opened the Intake preferences page`).

```bash
# quit foobar2000 first
sqlite3 ~/Library/foobar2000-v2/config.sqlite \
  "INSERT INTO configInts(name,value) VALUES('foo_jl_intake.test_open_prefs',1)
     ON CONFLICT(name) DO UPDATE SET value=1;"
```

## foo_jl_intake.test_actions

Temporary acceptance aid (B6, extended in B7, B8 and B9), removed before the
merge to main with the other aids (`src/Integration/IntakeTestActions.mm`,
`src/Core/IntakeTestActionScript.*` and its tests, the `PickerTestHooks`,
`ExecuteTestHooks`, `SwapTestHooks`, `DeleteTestHooks` and
`actionsTableForHandles` in `src/Integration/IntakeActions.*`, and
`playlistRowsOfRoot` in `src/Integration/IntakeSwap.*`). It lets an in-app check drive the intake
context menu, the collection picker, the execute sheet and the delete
confirmation included, and read the group header badges, the tracked execute
runs and the playlist rows of a release, without clicking.

`configStrings`, default empty. Read once per foobar2000 session, right after
the first successful `status` load (and after the check for execute runs an
earlier session left, B8); the key is reset to `""` before the first step
runs (foobar2000 writes that back when it quits). Steps are separated by `;`,
words by spaces:

| Step | What it does |
|---|---|
| `menu <id...>` | Logs the items (title, enabled) the context menu would show for a selection of those roots' rows. The rows are the roots' members from the snapshot (a whole-folder root: its folder), mapped through the same lookup as a real selection, then the same table. |
| `badge <id...>` | Logs the group header badge for a group made of those roots' rows (the same rows as `menu`, at most the first 64, as SimPlaylist passes): it makes metadb handles for them and runs the provider's own `decorate_group` code on them, on the main thread. The line is `test_actions: badge <ids>: "<text>" color #RRGGBBAA`, with ` (amber)` after the colour when it is the amber review colour (`#00000000` is the host's default secondary colour), or `test_actions: badge <ids>: no badge` (members of two roots, a root that is not `proposed` or `approved`, an inert view). It needs no SimPlaylist panel or grouping preset. |
| `propose <id...>`, `approve <id...>`, `reject <id...> [reason=<text>]` | Builds that menu and dispatches its item for the action through the same path and mutation lane as a click. Dialogs are skipped: reject runs with the `reason=` text (everything after `reason=` to the end of the step, trimmed), or with none. A disabled item, or a busy lane, runs nothing and says so. |
| `refresh` | The **Refresh intake status** item (a full reload with `version`). |
| `assign <id> collection=<name>` | B7. Builds the menu for that one root and dispatches its quick-assign item **Assign to `<name>`** (exact name) like a click: `assign <id> --collection <name> --by user --json` through the mutation lane. `collection=` takes everything after it to the end of the step, trimmed, so names may contain spaces. Without such an item (the name is not an alternate, the root has no `ranked`, the status does not allow it) it logs the menu and runs nothing. |
| `assign-other <id...> collection=<name>` | B7. The **Assign to other collection…** flow without the sheet: runs `collections --json` as the picker does, then logs `collections: N; "<name>" listed` (or `not listed; nothing assigned`) and, when the name is listed, runs the assign on the item's qualifying roots through the same code as the sheet's **Assign** button (lane and configuration checked again). A failed `collections` logs `no picker: <cause>; nothing assigned`. |
| `picker <id...> close=<seconds>` | B7. The real flow and the real sheet (for a screenshot): the window under the pointer when the step starts (as at a click), else the main, key or foobar2000 main window, is chosen first; then `collections --json`, then the sheet on that window (on the main, key or foobar2000 main window if it can no longer take a sheet), else app-modal. One line when it is up: `sheet shown: N collection(s), preselected "", OK disabled; closing as Cancel in <seconds> s` (or `shown app-modal ...`). It is then ended as **Cancel** after `<seconds>` (more than 0, at most 30; required), so nothing is assigned. |
| `execute <id...>` | B8. **Execute placement…** through the real flow: the menu item for those roots, the real `execute <ids> --dry-run --json` on the mutation lane, then, instead of the sheet, it confirms at once and starts the detached `execute <ids that passed> --json` (lane and configuration checked again). One line once the run was spawned: `dry run: N placeable, M excluded: <the rows the sheet would list, " \| " between them, up to 10, then "and N more", then "excluded: <album>: <why>">; confirmed; started: pid <pid>, run file execute-<stamp>.run`. With nothing placeable: `dry run: 0 placeable, M excluded: ...; no sheet, nothing executed`; a dry run still running at 10 s (the sheet would then say the check did not finish): `dry run: N unchecked (the check did not finish in 10 s): <album> \| ...; confirmed; started: ...` on every captured root; a root that changed after the dry run (no longer approved, another target): `...; confirmed; <id> left out: <why>; started: ...`; a run that could not start: `...; confirmed; not started: <why>`. A disabled item (lane busy, no approved root) logs `not run: the item is disabled`. |
| `execute-sheet <id...> close=<seconds>` | B8. The real dry run and the real sheet (for a screenshot): the window under the pointer when the step starts, else the main, key or foobar2000 main window, else app-modal. One line when it is up: `sheet shown: "<title>"; N placeable, M excluded: <rows>; buttons Execute, Cancel; closing as Cancel in <seconds> s` (or `shown app-modal ...`). It is then ended as **Cancel** after `<seconds>` (more than 0, at most 30; required): nothing is executed. |
| `resume <id...>` | B8. The **Resume placement** item (placing roots; listed only for a CLI that resumes by id, 0.2.1 or later): starts the detached `execute <ids> --resume --json` at once. One line once it was spawned: `started: pid <pid>, run file execute-<stamp>.run` (or `not run: ...` / `not started: ...`). |
| `runs` | B8. One line: the execute and resume runs the component tracks (its own and adopted ones: command, pid, state `starting`/`running`/`adopted`/`exited`, ids) and the mutation lane, e.g. `1 live: execute pid 4242 adopted (itk_00000010); lane busy (execute)` or `none; lane free`. |
| `swap <id...>` | B9. Selects, in the active playlist, the rows that map to those roots by their income path (and nothing else), builds the context menu for that selection with the real per-row mapping, and runs its **Swap to library paths** item as a click does. One line once the swap has ended: `Swap to library paths (<ids>): selected N row(s); swap: S row(s) swapped to library paths, K skipped (<reasons>)`, or why nothing ran (`not run: ...`). Swap runs no CLI command (calls.log does not change) and works while an execute runs. |
| `rows <id>` | B9. One line listing the rows of the active playlist that belong to that root, by income path or through the library index (rows already swapped): `N row(s) (I income, L library), H distinct handle(s) for P distinct path(s): #<index> income\|library <native path> [h<k>]; ...; menu: <the items a selection of those rows gets>`. The same tag `h<k>` on two rows means one metadb handle; a path with two tags would be a duplicate metadb entry for one file. |
| `delete <id...>` | B9. **Delete local copy…** through the real flow: the menu item for those roots, the sidecars read afresh, the income rows counted, then, instead of the sheet, the confirmation is answered **Delete** (the roots rechecked against the current snapshot, the lane and the configuration checked again), which runs `gc <ids> --json`. One line once gc was started or could not start: `confirmation: N path(s): <first three> (+K more); Swap, then delete offered (R income row(s)); answered Delete; gc: started for 1 root` (the income rows of every playlist: `(R income row(s) in P playlist(s))` when some are outside the active one; `Swap, then delete not offered (no income row)` when no row points at an income file, `not offered (R income row(s), K without a library copy)` when Swap could not move them all; then `; U row(s) not checked (slow volume)` when some rows could not be checked). No answer from the sidecar reads within 10 s: `not run: the sidecars could not be read within 10 s ...`. With `confirm_gc` 0: `no confirmation (confirm_gc 0); gc: started for ...`. The gc result follows as its own console line (`gc: done for 1 root`, `gc failed for 1 root: ...`). |
| `delete-swap <id...>` | B9. The same, answered **Swap, then delete**: the rows of those roots that still point at income paths are swapped first, in the active playlist, then in every other playlist that has such rows (one `swap: ...` part per playlist); gc runs only when none is left in any playlist: `...; answered Swap, then delete; swap: 2 row(s) swapped to library paths, 0 skipped; gc: started for 1 root`, or `...; not run: N row(s) in P playlist(s) still point at the income paths of these roots; nothing deleted` (also `K playlist row(s) on a slow volume could not be checked`). When the confirmation did not offer it (no income row, or a row without a library copy): `...; not run: "Swap, then delete" was not offered; nothing deleted`. With `confirm_gc` 0: `no confirmation: confirm_gc is 0, so "Swap, then delete" is not offered; nothing deleted`. |
| `delete-sheet <id...> close=<seconds>` | B9. The real confirmation for a screenshot: the window under the pointer when the step starts, else the main, key or foobar2000 main window, else app-modal. One line when it is up: `sheet shown: "<title>"; <the paths and the swap offer, as for delete>; buttons Delete, Cancel[, Swap, then delete]; closing as Cancel in <seconds> s`. It is then ended as **Cancel** after `<seconds>` (more than 0, at most 30; required): nothing is deleted. With `confirm_gc` 0 there is no confirmation: `no confirmation: confirm_gc is 0; nothing deleted`. |
| `wait <seconds>` | Waits before the next step; more than 0, at most 30, decimals allowed. |

Ids must be sidecar ids (`itk_` and 8 hex digits) present in the snapshot;
otherwise the step logs why and does nothing. The same happens when the rows
map to roots other than the ones named (a root without a member list in a
folder another root covers, or a file two virtual roots list): the step logs
the roots they map to and does nothing. Each step logs one Info line
starting `test_actions:` (combine with `log_file` 1 to read them from
`~/Library/Logs/foobar2000/jl_intake.log`); the end logs `test_actions: done`.
A mutating step returns as soon as the call has started; add a `wait` before a
step that should see its result (the call, then the refresh it triggers).
`assign-other` and `picker` are different: the next step runs only once their
flow has ended (after `collections` and the assign has started, or after the
sheet has closed). Their one line comes when the outcome is known; for
`picker` that is when the sheet is up. Only one picker flow runs at a time, as
for clicks: a second one while `collections` runs or a sheet is open logs
`ignored: the collection picker is already open or loading`. `execute`,
`execute-sheet` and `resume` also wait: `execute` and `resume` until the
detached run has been spawned (not until it ends: add `wait` steps and `runs`
to follow it), `execute-sheet` until the sheet has closed. A run then holds
the mutation lane until it ends: every mutating item reads `(execute
running)` and is disabled, so mutating steps in between log
`not run: the item is disabled`. `swap`, `delete`, `delete-swap` and
`delete-sheet` (B9) wait too: `swap` until its line is logged, `delete` and
`delete-swap` until gc was started (or not run), `delete-sheet` until the
sheet has closed. Menu listings (`menu`, the `no ... item in the menu (...)`
lines) include **Swap to library paths** and **Delete local copy…** since B9,
disabled unless a selected root is `placed` with `placed.verified`. The steps
start after the first successful load, which can come before `test_playlist`
has built its playlist (about 4 s after start): begin with `wait 8` when a
step needs the playlist (`rows`, `swap`, `delete-swap`, and the income-row
count of `delete` and `delete-sheet`).

```bash
# quit foobar2000 first
sqlite3 ~/Library/foobar2000-v2/config.sqlite \
  "INSERT INTO configStrings(name,value) VALUES('foo_jl_intake.test_actions',
     'menu itk_0000000b; badge itk_0000000b; propose itk_0000000b; wait 4; menu itk_0000000b; badge itk_0000000b')
   ON CONFLICT(name) DO UPDATE SET value=excluded.value;"
```

B7 example (the mock's `default` scenario, `assign.next` holding `e-assigned`
twice):

```bash
# quit foobar2000 first
sqlite3 ~/Library/foobar2000-v2/config.sqlite \
  "INSERT INTO configStrings(name,value) VALUES('foo_jl_intake.test_actions',
     'badge itk_0000000e; assign itk_0000000e collection=Test & Ambient; wait 4; badge itk_0000000e;
      assign-other itk_0000000e collection=Test Collection C; wait 4; badge itk_0000000e;
      picker itk_0000000e itk_0000000d close=8')
   ON CONFLICT(name) DO UPDATE SET value=excluded.value;"
```

The line breaks inside the value are fine: steps are split at `;` and trimmed.

B8 example (the mock's `default` scenario with `execute.start` holding
`approved-placing`, `execute.mode` holding `slow-real 6` and `execute.next`
holding `approved-placed`; see Tests/mock-cli/README.md):

```bash
# quit foobar2000 first
sqlite3 ~/Library/foobar2000-v2/config.sqlite \
  "INSERT INTO configStrings(name,value) VALUES('foo_jl_intake.test_actions',
     'menu itk_00000010; execute itk_00000010; runs; wait 3; menu itk_00000010; wait 8; runs; menu itk_00000010')
   ON CONFLICT(name) DO UPDATE SET value=excluded.value;"
```

B9 example (the mock's `default` scenario with `gc.next` holding
`placed-gc_done`; the test playlist built from `$INTAKE_MOCK_STATE/root`, so
it holds the income and the library copies of `itk_00000012`):

```bash
# quit foobar2000 first
sqlite3 ~/Library/foobar2000-v2/config.sqlite \
  "INSERT INTO configStrings(name,value) VALUES('foo_jl_intake.test_actions',
     'wait 8; rows itk_00000012; swap itk_00000012; rows itk_00000012; delete-sheet itk_00000012 close=8;
      delete itk_00000012; wait 4; menu itk_00000012')
   ON CONFLICT(name) DO UPDATE SET value=excluded.value;"
```

Execute runs leave two files in `~/Library/Caches/foo_jl_intake/` while they
run: `execute-<stamp>.json` (the CLI's stdout) and `execute-<stamp>.run` (pid,
start time, ids, root paths, output name, command). The run file is written
before the CLI starts, without the pid and start time, and rewritten with
them as soon as the child exists. Both are deleted when the component has
read the result. A run still going when foobar2000 quits keeps running and
keeps its files; the next start adopts it (live) or finishes it (ended). A
run file still without a pid (foobar2000 was gone before it was rewritten)
is adopted when one of this user's processes still has the output open (that
process is then watched), finished when the output exists and nobody has it
open, and deleted when there is no output (the CLI never started). Stray
`execute-*.json`/`.tmp` files that have no run file, and run files that do
not parse, are deleted.

# Reverting everything

```bash
# quit foobar2000 first
sqlite3 ~/Library/foobar2000-v2/config.sqlite \
  "DELETE FROM configStrings WHERE name LIKE 'foo_jl_intake.%';
   DELETE FROM configInts WHERE name LIKE 'foo_jl_intake.%';"
```
