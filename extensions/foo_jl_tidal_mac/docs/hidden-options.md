# Hidden options (config-store only)

Some settings are deliberately absent from the Preferences UI. They live in
foobar2000 v2's config store, which is a SQLite database:

```
~/Library/foobar2000-v2/config.sqlite
```

Settings are split by type across tables — `configInts` (booleans and integers,
booleans stored as 0/1), `configStrings`, `configReals`, `configBlobs`. The
component's keys all use the `tidal.` prefix, so `SELECT * FROM configStrings
WHERE name LIKE 'tidal.%'` shows the visible settings too.

**foobar2000 must be quit before editing.** It caches configuration in memory
and writes it back on exit, so edits made while it runs are overwritten.

## tidal.TI_download_on

Master gate for the personal library-download feature ("Save to library
(music.hq)"). Default off. When off:

- the Preferences > Tidal > **Library** section is not built at all
- the **Save to library** playlist context-menu command stays hidden
- `JLTidalLibrarySaver` refuses to run even if invoked some other way

The configured library root (`tidal.library_root`) is left untouched while the
gate is off, so turning it back on restores the previous folder.

Enable:

```bash
# quit foobar2000 first
sqlite3 ~/Library/foobar2000-v2/config.sqlite \
  "INSERT INTO configInts(name,value) VALUES('tidal.TI_download_on',1)
   ON CONFLICT(name) DO UPDATE SET value=1;"
```

Disable (set to 0, or delete the row to fall back to the default):

```bash
sqlite3 ~/Library/foobar2000-v2/config.sqlite \
  "UPDATE configInts SET value=0 WHERE name='tidal.TI_download_on';"
```

Check the current state:

```bash
sqlite3 ~/Library/foobar2000-v2/config.sqlite \
  "SELECT name,value FROM configInts WHERE name='tidal.TI_download_on';"
```

An empty result means the key was never written — the default (off) applies.

## tidal.signin_display

Also settable from Preferences ("Browser status line"), listed here because it
is an integer enum: `0` = show nothing, `1` = show email (default), `2` = show
username. Stored in `configInts`.
