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

**Hidden (config store only):** `decor_stats`, `log_file` and
`recent_collections` (kept by the picker, not a setting).

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
The icons that take a colour use it at full alpha; on a tint of alpha `99`
(60%) or more they use the label colour, the colour of the row text, so they
stay visible. The amber group badge keeps the full-alpha colour at any alpha
(the group header is not tinted). An alpha of `00` with a colour
(`0xRRGGBB00`) draws no background but keeps the icon colour. A
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
shows a confirmation (a sheet on the window under the pointer at the click,
else the main or key window) that lists the albums it
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

## foo_jl_intake.recent_collections

`configStrings`, default empty. The "Recent" section of the "Assign to other
collection…" picker: the last five collections the user confirmed Assign
for, one name per line, most recent first. The picker writes it when Assign
is confirmed and reads it when it opens; names the CLI no longer lists are
left out of the section and dropped at the next write. Not a preference: to
clear the list, delete the row while foobar2000 is quit:

```bash
sqlite3 ~/Library/foobar2000-v2/config.sqlite \
  "DELETE FROM configStrings WHERE name='foo_jl_intake.recent_collections';"
```

# Execute run files

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
