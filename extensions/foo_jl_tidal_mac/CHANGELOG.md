# Changelog

All notable changes to TIDAL Integration will be documented in this file.

## [0.3.1] - 2026-06-17

LOSSLESS FLAC playback now works for LOSSLESS subscribers by default. The DASH segment parser was rewritten against `python-tidal`'s reference semantics, fixing three compounding bugs that previously made the v0.3.0 toggle produce a malformed fMP4.

### Added
- **LOSSLESS FLAC playback is now the default** for LOSSLESS subscribers. The preference checkbox is renamed to "Download LOSSLESS via DASH segments" and ticked by default. Untick to fall back to 320kbps HIGH AAC.
- Raw MPD manifest XML (truncated to 4 KB) is now logged to the foobar2000 console when DASH is enabled, so any future Tidal manifest change is easier to diagnose.

### Fixed
- **Segment count** is now derived from walking `<SegmentTimeline>` `<S r="N"/>` elements (`r` contributes `r ?: 1` segments, plus a base of 2 for init + first media). Previously computed from `mediaPresentationDuration / segmentDuration`, which undercounted whenever segments weren't uniform.
- **Init segment** is no longer downloaded separately. Tidal's URL scheme treats `media.replace($Number$, "0")` AS the init segment, so iterating `$Number$ = 0..(N-1)` against the media template gets the right URLs. Previously we downloaded `[initialization URL, media[1], media[2], …]`, producing a duplicated-init fMP4 that fb2k's MP4 demuxer couldn't read past the first few seconds.
- **FLAC content type** is now routed via `audio/x-flac` so fb2k picks the FLAC decoder. Previously hard-coded to `audio/mp4`, which routed to a generic MP4 demuxer that couldn't decode FLAC-in-MP4 reliably.
- **Codec normalisation** added for DASH manifests: `"flac"` → `FLAC`, `"mp4a.40.2"` / `"mp4a.40.5"` → `MP4A`, `"ec-3"` → `EAC3`, `"ac-4"` → `AC4`. Previously left as raw MPD strings, which the MIME-type picker didn't recognise.

### Out of scope
- HI_RES_LOSSLESS / MQA / Dolby Atmos still fall back to LOSSLESS — these use DASH too but may require AES-CTR decryption that is not implemented yet.

## [0.3.0] - 2026-05-17

Fixes the long-standing "playback stops until restart" cascade (aborted preloads were being reported as broken tracks), restores drag-drop to SimPlaylist, and unblocks Tidal column resizing in fb2k layouts. Adds token-state visibility in preferences, Year and Tracks columns in the album browser, and an experimental DASH toggle for true LOSSLESS.

### Added
- Album browser: Year and Tracks columns.
- Preferences: token status line with expiry countdown and last-refresh outcome.
- Preferences: experimental DASH toggle for true LOSSLESS (off by default, untested across account types).
- Stream-open diagnostics (host, file, size) and premature-EOF detection always logged.

### Fixed
- Playback cascade through the playlist on aborted preloads — decoder was converting `exception_aborted` into `exception_io_data`, so fb2k treated cancellations as track failures and advanced.
- Tidal browser column can now be resized freely (root view returns no intrinsic size; toolbar subviews yield to compression). See `docs/PANEL_COLUMN_RESIZING.md`.
- Drag-drop to SimPlaylist — each track's URL is emitted as `NSPasteboardTypeURL`, picked up by SimPlaylist's existing URL handler with no changes on its side.
- Reconnect button no longer hangs on "Reconnecting…" when the refresh succeeds.
- Refresh-token rotation honoured (new refresh tokens are stored, not just the old one).
- 401 auto-retry transparently refreshes the token before failing.

### Changed
- Quality-fallback log is unambiguous about silent API downgrades (e.g. requested LOSSLESS, got 320kbps).
- Refresh/token logs always visible regardless of debug-logging setting.

### Technical
- New `tidal::MemoryFile` (in-memory fb2k `file` impl) backs the DASH path.
- `TidalModels.mm` parses `SegmentTemplate` and ISO-8601 `mediaPresentationDuration` to compute segment count.
- New abort-aware `syncGET` / `downloadDASHSegments` helpers in `TidalInputDecoder.mm`.

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
