# Changelog

All notable changes to SimPlaylist will be documented in this file.

## [1.1.1] - 2025-12-29

### Fixed
- **Album art blinking during rapid scrolling**: Cache eviction no longer causes placeholder flicker

### Changed
- Increased album art cache from 200 to 500 images
- Batch image load completions with 50ms delay for smoother redraw

## [1.1.0] - 2025-12-28

### Added
- **Header Display Styles**: Four configurable header display modes
  - "Above tracks" (default) - Header row appears above track rows
  - "Album art aligned" - Header text aligned with album art left edge
  - "Inline" - Header row with album art starting at same Y position
  - "Under album art" - No header row, text drawn below album art
- **Subgroup Support**: Display disc numbers (Disc 1, Disc 2, etc.) within album groups
  - Configurable subgroup pattern (e.g., `[Disc %discnumber%]`)
  - "Show First Subgroup Header" option
  - "Hide subgroups if only one in album" option
- **Now Playing Highlight**: Optional yellow shading for currently playing track
- **Dim Parentheses Text**: Option to render text in `()` and `[]` with dimmed color
- **Preferences UI**: Reorganized into two sections
  - Grouping Settings (Preset, Header Pattern, Subgroup Pattern, Show First Subgroup, Hide Single Subgroup)
  - Display Settings (Header Display, Album Art Size, Now Playing Shading, Dim Parentheses)

### Fixed
- **Hidden tracks at end of multi-disc albums**: Tracks at the end of albums with disc subgroups were incorrectly classified as padding rows and not rendered
- **Subgroup detection showing disc headers mid-album**: Albums with inconsistent discnumber metadata no longer show spurious headers
- **Settings change losing scroll position**: Uses synchronous detection when scroll position exists
- **Extra padding for multi-subgroup albums**: Padding formula now subtracts subgroup count
- Header text now vertically centered in header rows (was bottom-aligned)
- Album art column no longer clips header text

### Changed
- **Performance**: O(1) caching for subgroup row lookups (was O(S) per lookup)
- **Performance**: Debounced text field changes (0.5s delay) to avoid rebuild on every keystroke
- **Performance**: Lightweight redraw for visual-only settings (Dim Parentheses, Now Playing Shading)
- Refactored subgroup detection into unified SubgroupDetector helper struct
- Install script clears macOS extended attributes to help invalidate dyld cache

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
