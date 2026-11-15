# Hidden options (config-store only)

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
The component reads these keys once, at startup.

The preferences page (PLAN.md B5) will take over the first four keys. Until
then they can only be set here. `decor_stats` stays hidden after that.

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

## Reverting everything

```bash
# quit foobar2000 first
sqlite3 ~/Library/foobar2000-v2/config.sqlite \
  "DELETE FROM configStrings WHERE name LIKE 'foo_jl_intake.%';
   DELETE FROM configInts WHERE name LIKE 'foo_jl_intake.%';"
```
