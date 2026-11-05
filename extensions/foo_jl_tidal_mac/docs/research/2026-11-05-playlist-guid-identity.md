# Playlist GUID identity (`playlist_manager_v5`)

**Date:** 2026-11-05. **Brief:** `docs/design/2026-11-05-playlist-guid-brief.md`.
**Host:** foobar2000 v2.26 preview 2026-07-09 (bundle build 66), macOS 27.0.1, SDK-2026-10-01.
**Method:** a temporary probe in this component (`src/Integration/TidalGuidProbe.mm`, commit `2db7004`), armed by the hidden option `tidal.TI_guid_probe`.
- **Run A** started at 21:34:29. foobar2000 was then quit and started again.
- **Run B** started at 21:35:21.
- **Log:** `~/Library/Logs/foobar2000/jl_tidal_guid_probe.log` (local only).
- **What is quoted here:** the user's playlist names and file paths are left out; counts are kept.
- **Cross-check:** JL Shell 0.1.3's startup census agreed both times.
  - `census: playlist_manager_v5 available; 39 playlists, 39 GUIDs match playlists-v2.0/index.txt (39 entries), 39 find_playlist_by_guid round-trips`
  - 40 of each before run B, the extra one being the probe playlist.

## Verdict

**Yes: per-playlist state can be keyed by playlist GUID across restarts, with caveats.**
- **Host:** a single host (2.26 preview, build 66), on a profile with only ordinary playlists.
- **What holds:** the GUID is unique and never null, matches the `index.txt` on disk, survives restart, rename and reorder, and `find_playlist_by_guid` always returns the current index.
- **What it does not survive:** restoring a deleted playlist from the recycler gives it a new GUID. A duplicate also gets a new GUID, whether or not it is created with the source's side info. So GUID-keyed state is orphaned when a playlist is deleted and restored.
- **Mitigation:** persistent playlist properties do survive restart, rename and recycler restore. A role tag or a back-pointer stored as a property can re-link a restored playlist.
- **Duplicate risk:** `create_playlist_ex` with side info copies the properties too, so code that relies on a property must treat two playlists carrying the same tag as a duplicate, not as one identity.
- **Not-found value:** SIZE_MAX.
- **Threading:** main thread only.
- **Untested:** autoplaylists and TIDAL-sync (locked) playlists, because none existed on this profile.

## Results

| # | Question | Answer | Evidence (probe log) |
|---|---|---|---|
| 1 | Host serves `playlist_manager_v5`? | **Yes** (v3-v6 all present) | `Q1 tryGet: playlist_manager_v3 yes, playlist_manager_v4 yes, playlist_manager_v5 yes, playlist_manager_v6 yes`, in both runs |
| 2 | All GUIDs unique, never `guid_null`? | **Yes** | `Q2 39 playlists, 39 unique GUIDs, 0 guid_null, 0 duplicated GUIDs` (run A), `40 ... 40 ...` (run B) |
| 3 | API GUIDs equal `index.txt`, both directions? | **Yes** | `Q3 API 39 GUIDs, index.txt 39; in API only 0; in index.txt only 0; name mismatches on shared GUIDs 0; .fplite files 39, not in index.txt 0`. Run B: 40/40, and `saved gP C3B026F7-... in index.txt after restart: yes`. The file has a UTF-8 BOM and CRLF line endings |
| 4 | Stable across restart? | **Yes** | `Q4 find_playlist_by_guid(saved gP C3B026F7-5DED-E15F-4BAC-1C7A846C18F9) = 39`; `name "JL GUID probe" (same yes); items 3 (saved 3, same yes); first item ... (same yes)` |
| 5 | Stable across rename? | **Yes** | `playlist_rename([40], "JL GUID probe (renamed)") = yes; ... guid before E60BFC39-..., after E60BFC39-..., same yes; find_playlist_by_guid(gT) = 40, same index yes`, and the same after renaming back |
| 6 | Stable across reorder; does the lookup follow? | **Yes, and yes** | `reorder(swap [39] and [40]) = yes; find_playlist_by_guid(gP) = 40 (expect 40), find_playlist_by_guid(gT) = 39 (expect 39)`; after swapping back, 39 and 40 again |
| 7 | Does a duplicate get a new GUID? Can side info clone it? | **New GUID both ways; side info does not carry the GUID** | D1 `create_playlist`: `guid A6FCE079-..., equals gT no`. D2 `create_playlist_ex` with T's side info: `guid 8B0D8698-..., equals gT no`. The side info `contains gT raw bytes no, gT big-endian bytes no, gT as text no, property key raw bytes yes` |
| 8 | Exact not-found value? | **SIZE_MAX** (`0xffffffffffffffff`), which equals `pfc_infinite` and `pfc::infinite_size` | `find_playlist_by_guid(removed) = 18446744073709551615 (0xffffffffffffffff); ==SIZE_MAX yes; ==(size_t)pfc_infinite yes; ==pfc::infinite_size yes`. The same value for `guid_null` and for a GUID that never existed |
| 9 | Recycler restore: same GUID? | **No, a new GUID** | `recycler_restore_by_id(3): count 40 -> 41; find_playlist_by_guid(gT) = 18446744073709551615`; `restored as a new GUID 62B67BE6-8846-1E89-C531-FAB40EFC1F8F at [40] "JL GUID probe", 3 items` |
| 10 | Properties: survive rename and restart; copied by duplicate and restore? | **Survive rename and restart. Restore keeps them. `create_playlist_ex` with side info copies them; plain `create_playlist` does not** | rename: `property present yes ... equal yes`. Restart: `property present yes, value "jl-guid-probe P 2026-11-05 21:34:29.579", equals saved ... yes`. D1: `property present no`. D2: `property present yes ... equals T's yes`. Restored: `property present yes ... equals T's yes` |
| 11 | Autoplaylists, Library Viewer Selection, TIDAL-sync playlists? | **Not observable on this profile** | `0 autoplaylists`, `0 locked (TIDAL Sync 0 ...)`, `Library Viewer Selection absent`. All 39 playlists are ordinary, unlocked, and listed in `index.txt` |
| 12 | Threading? | **Main thread only**, per the SDK; every probe call was made from the main queue | `playlist.h:79`: "All playlist_manager methods are valid only from main app thread, unless documented otherwise." Since 2.26 the only exceptions are `get_active_playlist()` and `playlist_item_format_title()`, read from a worker while the main thread is blocked (`playlist.h:97-98, 167-168`). Off-main calls were not tested |

## Not-found value

`find_playlist_by_guid` returns `SIZE_MAX` for:
- a removed playlist;
- `pfc::guid_null`;
- a GUID that never existed.

`pfc_infinite` is `(~0)`, an `int`. Converted to `size_t` it equals `SIZE_MAX`, so either comparison works. The robust check is `index < get_playlist_count()`, which all TIDAL call sites already use.

## Recycler behaviour

- **Every `remove_playlist` call adds a recycler entry,** including API removals of probe playlists: D2, D1 and T got ids 1, 2 and 3.
- **The entry keeps the name and items:** `name "JL GUID probe", 3 items`.
- **Restore moves the entry out of the recycler:** `recycler_find_by_id(3) after restore = SIZE_MAX`.
- **The restored playlist is appended at the end with a new GUID, and keeps its properties.**
- **Recycler ids are per-session counters, not a persistent identity.** Run A started with an empty recycler and handed out ids 1-4. Run B, after the restart, handed out id 1 again.
- **Recycler contents are not persistent either, as far as this run shows.** The recycler was empty at the start of both runs. Run A had purged its own entries, so this does not prove that the recycler is cleared at exit.
- **Purging by id works:** `recycler_purge ids [1,2,4]; recycler count 3 -> 0`.

## Side info

- **`playlist_get_sideinfo` returns the playlist's persistent properties and nothing else** (63 bytes):
  - a count (`01 00 00 00`);
  - the property key GUID (`d9 e0 06 e1 ...`);
  - a length (`27 00 00 00`, 39);
  - the value bytes (`jl-guid-probe T ...`).
- **No GUID, name or items.** `create_playlist_ex(..., sideInfo)` copies the properties into the new playlist, but the new playlist always gets a new GUID.

## Properties

- **They survive** rename, restart and recycler restore.
- **They are copied** by `create_playlist_ex` with the source's side info, but not by `create_playlist`.

So a property is a better carrier for "which logical playlist is this" than the GUID when deleted playlists can come back through the recycler. But it can be cloned, so code that relies on it has to detect duplicates.

## Consequences for TIDAL code

- **Not-found handling: correct, no change needed.**
  - `TidalPlaylistSync.mm` `resolvePlaylistIndex` (around line 695) documents SIZE_MAX, as observed.
  - Its caller (`TidalSyncImportNotify::on_completion`) and `TidalPlayNotify::resolveIndex` in `TidalBrowserController.mm` both check `idx < get_playlist_count()`, which does not depend on the exact value.
- **Sync identity (recommendation, not done):** sync maps TIDAL playlist UUIDs to foobar2000 playlist names (`uuidToNameMap` / `nameToUUIDMap`, persisted in `foo_tidal.sync_map`). So renaming a synced playlist in foobar2000 breaks the link.
  - Keying by persisted GUID would survive rename and reorder.
  - Storing the TIDAL UUID as a playlist property as well would re-link a playlist restored from the recycler.
  - A GUID mismatch identifies a duplicate made with side info.
  - This changes the sync data format and needs a migration from the name map, so it is logged in the component backlog rather than done here.

## The probe

- **Removed after these runs.** It was 1,400 lines, and the 0.4.0 release is next. JL Shell's startup census keeps re-checking Q1-Q3 on every start.
- **To re-run it on a later host:** restore the probe files from commit `2db7004` (`TidalGuidProbe.h/.mm`, the `kGuidProbe` constant, the `on_init` call, and its `hidden-options.md` section), build, and arm `tidal.TI_guid_probe = 1`.
- **Leftovers:**
  - the key `tidal.TI_guid_probe = 3` in `config.sqlite` (harmless: nothing reads it);
  - one `JL GUID probe` node in Playlist Organizer's tree (`foo_plorg.yaml`), which adds a node for every new playlist name and does not remove nodes when playlists are deleted. Renaming did not add a second node.
