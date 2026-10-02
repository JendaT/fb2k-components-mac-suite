# Changelog

## [1.2.0] - 2026-08-17

### Added

- **Multi-row drag reorder**: dragging a multi-row selection moves all selected rows as a contiguous block, preserving their relative order. Previously only the first row moved, silently.
- **Queue restored after restart**: the queue is saved on quit and re-added on the next launch; tracks keep their playlist position when it still holds the same track, otherwise they are re-added by location. On by default; toggle via "Restore queue after restart" in preferences.
- **Stop After Queue**: stops playback when the last queued track finishes instead of continuing in the playlist. Toggle from Playback > Stop After Queue, the new Queue Manager context menu, or preferences; off by default. Queuing more tracks or skipping past the last queued track cancels the pending stop. Optional one-shot mode ("Turn off after it stops playback once") switches it off after it stops playback.
- **Context menu**: right-click in Queue Manager for the Stop After Queue toggles (the view had no context menu before)

### Fixed

- **Double refresh on every reorder**: the reorder suppression flag was checked after it had already been cleared, so it never suppressed anything and each drag rebuilt the whole view twice (visible flicker, selection reset twice)
- **Frozen view after a failed reorder**: if the queue rebuild failed partway, updates stayed suppressed permanently and the view stopped tracking the queue; the reorder path is now failure-safe
- **Tracks lost on reorder after playlist edits**: queue entries whose source playlist reference went stale are re-added by handle instead of pointing at the wrong track
- **Rejected malformed drops**: drops carrying a nonexistent playlist reference (stale drag, or data from another app) are now rejected instead of being passed to the SDK
- **Duration display**: tracks reporting a malformed length (NaN, infinite, or absurdly large) show `--:--` instead of garbage; this was undefined behavior
- **Build**: restored compilation after shared `UIStyles.h` dropped `selectedBackgroundColorForGlass()`; selection now uses `selectedBackgroundColor()` like SimPlaylist

### Changed

- **Column metadata consolidated**: `queue_config::kAvailableColumns` is the single source of truth for column identifiers, titles, widths, and title formats; the controller and item wrapper read from it instead of keeping their own copies
- **Removed dead code**: the unused `QueueHeaderView` class (superseded by the native header in 1.1.2) no longer ships in the binary
- **Component description** no longer advertises configurable columns, which are not implemented yet

### Technical

- **Testable Core extraction** (same pattern as SimPlaylist): pure logic moved into SDK-free units that compile and test standalone
  - `QueueReorderPlanner` — drag-reorder move planning, generalized to multi-row moves
  - `QueueFormatting` — duration and status bar text
  - `QueueDropParser` — SimPlaylist drag payload decoding and validation
  - `QueuePersistence` — versioned, escape-safe text serialization of the saved queue
  - `StopAfterQueuePolicy` — Stop After Queue arm/cancel/one-shot decisions; `StopAfterQueue.mm` applies them to fb2k's stop-after-current flag and registers the Playback menu command
- New `Tests/` suite (3300+ checks, including an exhaustive reorder sweep against a naive simulation) compiled with bare clang by `Scripts/run_tests.sh`, gating every build via `Scripts/build.sh`
- Queue rebuild and playlist lookups moved out of the controller into `queue_ops`; internal cleanups (orphan sentinel constants, selection recoloring limited to instantiated rows, no-op callback dispatch skipped, named constants)
- Component and preferences GUIDs are documented as frozen — foobar2000 resolves saved layouts by element GUID

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
