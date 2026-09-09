# Changelog

All notable changes to foo_jl_scrobble (Last.fm Scrobbler) will be documented in this file.

## [Unreleased]

### Changed
- Core logic extracted into pure, host-independent modules covered by a unit-test suite (~430 checks) that now gates every build, mirroring the SimPlaylist testable architecture: playback-to-scrobble state machine (PlaybackTracker), Last.fm request signing/parameter assembly (LastFmRequestBuilder), per-endpoint JSON parsing (LastFmResponseParser), submission error policy and backoff (ScrobblePolicy), queue/duplicate detection (ScrobbleQueueModel), streak cache validity (StreakValidity), streak discovery walk (StreakWalker), and widget layout geometry (WidgetLayoutMath). No functional change intended.
- Widget layout is now computed in a dedicated geometry pass consumed by both drawing and mouse hit-testing; previously rects were a side effect of drawing (style switches even forced a synchronous draw just to obtain them)

### Fixed
- Latent double-queue of an already-scrobbled track on playback stop (previously masked by cache duplicate detection)
- Streak inflated by one day when the user had not scrobbled today (yesterday was checked and counted twice during discovery)

### Technical
- Tests compile standalone with clang (no Xcode target) via Scripts/run_tests.sh; build.sh aborts if any test fails
- Duplicated local-midnight and ARGB color conversion helpers consolidated into single definitions

## [1.4.0] - 2026-05-17

### Added
- Scrobble Queue table in preferences with multi-select delete and confirmation

### Fixed
- Scrobbles lost for artists with `&`, `=`, `+`, `#` in name (e.g. Simon & Garfunkel) — contributed by [@Scannou](https://github.com/Scannou)
- Album art not appearing in Recent Tracks until view switch
- UI freeze during cache save (blocking disk I/O on main thread)
- Nil pointer crashes in image loading paths
- Double-scrobble on rapid track changes

### Changed
- Async album art downloads with NSCache (previously synchronous and unbounded)
- Hardened auth flow, keychain storage, and notification observers

## [1.3.0] - 2026-02-13

### Added
- Recent Tracks view mode showing scrobbled tracks list with album art and relative timestamps
- View mode switcher pill (Charts / Tracks) in widget header
- Track count selector (10 / 30 / 50) for recent tracks list
- Left/right arrow navigation to cycle between view modes
- Scrollable content area (trackpad/mouse wheel) for both tracks list and album grid
- Live Now Playing indicator: currently playing track appears instantly at top of tracks list (zero API calls)
- Auto-refresh on scrobble: tracks list refreshes 15 seconds after a scrobble, with debouncing for rapid skips

### Changed
- Content area now clips and scrolls when items exceed available space
- Scroll position resets automatically when switching view mode, period, type, or data

## [1.2.0] - 2026-02-01

### Added
- Artist image scraping from Last.fm website (API deprecated artist images in 2019)
- Track images via album artwork lookup using track.getInfo API
- Widget background customization in preferences (color picker)
- Glass background effect option (NSVisualEffectView)
- Reload button in widget header for manual refresh
- Rank display in tooltip for bubble view (#1, #2, etc.)

### Changed
- Footer is now sticky at bottom of widget
- Bubble view is vertically centered between header and footer
- Removed rank badges from bubble view (cleaner look, rank shown in tooltip)
- Scrobbled today count updates after each successful scrobble
- Error handling improved: partial failures show in footer instead of full-screen error

### Fixed
- Animation duplicate issue where items appeared both animated and at final positions
- Layout transitions now properly suppress drawing during animation

## [1.1.0] - 2025-12-30

### Added
- Stats widget for foobar2000 layout system
- Top albums grid display (weekly/monthly/all time)
- Top artists and tracks navigation (UI ready, API pending)
- Profile image and username display
- Scrobbled today counter
- Queue status indicator
- Album artwork loading with caching
- Click albums to open on Last.fm
- Click profile link to open user library on Last.fm
- Context menu for period selection and refresh

### Fixed
- Widget properly supports container column resizing

## [1.0.0] - 2025-12-26

### Added
- Initial release
- Last.fm authentication via web browser
- Automatic scrobbling after 50% or 4 minutes played
- Now Playing notifications
- Offline queue with automatic retry
- Preferences page for configuration
