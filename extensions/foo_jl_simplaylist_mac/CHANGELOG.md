# Changelog

All notable changes to SimPlaylist will be documented in this file.

## [1.5.0] - 2026-07-02

### Added
- **Focus Playing Now**: New context menu item (at the bottom) that selects the currently playing track and scrolls it to the center of the view, switching to its playlist first when needed. Disabled while nothing is playing.
- **Cover art from external volumes**: Album art now loads for tracks on external volumes, with smarter companion-file matching (by album/artist tags before conventional filenames). (thanks @Scannou, #27)

### Fixed
- **Per-playlist scroll position — full overhaul**: Every playlist now returns to exactly where you left it, pixel-for-pixel, when switching between playlists and across restarts. Previously the restore used minimal scrolling (the remembered track could land at the bottom edge, drifting the view by up to a full screen per switch), ungrouped playlists never saved their position at all, large playlists (over the group-cache limit) could be restored against a stale cached layout that walked the position down the playlist on every switch, and the final scroll before quitting was lost. Positions are now stored as (track, pixel offset) anchors per playlist, persisted independently of the group cache.
- **Stable selections**: Selection changes from foobar2000 (including Focus Playing Now and other components) could be silently ignored after clicking an already-selected track, leaving stale highlights in the view. Selection callbacks now always sync from foobar2000.
- **Playing column symbol**: Cached ">" indicator is cleared when a new track starts, so it no longer lingers on the previous track. (thanks @Scannou, #28)
- **Metadata broadcast after playlist refresh/switch**: Tag updates arriving right after a refresh or switch are reflected correctly. (thanks @Scannou, #25)
- **Cover art bleed-through**: A file-specific extractor prevents one album's embedded art from appearing on a neighboring group. (thanks @Scannou, #23)

### Changed
- **Codebase optimization and testability**: The core playlist logic (row geometry, selection math, drag-reorder planning, group detection) was extracted into pure, host-independent modules covered by a unit-test suite (~108k checks) that now gates every build. No functional change intended; verified by equivalence testing against the previous implementation.

Thanks to @Scannou for the pull requests and the field reports that drove the scroll-position debugging in this release.

## [1.4.6] - 2026-05-17

### Added
- **Cmd+Z / Cmd+Shift+Z**: Undo / redo the last playlist modification on the active playlist (useful for recovering after a Finder open replaces your playlist).
- **Finder open override**: New preference to control what happens when files are opened from Finder. Options: replace active playlist (default), append to active playlist, or send to a named playlist (defaults to "Inbox").
- **Pattern Help side panel**: Live preview and typo warnings for the Header / Subgroup title-format patterns. Preview resolves against the currently focused track in the active playlist. Catches common typos like `%albumartist%` (no space) → suggests `%album artist%`, `%year%` → `%date%`, etc.
- **Default preset fallback**: `Artist - album / cover` preset now uses `$if2(%album artist%,%artist%)` so it works for tracks that only have an artist tag, not album artist.
- **Scrollable preferences**: SimPlaylist preferences page now scrolls properly when the host window is shorter than the content.

### Fixed
- **Background metadata refresh**: When foobar2000 reads tags in the background (e.g., on first playback of a previously unanalyzed file), unresolved `?` rows now refresh immediately instead of requiring a playlist switch.
- **Title-format help text**: Updated to include `%album artist%` (with space), `%discnumber%`, conditional `[...]` brackets, and `$if2()` fallback with worked examples.

### Known issues
- The "Send to named playlist" Finder-open mode is functional but the target playlist picker UI is currently disabled (the popup is unresponsive in the preferences). The default target name "Inbox" is used; advanced users can change it via `kFinderOpenTargetPlaylist` in the config. Re-enable tracked in BACKLOG.md.

## [1.4.5] - 2026-04-29

### Added
- **Album duration in group header**: Optional checkbox in Display Settings appends total album duration to each group header (e.g. "Album Name  •  45:23").

### Fixed
- **Group refresh on track discovery**: Groups now rebuild as track metadata is resolved during import (e.g. tracks going from `?` to real album/artist values).
- **Column widths reset on layout resize**: Manually resized columns are no longer overwritten when adjacent UI panels (e.g. album art) are resized. Auto-resize now distributes remaining space proportionally instead of equally. (thanks @Scannou, #19)

## [1.4.4] - 2026-04-06

### Added
- **Queue # column**: Built-in column showing queue position for each track. Two display styles configurable in preferences: brackets `[1]` or system accent color.
- **Double-click preserves queue**: Playing a track via double-click no longer flushes the playback queue. Enabled by default; toggle in new Behavior preferences section.
- **Behavior preferences section**: New section with queue preservation toggle and queue display style popup.

### Fixed
- **Q key queues all selected tracks**: Previously only queued the focused track; now queues the entire selection.

## [1.4.3] - 2026-03-24

### Fixed
- **Space key**: Now toggles play/pause instead of track selection; starts playback when stopped. (thanks @sircoderin, #12)
- **Scroll rendering**: Tracks no longer appear blank when scrolling to albums outside the initial viewport. (thanks @sircoderin, #10)
- **Import sort order**: Tracks sorted by metadata (album artist, album, track number) instead of filename. (thanks @sircoderin, #8)

## [1.4.2] - 2026-03-08

### Added
- **Cmd+F opens playlist search**: Press Cmd+F while the playlist is focused to invoke foobar2000's search dialog.
- **Q key queues hovered track**: Press Q while hovering over a track to add it to the playback queue.

### Fixed
- **Unrendered strips at top/bottom when scrolling**: The last album group could appear partially blank when scrolled to the edge of the playlist. Clicking into the area would fix it. Caused by sub-pixel rounding in dirty rect calculations during scroll.
- **Album art and group headers leaking between playlists**: Switching from a playlist with album art to one without could show stale album art and phantom group headers from the previous playlist.
- **Search results not scrolling into view**: Finding a track via playlist search now scrolls to and focuses the result.
- **Playing wrong track from search**: Double-clicking a search result could play a track from the wrong playlist.

## [1.4.0] - 2026-02-10

### Added
- **Drag to Finder**: Drag tracks from SimPlaylist to Finder to copy files out. Default behavior is copy; a preference toggle enables move-by-default (hold OPT to copy).
- **Debug rendering diagnostics**: Optional overlay showing diagnostic info on blank/unmapped rows (red) or nil column values (orange). Enable in Display Settings preferences.

### Fixed
- **Album art cache eviction**: Replaced `NSCache` (which silently evicts under memory pressure) with a manual LRU dictionary. Album art no longer blinks or disappears during fast scrolling.
- **Stale subgroup caches on empty playlists**: Subgroup/padding caches are now cleared in all early-return paths of `rebuildFromPlaylist`, preventing stale data from a previous playlist.

## [1.3.4] - 2026-02-08

### Fixed
- **Blank rows appearing during scroll**: Rows could appear blank when scrolling into areas where group data had recently changed (e.g. after async group detection). Caused by NSScrollView's copy-on-scroll preserving stale pixels. Fixed by forcing a full visible-rect redraw after group data updates.

## [1.3.3] - 2026-02-07

### Fixed
- **Album art and group column misaligned with Group Header Spacing**: Group height calculation used track row height for all rows instead of accounting for taller header rows. Album art and group column backgrounds now use correct pixel height via `pixelHeightForGroup:` helper. Also fixed album art vertical offset to use header height for styles 0/1.
- **View jumps on auto-advance**: Scrolling no longer jumps dozens/hundreds of tracks back when a new track plays automatically in a long playlist. Metadata updates during playback no longer trigger a full rebuild. Also added scroll preservation in sync detection background continuation.
- **Enter key plays focused track**: Pressing Enter now correctly starts playback of the keyboard-focused track. Previously broken due to passing a playlist index where a row index was expected, and was restricted to flat mode only.

## [1.3.2] - 2026-02-03

### Added
- **Group Header Spacing setting**: Adjustable vertical spacing for group header rows
  - Compact: Same height as track rows, text centered
  - Normal: Slightly taller (+6px) for breathing room
  - Larger: Generous spacing (+12px) for visual separation

### Fixed
- **Glass background toggle**: No longer requires restart to take effect
- **Subgroup headers in style 3**: Now display before their tracks (was appearing after)
- **Memory safety**: Replaced unsafe `__weak` pointers in C++ containers with `NSHashTable`
- **Cache memory pressure**: Formatted values cache now has bounded size with proper eviction
- **Path traversal**: Playlist name sanitization prevents directory escape

### Performance
- **Album art cache**: Batch LRU eviction reduces lock contention during rapid scrolling
- **Subgroup iteration**: O(log n) binary search replaces O(n) linear scan

## [1.3.1] - 2026-01-26

### Fixed
- **Orphaned custom columns**: Renaming a custom column no longer causes it to become unmanageable
- Custom column renames now sync to visible columns list
- Orphaned columns (visible but without definition) are automatically cleaned up on startup

## [1.3.0] - 2026-01-13

### Added
- **Glass background option**: Transparent background using NSVisualEffectView (requires restart)
- **Custom Columns**: New preferences page (Display > SimPlaylist > Custom Columns) for user-defined columns with name, alignment, and title formatting pattern
- **Column menu overhaul**: Flat list of built-in columns, SDK columns from components, and custom columns sections
- **Shared UIStyles component**: Centralized styling for consistent look across components

### Changed
- Refactored to use shared UIStyles.h for colors and fonts
- Glass mode respects macOS accessibility setting (reduce transparency)
- "Edit Custom Columns..." menu item opens dedicated preferences page
- Playback statistics (Play Count, First/Last Played, etc.) now sourced from SDK only

### Fixed
- Album art blinking during fast scrolling (increased cache limits, always show placeholder while loading)

## [1.2.1] - 2026-01-11

### Changed
- Removed "Solid" option from Header Accent (too similar to selection color)

## [1.2.0] - 2026-01-11

### Added
- **Header Size setting**: Compact (22px) / Normal (28px) / Large (34px)
- **Header Accent setting**: None / Tinted - use system accent color for column header
- **URL drop support**: Accept URL drops from external sources (e.g., Cloud Browser)

### Changed
- Column header styling matches default foobar2000 playlist
- Focus ring uses system accent color (matches selection)

## [1.1.7] - 2026-01-06

### Fixed
- **Threading crash**: Selection sync now dispatches SDK calls on main queue (was causing autolayout crashes when default playlist view was also active)
- **Vertical text centering**: Track text now properly centered within row height

### Added
- **Row Size setting**: New preference to adjust row height and font size
  - Compact: 12pt font, 19px row
  - Normal: 13pt font, 22px row (default)
  - Large: 14pt font, 26px row
- **'#' column in column menu**: Track number column can now be toggled on/off via right-click header menu

### Changed
- Removed duplicate "Track no" column (use "#" instead)
- Existing "Track no" columns automatically filtered out on load

## [1.1.6] - 2026-01-03

### Fixed
- **Context menu crash on foobar2000 2.26+**: Removed dead code that incorrectly bridged C++ pointer as ObjC object, causing crash when Cocoa called retain on it

### Technical
- Bug only affected fb2k 2.26+ users (contextmenu_manager_v2 API)
- See docs/DEBUG_REPORT_2026-01-03_context_menu_crash.md for full analysis

## [1.1.5] - 2026-01-03

### Added
- **Option-key modifier for drag operations**: Hold Option to copy instead of move
  - Same playlist: Option+drag duplicates items
  - Cross playlist: Option+drag copies items (leaves source unchanged)
  - Default behavior (no modifier) moves items

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
