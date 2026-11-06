# Changelog

All notable changes to TIDAL Integration will be documented in this file.

## [0.4.0] - 2026-11-06

Hi-res tracks start while they download and the next track is prefetched. The browser keeps your place on Back, drags whole albums and plays playlists. Adds BPM tags and a BPM/key lookup for other components. Requests retry instead of skipping tracks, and sync and sign-in got correctness fixes from a full code review.

### Added
- **Lossless by default**: LOSSLESS FLAC via DASH segments for LOSSLESS subscribers; untick the preference to fall back to 320 kbps AAC.*
- **Progressive hi-res playback**: FLAC DASH tracks are remuxed from fragmented MP4 on the fly and start on the first segment instead of after the whole 50-250 MB download.
- **Next-track prefetch**: The next track is assembled in the background while the current one plays, so it opens without a download stall; follows the playback queue, capped at ~320 MB, cleared on quit.
- **Back keeps your place**: Every browser level comes back as it was left (rows, loaded pages, scroll position, selection) without refetching.
- **Go to Album**: Track context menu opens the track's album; Back returns to the list it came from.
- **Drag albums**: Album rows drag as all their tracks, album after album in the listed order. SimPlaylist 1.6.0 still re-sorts drops by album artist and album.
- **Clickable trail**: An album opened from an artist shows "Artist › Album" with the artist clickable; the back button's tooltip names its destination.
- **Play playlists**: Playlist rows offer Play, Add to Playlist and Queue, not only Import.
- **Add to Playlist with Quality**: Context submenu pins a quality tier on added entries (`tidal://track/<id>?q=<TIER>`); the pin is stored with the playlist and still steps down when the tier is unavailable.
- **BPM tag**: From the TIDAL catalogue, on playlist entries and in saved FLAC files.
- **Lookup service**: `jl_tidal_lookup` (`shared/jl_tidal_api.h`) lets other components ask TIDAL for a track's BPM, key and track ID, for local files (by ISRC, else artist/title/length search) and tidal:// entries; one request at a time, answers cached in the profile.
- **ReplayGain preference**: "Use TIDAL ReplayGain" (default on); turn it off when a library without ReplayGain tags makes TIDAL tracks play quieter.
- **Status line preference**: The browser shows nothing, the email or the username when idle.
- **Save to library / Save to folder...**: Hidden by default (`tidal.TI_download_on`, see `docs/hidden-options.md`). Saves tracks as tagged FLAC with cover art, into the music.hq layout or one `Artist [YYYY] Title` folder per album in a folder you pick.
- **Component details**: A "?" button next to the preferences title shows the component file, version and layout element names, ready to copy.

### Changed
- **Requires macOS 12**: Built with Xcode 27, which cannot target macOS 11.
- **About**: Shows the layout element name (`tidal-browser`) and the preferences path; the copyright notice is replaced by the MIT license line.
- **Preferences title**: Same size as foobar2000's own page titles.
- **MQA retired**: HI_RES (MQA) is gone from the quality preference, pin menu and fallback cascade; a stored MQA preference maps to Lossless.
- **Track tags**: Every credited artist, the version in the title, the explicit flag, and ReplayGain from both catalogue and stream.
- **Artist discography**: Includes EPs, singles and compilations.
- **Sync map**: Moved into the foobar2000 profile (migrated automatically), so it travels with a copied profile.
- **Request pacing**: At most four requests in flight; the pacer no longer blocks the calling thread.
- **Debug timing**: With debug logging on, each track open logs its resolve, metadata, stream and decoder times, and each skipped prefetch its reason.

### Fixed
- **"Unsupported file format"**: Playback failed intermittently; the CDN URL's `?token=` broke extension detection and only the first input claiming the extension was tried. Every candidate is now tried until one accepts the stream.
- **Transient failures skipped tracks**: GET and HEAD retry up to three times (500/1000/2000 ms, honouring `Retry-After`) on network errors, 429 and 5xx; DASH segments retry individually.
- **Pinned quality ignored after the first track**: The prefetcher dropped the pin and its cache was keyed by track only.
- **Quality badge**: Shows the formats TIDAL actually holds; lossless is no longer exported as `.m4a`; 44.1kHz no longer reads 44kHz.
- **Token refresh**: A 401 forces a real refresh instead of re-sending the rejected token; refresh is single-flight; signing out during a refresh can no longer bring the session back.
- **Sign-in through outages**: A transient refresh failure keeps the stored session, and a failed startup refresh retries instead of needing a restart.
- **Preview clips**: Rejected instead of playing as full tracks.
- **Unavailable tracks**: Region-locked and withdrawn tracks fail at once; a 403 reports its real reason instead of always "Subscription required".
- **Atmos**: Atmos editions no longer replace the stereo master (`immersiveaudio=false`).
- **Short tracks**: Tracks shorter than about two DASH segments no longer fail.
- **Mid-track recovery**: A re-resolve resumes where playback was; a seek on an expired URL re-resolves instead of failing.
- **Track changes**: Segments download four at a time; abandoned downloads stop; a stale prefetch yields to the track being opened; returning to a just-skipped track works; stream resolution can no longer hang the decoder.
- **Remix and version names**: The browser and saved files show "Title (Version)" instead of the bare title.
- **Back button**: Steps back one level (album to the artist's albums) and stays visible with long album titles.
- **"Loading more..."**: No longer sticks in the status line inside an opened album.
- **Long playlists and albums**: Opening or importing a playlist loads every page instead of the first 100/500 tracks; albums past 100 tracks are complete.
- **Browser errors**: Shown as errors instead of empty results; late responses no longer overwrite a newer view; adds to a locked playlist report failure; artist and playlist art loads.
- **Metadata**: A failed fetch no longer overwrites good tags with placeholders; imports reuse list metadata instead of fetching per track.
- **Pasted links**: tidal.com track links are normalised; album, playlist and artist links are no longer added as tracks.
- **Release dates**: Parsed and shown in UTC, fixing the year shift east of Greenwich.
- **Sync data safety**: Pull no longer truncates at 200 tracks; a failed fetch can no longer wipe or delete a playlist; imports target playlists by GUID; deletion honours the lock.
- **Sync results**: Pull waits for its imports and reports the real outcome; push no longer leaves empty playlists.
- **Sync requests**: v1 writes are form-encoded; ISRC matching uses the official filter endpoint.
- **Crashes**: Nil key in push-sync apply; `std::string(NULL)` in the DASH 403 re-open path.
- **Logging**: Decoder open failures log the decoder and the exception; the debug-logging preference holds after restart.
- **Album art**: Cached per album instead of downloaded per track; async art no longer lands on recycled rows.
- **Review fixes**: 58 fixes from a three-round code review (JSON type guards, a leak, duplicated code, dead code).
- **DASH segments**: The segment count comes from the SegmentTimeline and segment 0 is the init segment; both had produced malformed fMP4.*
- **FLAC over DASH**: Routed to the FLAC decoder (`audio/x-flac`); DASH codecs normalised for flac, mp4a, ec-3 and ac-4.*

### Security
- **Content IDs**: IDs from `tidal://` URLs are validated per type before use in API paths; search and ISRC values are strictly encoded.
- **Library paths**: `.`/`..`, collection names and stored genre values are sanitized; ffmpeg tag values are stripped of control characters.
- **Logs and limits**: Request logs show host and path only; DASH segment counts and track size are capped.

### Technical
- **Pure Core modules** (no fb2k SDK): ManifestParser, StreamResolutionPolicy, HTTPResponsePolicy, ResponseParser, SyncPlanner, BrowserLogic, DashCachePolicy, PaginationPolicy, LibraryLayout, FlacFromFmp4, TrackMatcher, TidalLog.
- **Tests**: 14 standalone binaries, 607 checks, run under ASan and UBSan by `Scripts/run_tests.sh` on every build.
- **Auth layering**: Token refresh is injected into the API; the auth service is the only session owner; each request reads the session once.
- **Thread safety**: fb2k playlist state is read on the main thread only; config reads use `tryGet`; in-flight requests are cancelled on quit; nothing logs from static destructors.
- **Raw MPD logging**: With debug logging on, the DASH manifest XML is logged for diagnosis.*

\* Developed as 0.3.1, which was never published.

## [0.3.1] - developed 2026-06-17, never published (ships in 0.4.0)

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
