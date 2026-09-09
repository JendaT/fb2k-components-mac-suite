# Playing-Playlist Guard (ReFacets playback hijack)

Added 2026-07-07 (post-1.5.0). Implementation: `src/Integration/PlaylistCallbacks.mm`
(`simplaylist_playing_playlist_guard` + `runPlayingPlaylistGuardCheck`), config key
`keep_playing_playlist` (default on), checkbox in preferences Behavior box.

## The problem

While music plays from a normal playlist, browsing the media library with the
built-in ReFacets viewer causes playback — the moment the current track ends —
to jump to the first track of the browsed selection, abandoning the playlist
the user was listening to. No native setting fixes this ("playback follows
cursor" etc. are unrelated). The Windows UI does not do this; the Mac ReFacets
integration does.

## Root cause: active vs playing playlist

foobar2000 tracks two independent playlist roles (`SDK/playlist.h:95-103`):

- **active playlist** — the one displayed/focused in the UI
  (`get_active_playlist` / `set_active_playlist`)
- **playing playlist** — "playlist from which items to be played are taken
  from" (`get_playing_playlist` / `set_playing_playlist`), i.e. where the next
  track is resolved when the current one ends

On the Mac, browsing a library viewer mirrors the selection into a hidden
auto-managed playlist ("Library Viewer Selection" — the name shows up in real
installs, e.g. old plorg config dumps) and redirects the *playing* playlist to
it. The current track keeps playing from the user's playlist, but continuation
resolves in the mirror.

The playback queue is a separate mechanism (`queue_*` APIs) and takes priority
over the playing playlist; the hijack affects what plays after the queue is
empty.

## SDK facts that shaped the design

- `set_playing_playlist(t_size)` is a base-interface pure virtual — available
  on the Mac SDK. `playlist_manager::reset_playing_playlist()` is a helper
  that sets it to the active playlist (`playlist.cpp:421`).
- **There is no callback for playing-playlist changes.** Neither
  `playlist_callback` nor `playlist_callback_single` has a flag for it
  (`playlist.h:594-618`, `653-670`). `play_callback` events are track-level
  only.
- `get_playing_item_location(&playlist, &index)` (`playlist.h:175`) still
  reports the playlist the current track is actually playing from, and is NOT
  affected by the redirect. So the hijack is detectable as a mismatch:
  `get_playing_playlist() != playing item's playlist`.
- Inside playlist callbacks only *read* playlist APIs may be called; state
  mutations (like `set_playing_playlist`) must be deferred (comment at
  `playlist.h:563`; also the `playback_control.h:5` race warning).
- `playlist_callback_single_impl_base` (what SimPlaylist's main callback uses)
  only reports the active playlist. Watching the hidden mirror playlist
  requires the multi-playlist `playlist_callback_impl_base`.

## Guard design

- A global `playlist_callback_impl_base` watches `on_items_added/removed/
  replaced` across **all** playlists. ReFacets rewrites the mirror playlist on
  every selection change, so browsing generates these events. Each event
  schedules a coalesced check on the main queue (deferred → allowed to mutate
  state).
- Check logic: if playing, and `get_playing_item_location` succeeds, and
  `get_playing_playlist()` differs from the item's playlist → restore with
  `set_playing_playlist(itemPlaylist)` and log to console. Config is read only
  after a mismatch is found, keeping the common path free of configStore hits.
- A 2s `NSTimer` backstops redirects that don't touch playlist contents
  (e.g. re-clicking the same ReFacets row). Cost is a few in-process virtual
  calls per tick; the not-playing early-out is first.
- The guard repairs **any** mismatch, not just a name-matched "Library Viewer
  Selection" thief — the mirror's name is not guaranteed, and no legitimate
  Mac UI action produces a mismatch without starting playback (starting
  playback moves the playing item's location too, which clears the mismatch).

## Why deliberate ReFacets playback still works

Double-clicking a track in ReFacets starts playback *from* the mirror
playlist, so the playing item's location and the playing playlist agree — the
guard stays idle. Continued browsing after that eventually removes the playing
item from the mirror, making `get_playing_item_location` return false — the
guard also stays idle, preserving stock behavior for play-from-browser
sessions.
