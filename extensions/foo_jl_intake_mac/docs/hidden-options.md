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
`confirm_reject` (B6) and `log_level`. These are no longer hidden: the page
writes them and they apply at once, with no restart (a CLI, bun or rules
change reloads with `version`; a watched-folders change rebuilds the watch
set; the log level and `confirm_reject` apply immediately). They are described below because in-app checks set them with
`sqlite3` while foobar2000 is quit.

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
half-filled or relative pair. Stored and validated only until Swap exists.

## foo_jl_intake.confirm_reject

`configInts`, `1` (default) or `0`. The page's "Confirm before Reject"
checkbox (Confirmations). With `1`, the context menu's **Reject…** first
shows a confirmation (a sheet on the key window) that lists the albums it
affects (up to 10, then "and N more") and has an optional reason field; the
reason is passed as `--reason`. With `0`, Reject runs at once, without a
reason. Approve and Propose never ask. Execute will always ask (B8).

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
| `1` | About 4 s after start: remove every playlist named `JL intake test`, create a fresh one holding the `.wav`, `.flac` and `.mp3` files under `test_playlist_dir` (sorted, at most 2,000), and make it active. |
| `2` | About 4 s after start: remove every playlist named `JL intake test`. |

The component sets the value back to `0` after acting, and foobar2000 writes
that back when it quits. One console line reports what happened.

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

Temporary acceptance aid (B6, extended in B7), removed before the merge to
main with the other aids (`src/Integration/IntakeTestActions.mm`,
`src/Core/IntakeTestActionScript.*` and its tests, and the
`PickerTestHooks` in `src/Integration/IntakeActions.*`). It lets an in-app
check drive the intake context menu, the collection picker included, and
read the group header badges, without clicking.

`configStrings`, default empty. Read once per foobar2000 session, right after
the first successful `status` load; the key is reset to `""` before the first
step runs (foobar2000 writes that back when it quits). Steps are separated
by `;`, words by spaces:

| Step | What it does |
|---|---|
| `menu <id...>` | Logs the items (title, enabled) the context menu would show for a selection of those roots' rows. The rows are the roots' members from the snapshot (a whole-folder root: its folder), mapped through the same lookup as a real selection, then the same table. |
| `badge <id...>` | Logs the group header badge for a group made of those roots' rows (the same rows as `menu`, at most the first 64, as SimPlaylist passes): it makes metadb handles for them and runs the provider's own `decorate_group` code on them, on the main thread. The line is `test_actions: badge <ids>: "<text>" color #RRGGBBAA`, with ` (amber)` after the colour when it is the amber review colour (`#00000000` is the host's default secondary colour), or `test_actions: badge <ids>: no badge` (members of two roots, a root that is not `proposed` or `approved`, an inert view). It needs no SimPlaylist panel or grouping preset. |
| `propose <id...>`, `approve <id...>`, `reject <id...> [reason=<text>]` | Builds that menu and dispatches its item for the action through the same path and mutation lane as a click. Dialogs are skipped: reject runs with the `reason=` text (everything after `reason=` to the end of the step, trimmed), or with none. A disabled item, or a busy lane, runs nothing and says so. |
| `refresh` | The **Refresh intake status** item (a full reload with `version`). |
| `assign <id> collection=<name>` | B7. Builds the menu for that one root and dispatches its quick-assign item **Assign to `<name>`** (exact name) like a click: `assign <id> --collection <name> --by user --json` through the mutation lane. `collection=` takes everything after it to the end of the step, trimmed, so names may contain spaces. Without such an item (the name is not an alternate, the root has no `ranked`, the status does not allow it) it logs the menu and runs nothing. |
| `assign-other <id...> collection=<name>` | B7. The **Assign to other collection…** flow without the sheet: runs `collections --json` as the picker does, then logs `collections: N; "<name>" listed` (or `not listed; nothing assigned`) and, when the name is listed, runs the assign on the item's qualifying roots through the same code as the sheet's **Assign** button (lane and configuration checked again). A failed `collections` logs `no picker: <cause>; nothing assigned`. |
| `picker <id...> close=<seconds>` | B7. The real flow and the real sheet (for a screenshot): `collections --json`, then the sheet on the window under the pointer, else the main or key window, else app-modal. One line when it is up: `sheet shown: N collection(s), preselected "", OK disabled; closing as Cancel in <seconds> s` (or `shown app-modal ...`). It is then ended as **Cancel** after `<seconds>` (more than 0, at most 30; required), so nothing is assigned. |
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
`ignored: the collection picker is already open or loading`.

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
sqlite3 ~/Library/foobar2000-v2/config.sqlite \
  "UPDATE configStrings SET value='badge itk_0000000e; assign itk_0000000e collection=Test & Ambient; wait 4;
     badge itk_0000000e; assign-other itk_0000000e collection=Test Collection C; wait 4; badge itk_0000000e;
     picker itk_0000000e itk_0000000d close=8'
   WHERE name='foo_jl_intake.test_actions';"
```

# Reverting everything

```bash
# quit foobar2000 first
sqlite3 ~/Library/foobar2000-v2/config.sqlite \
  "DELETE FROM configStrings WHERE name LIKE 'foo_jl_intake.%';
   DELETE FROM configInts WHERE name LIKE 'foo_jl_intake.%';"
```
