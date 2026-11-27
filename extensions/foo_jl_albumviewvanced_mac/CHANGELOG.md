# Changelog

## [Unreleased]

### Added
- **Play / Play Next / Add to Queue**: Unified actions on albums and tracks; all playback goes through the single "Now Playing" up-next list.
- **Artist filter**: `setArtistFilter:` API shows an artist's albums plus an "Appears on" section (used by ShellVanced's artist page).
- **Search shortcuts**: ⌘F / ⌘L focus the search field.

### Changed
- **Context menu**: Replaces "Add to Now Playing" / "Add to Playback Queue" with the unified actions; duplicate foobar entries hidden.
- **Q key**: Adds the album or track to the end of the up-next list.

### Fixed
- **Stale rebuilds**: Older search results can no longer overwrite newer ones.
- **Arrow keys**: Select the first album when nothing is selected instead of jumping to the bottom.

## [1.0.0] - 2026-03-20

### Added
- Album grid view with cover art thumbnails
- Search/filter with foobar2000 library search syntax
- In-place track list expansion on album click
- Drag & drop to SimPlaylist and Queue Manager
- Context menu with playlist/queue actions
- Keyboard shortcuts (Q to queue, Enter to send to playlist)
- Dark mode support
