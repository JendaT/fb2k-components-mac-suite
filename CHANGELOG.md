# Changelog

All notable changes to foobar2000 macOS Components will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- Unified monorepo structure for all extensions
- Shared branding and about page utilities
- Shared preferences UI utilities for consistent styling
- Distribution packaging scripts

### Changed
- Preferences page titles now match foobar2000's built-in style (non-bold)
- Unified copyright notices across all extensions

---

## SimPlaylist

### [1.0.0] - 2025-12-26

#### Added
- Initial release
- Flat list view with virtual scrolling
- Album art display with grouping
- Keyboard navigation
- Selection sync with playlist manager
- Customizable grouping presets

---

## Playlist Organizer

### [1.0.0] - 2025-12-26

#### Added
- Initial release
- Hierarchical playlist organization with folders
- Drag and drop reordering
- Customizable node display formatting
- Automatic sync with playlist changes
- Based on foo_plorg by Holger Stenger

---

## Waveform Seekbar

### [1.0.0] - 2025-12-26

#### Added
- Initial release
- Complete waveform display with click-to-seek
- Stereo and mono display modes
- Multiple waveform styles: Solid, Heat map, Rainbow
- Cursor effects: Gradient, Glow, Scanline, Pulse, Trail, Shimmer
- BPM sync from ID3 tags
- Dark mode support
- SQLite waveform caching with compression

---

## Last.fm Scrobbler

### [1.0.0] - 2025-12-26

#### Added
- Initial release
- Automatic scrobbling after 50% or 4 minutes played
- Now Playing notifications
- Browser-based Last.fm authentication
- Offline queue with automatic retry
- Based on foo_scrobble for Windows by gix
