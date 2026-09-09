# Changelog

All notable changes to Album Art (Extended) will be documented in this file.

## [1.1.0] - 2026-07-09

### Added
- **Fetch Missing Artwork**: right-click > "Fetch Missing..." searches online sources for album art
  - Sources: Cover Art Archive (via MusicBrainz), iTunes, Deezer, and TIDAL (optional, requires free developer credentials)
  - Footer shows live search progress with cancel, then thumbnail previews of the results
  - Lightbox preview with type filter tabs (Front/Back/Disc/...), keyboard navigation, and multi-type selection
  - Save selected images to the album folder (front.jpg, back.jpg, ...) with save-panel fallback for read-only folders
  - Embed artwork into the audio file tags via the foobar2000 SDK (MP3, FLAC, M4A, ...)
- Unit test suite for the remote-search core, gating every build (Scripts/run_tests.sh)

### Fixed
- Track paths containing spaces broke save-to-folder (foobar2000 "file://" paths are unencoded and were parsed with NSURL string parsing)
- Restarting a search could complete instantly with stale or missing results (provider completions from a cancelled search corrupted the new search)
- Thumbnails could be attached to the wrong search results while sources were still responding (cache was keyed by index into a re-sorted array)
- Clicking a footer thumbnail could open the wrong image in the lightbox
- First search after startup could falsely report "Network unavailable" (reachability now fails open until the first path update)
- "Fetch Missing..." was not actually disabled when offline (menu used automatic item enabling)
- Changing tracks now cancels an in-flight search and clears results from the previous album
- "Save Selected" could claim more images than it saved: every artwork type was pre-selected before its image data loaded, and unloaded ones were silently dropped (now only the viewed image is pre-selected and unloaded selections are pruned)
- The lightbox window leaked on every sheet presentation (endSheet without orderOut) and risked over-release on the modal path (releasedWhenClosed)
- Data race on MusicBrainz provider task cancellation when switching tracks rapidly
- Remembered "embed" save preference was silently ignored when saving multiple images at once
- Embed checkbox said "format not supported" when the actual problem was a read-only file
- "Reset Artwork Save Options" context-menu item added; previously a remembered save choice could never be reset from the UI
- Malformed MusicBrainz release-ID tags could crash the host (nil-URL exception) or inject a request path; the ID is now validated as a UUID before the Cover Art Archive request
- A remote result with a valid full-resolution URL but a nil thumbnail URL could crash thumbnail download and the lightbox (nil-URL exception)
- Non-UTF-8 text in an SDK embed exception could crash the error path; the message is now nil-safe
- Search-animation timer leaked the view (and its full-resolution image) if the panel was closed mid-search; the timer no longer retains the view and stops when the panel detaches
- Lightbox full-resolution image cache is now bounded (NSCache), so browsing many large covers no longer grows memory without limit
- Album-art view no longer rescales the full-resolution image on every search-animation tick and hover change (only redraws the actually-invalidated region)

### Technical
- Core split refactor for testability (matches SimPlaylist): SDK-dependent metadata extraction isolated in TrackMetadata+FB2K, remote-search Core is Foundation-only and compiles standalone
- RemoteArtworkSearchController now takes injected providers (default: CAA, iTunes, Deezer, TIDAL) and drops stale completions via a search generation counter
- Thumbnail downloads reuse a single NSURLSession instead of leaking one session per batch

## [1.0.2] - 2025-12-30

### Fixed
- Fixed layout compression when no album art is available by setting low content hugging and compression resistance priorities

## [1.0.1] - 2025-12-29

### Fixed
- Fixed layout issue where album art images could affect parent container width, causing column resizing when navigating between tracks

## [1.0.0] - 2025-12-28

### Initial Release
- **Multiple Artwork Types**: Support for all 5 artwork types
  - Front cover (default)
  - Back cover
  - Disc art
  - Icon/thumbnail
  - Artist photo
- **Selection-Based Display**: Shows artwork for selected track, falls back to now playing
- **Interactive Navigation**: Arrows on hover to cycle through available artwork types
- **Context Menu**: Right-click to quickly switch artwork type
- **Per-Instance Configuration**: Each panel remembers its selected type
- **Layout Parameters**: Set default type via layout config (e.g., `albumart_ext type=back`)
- **Dual Panel Support**: Display multiple artwork types side by side
- Native macOS rendering with proper scaling
- Dark mode support
