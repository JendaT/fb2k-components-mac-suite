# Streaming-style layout: Up Next + ShellVanced — Design

Date: 2026-11-27 · Status: approved 2026-11-27

## Intent

The current foobar2000 layout splits playlists, queue, library tree and album grid across four panes, each with its own idea of "play" and "queue". In practice the user never uses the Queue tab and builds their listening with AlbumViewVanced's "Add to Now Playing". The goal is a Spotify/Apple Music–style flow:

- one obvious "what plays next" list, reachable from the bottom bar;
- a left sidebar with library sections and playlists, a main content area that navigates;
- one consistent set of actions everywhere.

Current layout (`~/Library/foobar2000-v2/UI-Layout.txt`): `foo_plorg` + tabs(`queue_manager`, `LibVanced`) on the left, tabs(`simplaylist`, `AlbumViewVanced`) in the middle, `playvanced` at the bottom.

## Goals

1. **Single up-next model.** The hidden "Now Playing" playlist is the one and only up-next list.
2. **Up Next popover** opened from a new button in PlayVanced's bar.
3. **Unified actions** in AlbumViewVanced and (when hosted by the shell) SimPlaylist: **Play**, **Play Next**, **Add to Queue**, **Add to Playlist ▸**, with no duplicate entries.
4. **ShellVanced**: new ui_element that owns the main area — sidebar (Albums, Your Library with Playlists/Artists filters) + content area hosting the existing panels, with back/forward.
5. **Artist browser** (added 2026-11-27): artist list with round photos (Deezer, album-cover fallback) and an artist page.
6. **Keyboard shortcuts** in the Spotify/Apple Music style (§7).
7. Fix the duplicate ui_element GUID `{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}` shared by Playlist Organizer, Playback Controls and Tidal.

## Non-goals (v1)

- Shell-level global search (each hosted panel keeps its own search field).
- Album detail pages (AlbumViewVanced's inline expand stays the album view).
- LibVanced in the shell (user decided: album search already finds artists; the artist browser replaces the tree). LibVanced is untouched.
- Spotify as a photo source (tested 2026-11-27: Deezer 46/62 album artists with photo vs Spotify 40/62, union 48; Spotify dev apps hit a 24 h rate-limit block after ~70 searches).
- Playlist folders in the sidebar (plorg keeps folders; the shell sidebar is flat).
- SDK upgrade to 2026-10-01 (separate task: C++17→C++20 across all projects).
- Exact shuffle-order prediction in the popover.

## Anti-goals

- Never modify the user's real playlists as a side effect of Play / Play Next / Add to Queue.
- Never lose foobar playback-queue items silently (they're still shown and still play first).
- Don't break the components for people using them outside the shell (standalone behavior of SimPlaylist stays unchanged unless shell mode is requested).

## Constraints (verified)

- Mac `ui_element_mac` has only `instantiate(arg)` / `match_name` / `get_name` / `get_guid` (unchanged in SDK 2026-10-01). No host API for tab switching or visibility. `arg` is a wrapped `NSDictionary<NSString*,NSString*>`; result is a wrapped `NSViewController` (`fb2k::wrapNSObject` / `unwrapNSObject`, `commonObjects-Apple.h`).
- Components are separate dylibs: no shared symbols. Cross-component cooperation is only through SDK services (`ui_element_mac` enumeration, `playlist_manager`, playlist properties, callbacks) and shared source compiled into each target.
- foobar `tabs`/`splitter` are `NSTabViewController`/`NSSplitViewController` subclasses (`fooTabViewController`, `fooSplitViewController`) — not needed by this design, noted for future.
- No SDK API returns "next item under the active playback order"; `playlist_manager::get_playing_item_location`, item accessors and `playlist_set_property`/`get_property` (`playlist.h:409-477`) are available. `set_playing_playlist` exists (`playlist.h:103`).
- SimPlaylist always shows the *active* playlist (`SimPlaylistController.mm:806-881`); plorg activates playlists by name.
- Repo `shared/*.mm` is not compiled into any target today; header-only shared code is the low-friction route.

## Approaches considered

**Up next model**
- **A. Single up-next list (chosen).** "Now Playing" is the list; Play / Play Next / Add to Queue all operate on it. Matches how the user already listens; one concept.
- B. Spotify two-tier (foobar queue + context). Rejected: keeps the concept the user never uses.

**Layout / navigation**
- X. Re-arrange the foobar layout only. Cheap, but clicking a playlist can't switch the main tab.
- **Y. ShellVanced (chosen).** One panel owns navigation and hosts existing panels by instantiating them through `ui_element_mac` — the native equivalent of how Eole/Columns UI themes keep all views alive and switch a shared "current view" value.
- Tab-switching hack (walk `parentViewController` to the host's `NSTabViewController`): works with public AppKit, depends on host internals; not needed with Y.

## Design

### 1. Shared up-next helper — `shared/UpNext.h` (header-only, `inline`)

One implementation, compiled into each component that needs it:

- `kNowPlayingName = "Now Playing"`; `findOrCreateNowPlaying()`.
- `playNow(handles, startIndex, sourceLabel)` — replace Now Playing contents, set focus, start playback at `startIndex`, store `sourceLabel`. Does **not** flush the foobar queue (change from current AlbumViewVanced behavior).
- `playNext(handles)` — insert after the playing item in Now Playing. If nothing is playing from Now Playing (stopped, or playing another playlist), see "Playing from another playlist" below.
- `addToQueue(handles)` — append to Now Playing (same fallback rule).
- `playPlaylistIntoNowPlaying(srcPlaylist, startRow)` — copy a real playlist into Now Playing, play from `startRow`, label "Next from: <playlist name>".
- Source label stored as a playlist property on Now Playing under a fixed GUID (UTF-8 string). Fallback when absent: "Now Playing".
- `filterDuplicateFoobarItems(...)` — helper used when converting foobar's context menu tree to `NSMenu`: skip foobar's own "Play" and "Add to playback queue" entries (by command GUID when obtainable, else by name).

**Active playlist rule (my call):** none of these helpers may change the *active* playlist (today `AlbumViewVancedController.mm:395` does — remove that). They only change the *playing* playlist (`set_playing_playlist`). Otherwise the shell's SimPlaylist would show Now Playing under another playlist's title. Known incompatibility: with foobar's "Playback follows cursor" enabled, browsing playlists in the shell changes what plays; documented, not guarded in v1.

**Shuffle (my call, user rarely uses shuffle):** when the active playback order is not "Default"/"Repeat (playlist)"/"Repeat (track)" (i.e. shuffle/random), `playNext` uses the foobar playback queue (`queue_add_item_playlist` after ensuring the items are in Now Playing) so the track reliably plays next; it shows in the popover's "Queued" section. `addToQueue` always appends to Now Playing.

**Playing from another playlist:** when playback is from playlist P ≠ Now Playing and the user does Play Next / Add to Queue, first copy P's remaining items (from the playing index on) into Now Playing, call `set_playing_playlist(NowPlaying)` so the next track comes from Now Playing, then apply the action. The current track keeps playing uninterrupted. When stopped, Play Next/Add to Queue simply edits Now Playing without starting playback.

### 2. AlbumViewVanced

- Context menu top section: **Play**, **Play Next**, **Add to Queue**, **Add to Playlist ▸** (playlist list excludes Now Playing), separator, then foobar's tree with duplicates filtered.
- Remove "Add to Now Playing" / "Add to Playback Queue" custom items.
- Double-click / Enter → Play (replace Now Playing).
- `Q` → Add to Queue (append to Now Playing).
- **Artist filter** for the shell's artist page: the controller responds to `-setArtistFilter:(nullable NSString*)name` (called by the shell via ObjC messaging, no linking). When set: show only albums where the artist is an album artist (after collaboration splitting) first, then albums they appear on (track artist) under an "Appears on" separator; hide the search field. `nil` restores the normal grid.
- **⌘F / ⌘L** focus its search field (works standalone too).

### 3. SimPlaylist shell mode

Shell instantiates SimPlaylist with `arg = {"vanced": "1"}`. When set (and only then):
- Double-click / Enter → `playPlaylistIntoNowPlaying(active, row)`.
- Context menu gets Play / Play Next / Add to Queue at the top; foobar duplicates filtered.
- `Q` → Add to Queue.
Without the flag SimPlaylist behaves exactly as today. (Whether foobar itself passes layout attributes in `arg` must be checked; the key name `vanced` must not collide.)

### 4. PlayVanced Up Next popover

- New SF Symbol button (`list.bullet`) between rating and shuffle in `NowPlayingView` (`setupSubviews` ~`:112`, `layout` ~`:258-365`). Highlighted while the popover is shown.
- `NSPopover`, transient, ~360×480, standard vibrancy; content is an `NSTableView` with sections:
  - **Now playing** — current track (art thumbnail, title, artist).
  - **Queued** — foobar playback-queue items, only if non-empty.
  - **Next from: <label>** — items after the playing index in the playing playlist (Now Playing normally). In playlist order; if shuffle/random order is active, a subtle note "Shuffle is on — order may differ".
  - Empty state: "Nothing up next".
- Interactions: double-click row → play it; drag to reorder (`playlist_reorder_items` on Now Playing); Delete / context "Remove"; "Clear" button removes upcoming items (not the current track). Reorder/remove only for Now Playing rows (rows from a non-Now-Playing playing playlist are read-only until copied by an action).
- Live refresh: `play_callback` (new track/stop — already in `PlayVancedCallbacks.mm:125-150`), `playlist_callback` (items added/removed/reordered, playing playlist changes), `playback_queue_callback`. Coalesce refreshes.

### 5. ShellVanced (new component `foo_jl_shellvanced_mac`)

- Scaffold with `Scripts/new-component.sh shellvanced "ShellVanced"` (read the script first — it touches `~/.local/bin` and zsh completions). Layout names: `ShellVanced`, `shellvanced`, `vanced_shell`.
- **Structure:** an `NSSplitView` with a source-list sidebar (min ~180, default ~220, collapsible) and a content container. Toolbar row at the top of the content area: back/forward buttons + current destination title.
- **Sidebar** (`NSOutlineView`, source-list style):
  - **Albums** (home, hosts AlbumViewVanced) fixed at the top.
  - **Your Library** header with filter chips **[Playlists] [Artists]** (none selected = both, like Spotify) and a + (new playlist).
  - Playlists: every playlist except Now Playing, with item counts. Selecting one → `set_active_playlist(idx)` and show the hosted SimPlaylist (shell mode). Context menu: Play (→ `playPlaylistIntoNowPlaying(idx, 0)`), Rename, Delete. Accepts track drops (suite pasteboard format + file URLs) to add to that playlist. Refreshes via `playlist_callback`.
- **Hosting:** enumerate `ui_element_mac` services, match by GUID (AlbumViewVanced, SimPlaylist), `instantiate` lazily on first visit with the arg dict, `unwrapNSObject` → `NSViewController`, add as child VC. Keep instances alive and swap visibility (Eole model). If a component isn't installed, show a placeholder "Install <name> to use this section".
- **History:** destinations = {albums, playlist(name), artist(name)}; back/forward stack; persist last destination and sidebar width in component config.
- **Risk to spike first:** enumerating and instantiating another component's `ui_element_mac` from inside a ui_element (no repo precedent). Also verify hosted controllers that register with singleton callback managers behave with exactly one instance and unregister on teardown.

New layout once ready:
```
splitter horizontal style=thin
 splitter vertical style=thin
  ShellVanced
 splitter vertical style=thin
  playvanced
```
(mirrors the current root structure; builder adjusts to whatever keeps PlayVanced as the bottom bar). Queue Manager, LibVanced and plorg leave the layout.

### 6. Artist browser (part of ShellVanced)

- **Shared pure helpers** `shared/ArtistNames.h`: `splitArtists(name)` (split on " vs ", " & ", " x ", " feat. ", " ft. ", ", "; parenthesised group names become extra parts; drop "Friends"), `isVariousArtists(name)` ("Various Artists", "VA", "V/A", case-insensitive), `artistKey(name)` (case/accent/punctuation-insensitive). Used by the shell index and AlbumViewVanced's artist filter so both agree.
- **Artist index** (shell): from the foobar library (`library_manager`), per track `%album artist%` (fallback `%artist%`), `%artist%`, `%album%`, `%date%`. Album artists → split → artists with owned albums; track artists on other albums → "appears on". VA excluded. Sorted A–Z by `artistKey`. Rebuilt (debounced) on library changes.
- **Sidebar rows:** 32 px round photo + name.
- **Artist page:** header (128 px round photo, name, "N albums · M tracks", **Play** = `playNow` of all the artist's tracks in album/track order with label "Next from: <artist>", **Shuffle** = same list shuffled) above the single hosted AlbumViewVanced instance with `setArtistFilter:`. Navigating back to Albums calls `setArtistFilter:nil`.
- **Photos:** Deezer `search/artist` (no key). Exact match on `artistKey`. If several exact candidates: fetch each candidate's `artist/{id}/albums` and accept only a candidate sharing a normalised album/track title with the user's library; if none confirms, use the fallback (never show a stranger's photo). Deezer's empty picture (URL containing `/images/artist//`) = no photo. Fallback: newest album's cover (album art of a track from it), cropped round. Disk cache under the user Caches directory (positive: image file; negative: JSON entry with 30-day TTL). ≤ 8 requests/s, fetch lazily for visible rows. Code to adapt (copy, not link): `extensions/foo_jl_biography_mac/src/API/DeezerClient.*`, `Core/ArtistImageCache.*`, `shared/RateLimiter.*`.

### 7. Keyboard shortcuts

Scoped to the foobar main window; ignored while a text field has focus (except ⌘ shortcuts).

| Keys | Action | Owner |
|---|---|---|
| ⌘F, ⌘L | Focus search of the current view | Shell (and AlbumViewVanced standalone) |
| Space | Play/pause | PlayVanced |
| ⌘→ / ⌘← | Next / previous track | PlayVanced |
| ⌘↑ / ⌘↓ | Volume up / down | PlayVanced |
| ⌘S / ⌘R | Toggle shuffle / cycle repeat | PlayVanced |
| ⌥⌘U | Toggle Up Next popover | PlayVanced |
| ⌘[ / ⌘] | Back / forward | Shell |
| ⌘1 | Go to Albums | Shell |
| ⌘N | New playlist (inline rename) | Shell |
| ⌃⌘S | Toggle sidebar | Shell |

PlayVanced uses a local `NSEvent` key-down monitor (so Space works whatever has focus); the shell overrides `performKeyEquivalent:`. The shell spike dumps foobar's runtime main-menu key equivalents to the console; any collision is resolved by picking another key before release.

### 8. GUID collision

Give Playback Controls and Tidal fresh GUIDs (keep plorg's, since it's in the user's layout). Note in their changelogs that existing layouts referencing them by GUID may need re-adding.

## Delivery (my calls)

- **Phasing:** §1–4 and §6 don't depend on the shell and are planned so they ship on their own. §5 starts with the hosting spike as a hard gate.
- **If the spike fails:** fall back to approach X — layout-only rearrangement with plorg as the left sidebar (plus a plorg option to hide "Now Playing"); revisit the `parentViewController` tab-switch hack only if the user wants click-to-switch.
- **Branch:** all work lands on the current `development` branch as one integration branch (cross-component change; per-component `dev/<name>` branches don't fit). Version bumps in `shared/version.h` for each changed component. No GitHub releases unless the user asks.
- **Live config:** the builder does **not** edit `~/Library/foobar2000-v2/UI-Layout.txt`. The new layout goes in `docs/shellvanced.md`; applying it (with a backup) is offered to the user at the end.

## Left to the builder

- Exact visuals (spacing, fonts, colors) following `shared/UIStyles.h` and existing component styling.
- Refresh coalescing strategy, table cell implementation, popover sizing details.
- Where per-component config keys live; naming of internal classes.
- Choosing the command-GUID vs. name approach for filtering foobar duplicates, after inspecting the context menu tree.

## Docs / housekeeping

- Per-component CHANGELOG + global CHANGELOG entries (compact style), README updates, `docs/shellvanced.md` with the new layout snippet, `docs/` note on hosting ui_elements from another component (SDK gotcha).
