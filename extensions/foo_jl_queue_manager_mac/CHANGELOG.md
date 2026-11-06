# Changelog

## [1.2.0] - 2026-10-02

### Added

- **Stop After Queue**: Stops playback when the last queued track finishes; toggle from Playback menu, context menu or preferences (off by default).
- **Stop only once**: Optional mode that turns Stop After Queue off after it stops playback.
- **Queue restore**: Queue is saved on quit and re-added on launch (on by default).
- **Context menu**: Right-click in Queue Manager for the Stop After Queue toggles.
- **Multi-row drag reorder**: Dragging several selected rows moves them together in order; previously only the first row moved.

### Fixed

- **Reorder flicker**: Each reorder no longer rebuilds the view and resets the selection twice.
- **Frozen view**: View no longer stops updating after a failed reorder.
- **Reorder after playlist edits**: Tracks whose source playlist changed are kept instead of lost.
- **Malformed drops**: Drops referencing a nonexistent playlist are rejected.
- **Duration display**: Malformed track lengths show `--:--` instead of garbage.
- **Build**: Compiles again after shared `UIStyles.h` dropped `selectedBackgroundColorForGlass()`.

### Changed

- **Requires macOS 12**: Built with Xcode 27, which cannot target macOS 11.
- **Column metadata**: `queue_config::kAvailableColumns` is the single source of truth.
- **Dead code**: Unused `QueueHeaderView` removed from the binary.
- **Component description**: No longer advertises configurable columns, which are not implemented yet.

### Technical

- **SDK-free Core units**: `QueueReorderPlanner`, `QueueFormatting`, `QueueDropParser`, `QueuePersistence` and `StopAfterQueuePolicy` compile and test standalone.
- **Test suite**: 3300+ checks run by `Scripts/run_tests.sh` gate every build.
- **queue_ops**: Queue rebuild and playlist lookups moved out of the controller.
- **Frozen GUIDs**: Component and preferences GUIDs documented as frozen; fb2k resolves saved layouts by GUID.

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
