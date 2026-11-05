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

## tidal.TI_guid_probe

Temporary probe that checks whether foobar2000's playlist GUIDs
(`playlist_manager_v5`) are a reliable persistent identity. It answers the 12
questions in `docs/design/2026-11-05-playlist-guid-brief.md` over two starts of
foobar2000. Default off. Stored in `configInts`. The probe will be removed once
the findings are written up.

| Value | Meaning |
|---|---|
| `0` | Off (default). Nothing runs, nothing is logged. |
| `1` | Run A at the next start. Run A sets the value to `2` when it finishes (or `3` if run B cannot follow). |
| `2` | Run B at the next start. Run B sets the value to `3`. |
| `3` | Done. Nothing runs. |

Any other value logs one line and does nothing. Each run starts about 3 seconds
after the component loads, on the main thread.

Enable (run A at the next start):

```bash
# quit foobar2000 first
sqlite3 ~/Library/foobar2000-v2/config.sqlite \
  "INSERT INTO configInts(name,value) VALUES('tidal.TI_guid_probe',1)
   ON CONFLICT(name) DO UPDATE SET value=1;"
```

Then start foobar2000 (run A), quit it, and start it again (run B). Check the
state:

```bash
sqlite3 ~/Library/foobar2000-v2/config.sqlite \
  "SELECT name,value FROM configInts WHERE name='tidal.TI_guid_probe';"
```

**Log:** every line goes to the foobar2000 console with the prefix
`[Tidal] [GUID probe]`, and is mirrored, timestamped, to
`~/Library/Logs/foobar2000/jl_tidal_guid_probe.log` (appended). Each run ends
with one `RESULT Qn: ...` line per question it covered.

**What it creates and removes:** every playlist it creates is named
`JL GUID probe` and is appended after the user's playlists. It is never made
active.

- Run A creates the probe playlist P (up to 3 tracks copied from the first
  non-autoplaylist playlist with items, or from the media library) and keeps it
  for run B. It also creates a temporary playlist T, renames it to
  `JL GUID probe (renamed)` and back, swaps it with P and back, creates two
  duplicates of it, removes T, restores it from the recycler, and removes it
  again. Everything except P is removed before run A ends.
- Run B looks P up by its saved GUID, then removes it. If the GUID lookup
  fails, it removes the playlists named exactly `JL GUID probe` instead.
- Both runs purge only the recycler entries they created: entries that were not
  there when the run started and whose name starts with `JL GUID probe`.
- Both runs restore the active playlist and check that the order of the user's
  playlists is unchanged.
- State between the runs is kept in `configStrings`/`configInts` under
  `tidal.guid_probe.*` (P's GUID, item count, first item path, test property
  value). Run B deletes these keys.

User playlists are only read: names, GUIDs, item counts, autoplaylist and lock
status.

**Leftover:** Playlist Organizer adds a tree node for every new playlist name
and never removes it. After the probe, it may show a stale `JL GUID probe` node
(and possibly `JL GUID probe (renamed)`, if it also adds nodes on rename).
Delete them by hand.
