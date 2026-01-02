# Changelog

All notable changes to SimPlaylist will be documented in this file.

## [1.1.4] - 2026-01-02

### Fixed
- **Cross-playlist drag support**: Drag data now captures file paths at drag start - if active playlist changes mid-drag (e.g., spring-loaded folder preview), items are correctly moved to the new playlist (inserted and removed from source)
- **Cross-playlist drag with cloud files**: Now correctly handles non-local paths (mac-volume://, mixcloud://, etc.) by passing foobar2000 native paths directly
- **Multi-item drag not working**: Clicking on an already-selected item in a multi-selection no longer reduces selection to single item - all selected items are now dragged together
- **Folder drop file ordering**: Files from dropped folders are now sorted by path before inserting, ensuring correct track order
- **Focus not set on dropped items**: Focus ring now moves to first inserted item after external file drop
- **Delete focus behavior**: Cursor now moves to next item after delete (or previous if at end)
- **Focus ring appearing during drag**: No longer shows focus outline on random items while dragging
- **Focus ring appearing after drag**: Suppressed for 100ms after drag operation ends
- **Drop indicator jumping erratically**: Uses pure distance-based positioning at album boundaries
- **Items misplaced after drag to padding area**: Dragging to end-of-album padding now correctly places items at end instead of beginning
- **UI blink when deleting items**: Disabled Core Animation during playlist rebuild

### Technical
- Drag pasteboard now includes dictionary with sourcePlaylist, indices, and paths (Plorg updated for compatibility)

## [1.1.3] - 2025-12-30

### Fixed
- **Delete tracks not working**: Delete key now correctly removes selected tracks
- **Drag and drop reordering not working**: Internal track reordering now works properly
- **External file drop not working**: Dropping files from Finder now inserts at correct position

### Technical
- Sparse model stores playlist indices directly in selection, not row indices
- Removed dead node-based code paths that were silently failing

## [1.1.2] - 2025-12-29

### Fixed
- **Excessive spacing in style 4 (header under album art)**: Reduced gap between album groups by half

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
