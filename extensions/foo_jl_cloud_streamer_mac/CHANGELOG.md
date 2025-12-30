# Changelog

All notable changes to Cloud Streamer will be documented in this file.

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
