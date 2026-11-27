# ShellVanced

A Spotify-style shell element: a sidebar with "Your Library" (playlists and artists), a main page that hosts AlbumViewVanced or SimPlaylist, and back/forward navigation. Playback always goes through the single **Now Playing** up-next list (see `shared/UpNext.h`). PlayVanced's Up Next popover shows that list.

## Pages

| Page | Hosted element | Notes |
|------|----------------|-------|
| Albums | AlbumViewVanced | ⌘F / ⌘L focus its search field |
| Playlist | SimPlaylist with `vanced=1` | Selecting a playlist makes it the active playlist (SimPlaylist shows the active playlist) |
| Artist | AlbumViewVanced with `setArtistFilter:` + artist header | Header: Deezer photo (or round album-cover fallback), counts, Play / Shuffle |

Missing components show a placeholder instead of the page.

## Shortcuts

| Key | Action |
|-----|--------|
| ⌘F / ⌘L | Focus Albums search |
| ⌘[ / ⌘] | Back / forward |
| ⌘1 | Albums |
| ⌘N | New playlist (inline rename) |
| ⌃⌘S | Toggle sidebar |
| Space, ⌘←/→, ⌘↑/↓, ⌘S, ⌘R, ⌥⌘U | Playback shortcuts (PlayVanced) |

## Recommended layout

Replace `~/Library/foobar2000-v2/UI-Layout.txt` with this (back up the old one first). Queue Manager, LibVanced and Playlist Organizer are no longer needed in the layout.

```
splitter horizontal style=thin
 splitter vertical style=thin
  ShellVanced
 splitter vertical style=thin
  playvanced
```

Turn off **Playback follows cursor**. With it on, foobar plays from the focused playlist instead of Now Playing.

## Artist photos

- Only artist names and Deezer ids are sent, to `api.deezer.com`. Requests are limited to at most 8 per second and are made only when a photo is needed.
- A photo is accepted only when the match is unambiguous: a single exact-name candidate, or the only candidate whose Deezer albums share at least two titles with your library (or one exact title of 6 or more characters). Otherwise the newest album cover is shown, cropped round, and initials if there is no cover.
- Cache: `~/Library/Caches/foo_jl_shellvanced/artists/`. Misses are remembered for 30 days in `negative.json`. Delete the folder to refetch.

## Implementation notes

- Hosting another component's element: [hosting-ui-elements.md](hosting-ui-elements.md).
- Playlists are tracked by name. Duplicate names resolve to the first match, and the sidebar refuses renames that would create one.
- Pure logic (`src/Core/ShellCore.h`, `src/Artists/*Core.h`) is unit-tested by `Scripts/run_tests.sh`, which gates every build.
