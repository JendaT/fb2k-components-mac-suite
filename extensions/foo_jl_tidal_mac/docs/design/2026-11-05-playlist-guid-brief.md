# Brief: settle playlist GUID identity (`playlist_manager_v5`)

**For:** the TIDAL worker (`dev/tidal-integration`). **From:** the planning session, 2026-11-05, at Jenda's request.
**Size:** small: one probe, one foobar2000 restart, one findings doc.

## Why this lands on you

- **SimPlaylist v2** wants to key all per-playlist state (layout cache, scroll anchors, roles) by playlist GUID instead of index or sanitised name. It is a phase 0 gate in `extensions/foo_jl_simplaylist_mac/docs/V2_PLAN.md` on `dev/simplaylist`.
- **The master design's playlist roles** identify playlists by GUID and store role tags in playlist properties.
- **TIDAL holds the only production use in the suite:** `TidalPlaylistSync.mm:684-701` and `TidalBrowserController.mm` (around lines 120-140). It uses GUIDs within one session, with an index fallback. So the owner of that code settles it.

## What is known

- **SDK `playlist.h`:**
  - `playlist_manager_v5` (since 2.0) adds `playlist_get_guid(idx)` and `find_playlist_by_guid(guid)`; its not-found return value is undocumented.
  - `playlist_manager_v6` only adds callback merit.
  - `playlist_manager_v3` has the recycler: `recycler_get_id`, `recycler_restore_by_id`, `recycler_find_by_id`, `recycler_purge`.
  - `playlist_manager_v4` has `playlist_get_sideinfo` / `create_playlist_ex`.
  - `playlist_manager_v2` has playlist properties.
- **On disk, the core stores playlists by GUID:** `~/Library/foobar2000-v2/playlists-v2.0/index.txt` (`GUID:name` lines), and `playlist-<GUID>.fplite` plus `-props.sqlite`.
- **JL Shell 0.1.3** (installed) logs at startup whether the API's GUIDs match `index.txt`: the line `census: playlist_manager_v5 …` in `~/Library/Logs/foobar2000/jl_shell.log`. Use it as a cross-check, not as the answer.

## Questions to settle (each needs a yes/no with evidence)

| # | Question | How |
|---|---|---|
| 1 | Does this host (the installed foobar2000 2.26 preview) serve `playlist_manager_v5`? | `tryGet` result |
| 2 | Are all GUIDs unique and never `guid_null`? | all playlists |
| 3 | Do the API's GUIDs equal those in `index.txt`, in both directions? | compare the sets |
| 4 | Stable across a restart? | a probe playlist created in run A is found by GUID in run B, same name, same item count |
| 5 | Stable across rename? | rename a temporary playlist |
| 6 | Stable across reorder, and does `find_playlist_by_guid` return the new index? | move it |
| 7 | Does a duplicate get a new GUID? Both `create_playlist` with the same content, and `create_playlist_ex` with the source's side info: can side info clone the GUID? | duplicate it both ways |
| 8 | After delete: the exact return value of `find_playlist_by_guid` (`SIZE_MAX`? `pfc_infinite`?). TIDAL's `resolvePlaylistIndex` assumes `SIZE_MAX`. | remove it |
| 9 | Delete, then restore from the recycler (`recycler_restore_by_id`): same GUID or a new one? | recycler API |
| 10 | Do properties (`playlist_set_property`, i.e. the role tags) survive rename and restart? Are they copied by duplicate and restore? | set a property with a fixed test GUID key |
| 11 | Autoplaylists, Library Viewer Selection, TIDAL-sync playlists: do they have GUIDs, and are they in `index.txt`? | observe only |
| 12 | Threading: main thread only, like the rest of `playlist_manager`? | document; call from main |

## Method

- **Switch:** a temporary probe in the TIDAL component, behind a hidden option (`docs/hidden-options.md`), off by default.
- **Run A** (startup, or a debug menu command):
  - Q1–3 and Q11.
  - Create `JL GUID probe` at the end with a few tracks, set the test property on it, and record its GUID in configStore.
  - On a second temporary playlist, run Q5–9 and Q10's duplicate/restore part.
  - Remove that second playlist and purge only the recycler entries the probe created, by id.
  - Keep `JL GUID probe` for run B.
- **Run B** (next start): Q4 and Q10 on `JL GUID probe` (found by GUID, name, item count, property). Then remove it and purge its recycler entry.
- **Logging:** log every step with a `[Tidal] [GUID probe]` prefix, giving values (GUIDs, indices, return codes), not just pass or fail.
- **Restart:** ask Jenda to restart foobar2000 between the runs.
- **Safety:** never touch the user's own playlists. Restore the active playlist and the playlist order exactly. Clean up even if a step throws.

## Deliverables

1. **Findings doc:** `docs/research/2026-11-05-playlist-guid-identity.md`. It contains:
   - the table with results and log evidence;
   - the exact not-found value;
   - recycler and side-info behaviour;
   - property behaviour;
   - a one-paragraph verdict: *can per-playlist state be keyed by GUID across restarts — yes or no, and with which caveats?*
2. **TIDAL code:** fix anything a finding contradicts (for example the not-found check), and note it in the doc. If it would help, consider keying synced playlists by persisted GUID.
3. **The probe:** remove it, or keep it behind the hidden option; say which.
4. **Report to Jenda:** the verdict paragraph and the doc path. Don't edit SimPlaylist's plan or the master design; they live on `dev/simplaylist`, and the planning session updates them from your doc.

## Constraints

`CLAUDE.md` worktree safety; `fb2k::configStore`; UI and playlist calls on the main thread; commit on `dev/tidal-integration` as usual.
