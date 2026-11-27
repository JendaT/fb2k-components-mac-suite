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

### Removed
- **Key dump**: Spike logging of foobar's main-menu shortcuts.
