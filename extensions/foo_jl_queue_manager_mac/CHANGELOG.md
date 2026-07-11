# Changelog

## [Unreleased]

### Added

- **Multi-row drag reorder**: dragging a multi-row selection now moves all selected rows as a contiguous block (previously only the first row moved, silently); `QueueReorderPlanner` generalized to multi-source moves with an exhaustive test sweep

### Fixed (review follow-ups)

- **Reorder debounce**: `isReorderingInProgress` was checked in a deferred block that always ran after the flag was cleared, so it never suppressed anything and every reorder triggered a redundant second full reload; the check now runs synchronously when the SDK callback arrives on the main thread
- **Reorder failure safety**: if an SDK call throws mid flush-and-readd, the flag is reset and the view reloaded instead of freezing updates permanently; queue items whose playlist reference went stale are re-added as orphans instead of pointing at wrong tracks
- **Drop validation**: SimPlaylist drops now reject payloads referencing a nonexistent playlist (forged pasteboard data or playlist deleted mid-drag)

### Changed

- **Testable Core extraction**: Pure logic moved into SDK-free Core units with standalone unit tests that gate every build (same pattern as SimPlaylist)
  - `QueueReorderPlanner`: drag-reorder move planning extracted from QueueManagerController (also removes a leftover dead loop in the drop handler)
  - `QueueFormatting`: duration and status bar text formatting extracted from QueueOperations and the controller
  - `QueueDropParser`: SimPlaylist drag payload decoding/validation extracted from the controller; malformed payloads are now rejected up front

### Fixed

- **Build**: Component failed to compile after shared UIStyles.h dropped `selectedBackgroundColorForGlass()`; QueueRowView now uses `selectedBackgroundColor()` like SimPlaylist
- **Code review cleanups**: duration formatting now rejects NaN/infinite/overflow track lengths (was undefined behavior); title-format error handling deduplicated into `queue_ops::formatItem`; orphan sentinel uses named constants; selection recoloring only visits instantiated rows; queue callback dispatch skips work when no views are registered; dead `setupKeyboardHandling` removed; magic numbers named

- **Column metadata**: `queue_config::kAvailableColumns` is now the single source of truth for column identifiers, titles, widths, and title formats; controller and item wrapper read from it instead of hardcoding copies
- **Component identity**: placeholder GUIDs replaced with real UUIDs (saved layouts re-match the element by name), component URL corrected, description no longer advertises unimplemented configurable columns
- **Removed**: dead `QueueHeaderView` class (controller uses native `NSTableHeaderView` since 1.1.2); queue-rebuild and playlist lookups moved from the controller into `queue_ops`

### Technical

- New `Tests/` suite (3300+ checks) compiled standalone with clang, run by `Scripts/run_tests.sh` as a gating phase in `Scripts/build.sh`

## [1.1.2] - 2026-02-09

### Changed

- **Native Table Header**: Switched from custom QueueHeaderView to native NSTableHeaderView for proper resize support
- **Column Resizing**: All column header dividers are now draggable; title column auto-flexes to fill available space

### Fixed

- **Column Resize**: Header columns can now be resized by dragging dividers (was blocked due to autoresizing style conflict)
- **SimPlaylist Drag/Drop**: Restored NSDictionary format handling for drops from SimPlaylist

## [1.1.0] - 2026-01-22

### Changed

- **Custom Header Bar**: Replaced NSTableHeaderView with standalone NSView header bar matching SimPlaylist's architecture
- **Glass/Vibrancy Refactor**: Uses shared UIStyles.h glass helpers (`createGlassContainer`, `configureScrollViewForGlass`, `configureTableViewForGlass`) instead of inline NSVisualEffectView setup
- **Selection Colors**: Glass-aware selection colors via `selectedBackgroundColorForGlass()`

### Fixed

- **Drag & Drop from SimPlaylist**: Updated pasteboard decoder to handle new NSDictionary format (sourcePlaylist, indices, paths)
- **Header Appearance**: Header now renders with correct dark appearance matching SimPlaylist

## [1.0.0] - 2025-12-29

Initial release of Queue Manager for foobar2000 macOS.

### Features

- **Queue Display**: Visual table view showing all items in the playback queue
  - Queue position (#), Artist - Title, and Duration columns
  - Live updates when queue changes

- **Queue Management**
  - Double-click to play item from queue
  - Delete/Backspace key to remove selected items
  - Multi-selection support

- **Drag & Drop**
  - Internal reordering within the queue
  - Drop from SimPlaylist to add tracks to queue

- **Visual Design**
  - Matches SimPlaylist appearance (row height, colors, selection style)
  - Glass/vibrancy background option (transparent mode)
  - Custom header styling
  - Status bar showing item count

- **Preferences**
  - Transparent background toggle (Preferences > Display > Queue Manager)

### Technical

- Uses `NSVisualEffectView` for glass effect
- Persists settings via `fb2k::configStore`
- Thread-safe callback handling with debounce support
