# Changelog

All notable changes to Waveform Seekbar will be documented in this file.

## [1.2.0] - 2026-07-02

### Added
- Glass background option (Preferences > Display): translucent blur background using the same behind-window effect as SimPlaylist; toggles live without restart
- Background color wells now support transparency (alpha slider in the color panel); a translucent background acts as a tint over the glass blur
- "Preferences..." context menu item that opens the Waveform Seekbar preferences page directly

### Fixed
- Playback cursor updated only ~2x per second on longer tracks; redraw threshold is now pixel-based for smooth movement
- Animated cursor effects (Glow, Scanline, Pulse, Shimmer) now animate continuously instead of only on cursor movement
- Played-portion shading painted the opaque background color over the glass blur; it now uses a neutral translucent dim in glass mode
- Stale waveform scans no longer overwrite the current track's data on rapid track changes (generation counter)
- Race between concurrent cache store and lookup resolved (double-check under lock)
- Per-controller waveform listener removal; seekbar recovers cleanly when layout elements are recreated

### Technical
- SQLite cache uses prepared statements for all queries
- Construct-on-first-use singletons avoid static initialization order issues
- Listener callbacks invoked outside the lock to prevent deadlocks
- Position updates driven solely by the 60fps timer; removed redundant playback-time dispatch and verbose config logging

## [1.1.0] - 2025-12-29

### Added
- Context menu with right-click on waveform seekbar
- "Lock Width" option to prevent horizontal resizing
- "Lock Height" option to prevent vertical resizing
- Lock settings persist across application restarts

## [1.0.0] - 2025-12-28

### Added
- Initial release
- Complete waveform display with 2048 buckets per track
- Click-to-seek functionality
- Stereo and mono display modes
- Waveform styles: Solid (with gradient bands), HeatMap, Rainbow
- Cursor effects: None, Gradient, Glow, Scanline, Pulse, Trail, Shimmer
- BPM sync for cursor animations from ID3 tags
- Dark mode support with automatic appearance switching
- SQLite waveform cache with zlib compression
- Configurable cache size and retention
- Preferences panel for all settings
