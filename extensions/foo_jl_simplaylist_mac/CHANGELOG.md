# Changelog

All notable changes to SimPlaylist will be documented in this file.

## [1.1.0] - 2025-12-27

### Added
- **Header Display Styles**: Three configurable header display modes
  - "Above tracks" - Header row appears above track rows with separator line
  - "Album art aligned" - Header text starts at left edge, aligned with album art
  - "Inline" - Compact header style with smaller text, no separator line
- **Now Playing Shading**: Optional yellow highlight for the currently playing track (configurable in preferences)
- **Subgroup Support**: Display disc numbers as subgroups within album groups
- **Preferences UI**: New settings in Preferences > Display > SimPlaylist
  - Header Display style selector
  - Highlight now playing row toggle

### Fixed
- Header text now vertically centered in header rows (was bottom-aligned)
- Album art column no longer clips header text in "album art aligned" mode
- Inline header mode now has proper header rows instead of overlapping tracks

### Changed
- Updated feature list in component About dialog
- Improved header row spacing for better visual separation from track rows

## [1.0.0] - 2025-12-22

### Initial Release
- Album grouping with cover art display
- Virtual scrolling for large playlists
- Keyboard navigation (arrows, page up/down, home/end)
- Selection sync with foobar2000 playlist manager
- Drag & drop track reordering
- Configurable album art size
- Click on album art to select all tracks in group
- Right-click context menu support
