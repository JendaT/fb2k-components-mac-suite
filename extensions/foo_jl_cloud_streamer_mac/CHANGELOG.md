# Changelog

All notable changes to Cloud Streamer will be documented in this file.

## [0.2.0] - 2026-02-18

### Features
- Cloud Browser panel with search UI for browsing SoundCloud and Mixcloud
- SoundCloud search via yt-dlp (`scsearch`)
- Mixcloud search via native GraphQL API
- Service selector (segmented control) to switch between SoundCloud and Mixcloud
- Track artwork thumbnails with async loading
- Double-click or Enter to add and play tracks
- Drag-and-drop tracks to playlists
- Mixcloud tracklist fetching from GraphQL API (yt-dlp does not extract these)
- Embedded CUE sheet generation from Mixcloud tracklist sections
- Persisted search query and selected service across sessions

### Fixes
- Artist field for Mixcloud now shows uploader name, not tracklist artists
- Use internal URL scheme for drag-drop (routes correctly to input decoder)

## [0.1.0] - 2025-12-30

Initial experimental release.

### Features
- Stream Mixcloud and SoundCloud content directly in foobar2000
- Support for internal URL schemes (`mixcloud://`, `soundcloud://`)
- Support for web URLs (`https://mixcloud.com/...`, `https://soundcloud.com/...`)
- Automatic metadata extraction (title, artist, duration, thumbnail)
- Chapter/tracklist support for DJ sets (embedded CUE sheet)
- Stream URL caching with automatic expiry refresh
- Album art extraction and display
- Preferences page for yt-dlp path configuration

### Technical
- Uses yt-dlp for stream resolution and metadata extraction
- Async pipe reading to prevent deadlocks with large JSON output
- Robust URL parsing with malformed URL correction
- Metadata and thumbnail caching for fast playlist operations

### Requirements
- foobar2000 v2 for macOS
- yt-dlp installed (auto-detected from Homebrew or configurable path)
