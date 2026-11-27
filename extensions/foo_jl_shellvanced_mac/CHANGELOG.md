# ShellVanced Changelog

## [0.1.0] - Unreleased

### Added
- **Scaffold**: Initial component with the `ShellVanced` layout element.
- **Element hosting**: Embeds AlbumViewVanced via its ui_element; shows a placeholder when it isn't installed.
- **Sidebar**: Source-list sidebar with Albums home, "Your Library" header, Playlists/Artists filter chips and playlist item counts (Now Playing hidden).
- **Playlists**: Select to open in SimPlaylist; + / ⌘N creates and renames inline; context menu Play, Rename, Delete; drop tracks or files to append.
- **Navigation**: Back/forward history, destination title bar, collapsible sidebar; last page, sidebar width and filter persist.
- **Artists**: Sidebar artist list with round photos; artist page with header (photo, counts, Play / Shuffle) over the artist's albums and "Appears on".
- **Artist photos**: Deezer lookup with strict same-name disambiguation; falls back to the newest album cover, then initials; cached on disk.
- **Shortcuts**: ⌘F/⌘L focus Albums search, ⌘[ / ⌘] back/forward, ⌘1 Albums, ⌘N new playlist, ⌃⌘S toggle sidebar.
- **Album page**: Clicking an album opens a Spotify-style page with its tracks; double-click a card to play.
- **Library search**: 🔍 in "Your Library" filters playlists and artists as you type.
- **Pinned Albums**: The Albums item stays above the scrolling library list.
- **Spotify photos**: Optional fallback for artists without a real Deezer photo; Client ID/Secret in Preferences → Display → ShellVanced (Keychain), paced and rate-limit aware.

### Removed
- **Key dump**: Spike logging of foobar's main-menu shortcuts.

### Fixed
- **Quit crash**: ⌘Q no longer crashes (playlist callback unregistered while foobar is still up).
- **Album editions**: Same-titled releases from different years no longer mix tracks; multi-disc albums play in disc order.
- **Artist names**: Case/accent variants merge (KiLLΔTK, Greek, Cyrillic); "ft"/"feat" and [ ] groups split correctly; names no longer truncate.
- **Artist photos**: Deezer placeholders and album covers posing as photos are rejected; same-name strangers need title or collaborator evidence; cover fallback tries several albums.
- **Search focus**: The library search field keeps focus while typing.
