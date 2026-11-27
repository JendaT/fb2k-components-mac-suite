# ShellVanced

A Spotify-style shell element: a sidebar with "Your Library" (playlists and artists), a main page that hosts AlbumViewVanced or SimPlaylist, and back/forward navigation. Playback always goes through the single **Now Playing** up-next list (see `shared/UpNext.h`). PlayVanced's Up Next popover shows that list.

## Pages

| Page | Hosted element | Notes |
|------|----------------|-------|
| Albums | AlbumViewVanced | ⌘F / ⌘L focus its search field |
| Playlist | SimPlaylist with `vanced=1` | Selecting a playlist makes it the active playlist (SimPlaylist shows the active playlist) |
| Artist | AlbumViewVanced with `setArtistFilter:` + artist header | Header: artist photo (Deezer, optionally Spotify; or round album-cover fallback), counts, Play / Shuffle |

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

Sources, in order:

1. **Deezer** photo, when the match is unambiguous (single exact-name candidate, or the only candidate whose Deezer albums share at least two titles with your library, or one exact title of 6+ characters). A lone candidate with no title overlap is accepted only with at most 15 albums and an artist name of 5+ characters. Deezer's generic grey silhouette is detected and treated as "no photo". A picture that is really one of the artist's album covers (perceptual hash within 10 bits of any of up to 10 covers) is only a fallback.
2. **Spotify**, only if credentials are configured and only for artists with no usable Deezer photo or a cover-like one. Same exact-name rule and the same title-overlap verification, using the Spotify albums list (titles are compared locally). Largest image up to 640 px.
3. A cover-like Deezer picture, if any.
4. The newest album's cover, cropped round, then initials.

Setup (optional): Preferences > Display > **ShellVanced**. Create an app at developer.spotify.com/dashboard and paste its Client ID and Secret, **Test**, then **Save**. Both values live in the macOS Keychain (service `foo_jl_shellvanced.spotify`) and nowhere else. Saving clears Spotify misses and re-looks up artists without a photo.

Privacy and limits:

- Only artist names and Deezer/Spotify ids are sent; never track or album titles.
- Deezer: at most 8 requests per second. Spotify: a single serialized queue with at least 2 seconds between requests. On HTTP 429 the Retry-After time is saved in `spotify-block.json` and Spotify is skipped until it passes (affected artists are retried in a later session, not remembered as misses).
- Cache: `~/Library/Caches/foo_jl_shellvanced/artists/`. `*.jpg` are photos, `*.cl` are cover-like Deezer pictures kept as fallback (30 days). Misses are remembered for 30 days in `negative.json` (Spotify misses under `sp:` keys). The cache format is versioned (`format` file); a new version wipes photos once. Delete the folder to refetch.

## Implementation notes

- Hosting another component's element: [hosting-ui-elements.md](hosting-ui-elements.md).
- Playlists are tracked by name. Duplicate names resolve to the first match, and the sidebar refuses renames that would create one.
- Pure logic (`src/Core/ShellCore.h`, `src/Artists/*Core.h`) is unit-tested by `Scripts/run_tests.sh`, which gates every build.
