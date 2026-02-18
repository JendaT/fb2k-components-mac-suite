# Changelog

All notable changes to TIDAL Integration will be documented in this file.

## [0.2.0] - 2026-02-13

### Added
- **Browser Panel**: Search tracks, albums, and artists with drag-drop, double-click playback, and context menus
- **Album/Artist Search**: Search type selector with drill-down navigation into albums and artist discographies
- **User Library & Favorites**: Browse favorite tracks, albums, artists, and playlists; add/remove favorites via context menu
- **Playlist Browsing**: Browse and drill-down into TIDAL playlists with track listing
- **Playlist Import**: "Import as New Playlist" context menu action creates foobar2000 playlists from TIDAL playlists/albums
- **Playlist Sync (Phase 5.3)**: Bidirectional pull/push sync between TIDAL and foobar2000 playlists with confirmation dialogs
- **Playlist Lock**: Synced TIDAL playlists are protected from accidental rename/delete
- **ISRC Track Matching**: Local tracks with ISRC metadata are matched to TIDAL equivalents during push sync
- **Enhanced Metadata**: ISRC, DATE, TOTALTRACKS, COPYRIGHT fields populated in track metadata
- **Search Pagination**: Infinite scroll for search results and library sections
- **Album Art Extractor**: Serves TIDAL cover art for `tidal://` URLs
- **Queue Manager Integration**: Drag-to-queue and "Queue" context menu support
- **Quality Badge Column**: Shows audio quality (HiFi/MQA/etc.) per track in search results
- **Reconnect Button**: Preferences shows Reconnect when OAuth token expires
- **Debounced Auto-Search**: 400ms debounce on keystrokes, no Enter required
- **Persistent Search State**: Remembers last query and search type across restarts
- **Quality Fallback Logging**: Diagnostic logging for DRM quality cascade

### Fixed
- Column display and reorder (artist-first layout, cell reuse, correct columns per search type)
- Search type switching now reconfigures columns correctly
- Artist drill-down falls back to top tracks when artist has 0 albums
- Album art and DATE metadata timeout increased (2s to 8s) with track-level releaseDate fallback
- Album art extractor GUID routing for SDK compatibility
- Back button uses compact SF Symbol chevron
- Drag-drop uses modern `pasteboardWriterForRow:` API (replaces deprecated API)

## [0.1.0] - 2026-02-11

### Added
- **OAuth Authentication**: Device code flow with PKCE, token refresh, secure storage
- **Playback**: Full `tidal://track/{id}` protocol handler with quality negotiation (HiFi, MQA, AAC fallback)
- **Preferences Page**: Account management, audio quality selection, connection status
- Shared UIStyles integration for consistent appearance
