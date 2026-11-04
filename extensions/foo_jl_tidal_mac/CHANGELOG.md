# Changelog

All notable changes to TIDAL Integration will be documented in this file.

## [Unreleased]

Adds a personal "Save to library" export into the music.hq folder layout, and DASH prefetch so lossless/hi-res tracks start without the ~3-4s, 50+ MB segment-download stall on every track change. Plus a testability refactor following the simplaylist 1.5.0 pattern: pure logic extracted into Foundation-only Core modules, covered by a standalone clang++ unit-test suite (425 checks across 11 binaries, run under ASan+UBSan) that now gates every build via `Scripts/run_tests.sh`. The refactor is behavior-preserving; parsing and policy code was extracted verbatim and pinned by tests.

### Added
- **Back keeps your place.** Every level of the browser -- search results, favourites, an artist's albums, a playlist -- is recorded when an album, artist or playlist is opened from it, and Back restores it as it was: the same rows and loaded pages, the scroll position and the selection, without refetching. Before, only "Go to Album" returned to the list it came from; every other Back reset the list to the top, and Back from an album to its artist fetched the artist's albums again. A newly opened level starts at the top, and no longer shows the previous list's rows while it loads. The clickable artist segment of the trail returns the same way.
- **Drag albums into a playlist.** Album rows (search results, favourite albums, an artist's albums) now drag as every track of each dragged album, album after album in the order the rows are listed and in album order within each. Track lists are fetched as soon as an album row is selected, so they are normally ready before the drop; a drop waits at most 10 s for any still on the way and reports albums that could not be loaded in the status line. Opening an album also records its list for later drags. New `Services/TidalAlbumTrackStore`. Untested in foobar2000. SimPlaylist 1.6.0 re-sorts every drop by album artist and album; the order across albums holds only with the SimPlaylist change that keeps TIDAL browser drops as dragged (dev/simplaylist, unreleased).
- **TIDAL lookup service for other components** (`shared/jl_tidal_api.h`, `jl_tidal_lookup`). Any component can ask what TIDAL's catalogue knows about a track -- BPM, musical key ("F#m", "Eb", "D Dorian") and the matched TIDAL track ID -- for local files as well as tidal:// entries. Local files match by ISRC tag when present, otherwise by an artist + title search that only accepts a result sharing an artist, with the same title (with or without TIDAL's version suffix) and a length within 2 s; each answer says which kind of match it was. `get_cached()` answers from the cache on any thread; `lookup()` queues on the main thread and answers through a reference-counted notify (`on_item`/`on_done`/`is_cancelled`). Lookups run one track at a time, so a bulk request never takes more than one of the API's four in-flight slots from browsing and playback; answers persist in the profile (`tidal_lookup_cache.plist`), "not found" for 30 days, "unavailable" (signed out, offline, rate limited) never. New pure `Core/TrackMatcher` (34 checks) and `Integration/TidalLookupService`. The track model now also parses `key`/`keyScale` and keeps the catalogue's fractional `bpm`. No consumer exists yet, so the service is untested end to end.
- **BPM tag** from the TIDAL catalogue's `bpm` field (rounded to a whole beat; absent or 0 writes nothing). Set on tidal:// entries and written into FLAC files saved with "Save to library" / "Save to folder..." (ffmpeg's MP4 muxer drops it on `.m4a` saves, as it already drops ISRC). Entries already in a playlist pick it up when played or on Reload info. Needs live validation that the v1 track response carries the field.
- **Go to Album** in the browser's track context menu opens the track's album. Back returns to the list it came from exactly as it was -- the search with its loaded pages, scroll position and the track selected, or the playlist, favourites or top tracks it was opened from.
- **Playlists can be played.** A playlist row in Library > Playlists now offers Play, Add to Playlist (with or without a pinned quality) and Queue, over every track in it; before, it offered only Import.
- **"Save to folder..."** next to "Save to library (music.hq)": asks for a destination and saves each album as `Artist [YYYY] Title` directly inside it, tagged and with its cover, skipping the genre collection, the artist level and the genre prompt. The picker reopens at the last folder used. Needs no library root, still behind the hidden download gate.
- **Hi-res tracks start playing while they download.** A DASH track used to play only once every segment had arrived: 53 MB took about 7 s, and a 245 MB 24/96 track 15.6 s, before the first sample, on every track the prefetch had not covered. FLAC DASH tracks are now remuxed on the fly from fragmented MP4 into a plain FLAC stream, which foobar2000's FLAC decoder starts on the first segment. Seeking before the download finishes waits for the rest of the track, then hands over to the MP4 demuxer; after that, seeking is instant as before. New pure `Core/FlacFromFmp4` (15 checks) and `Integration/TidalDashFlacFile`; the manifest parser now also reports the exact sample count, so the length is right from the first second. Needs live validation.
- **"Use TIDAL ReplayGain" preference** (default on). With foobar2000's ReplayGain processing enabled and a local library without ReplayGain tags, Tidal tracks played several dB quieter than everything around them. Turning it off removes Tidal's values from playback and clears those already stored on Tidal tracks in your playlists; turning it back on applies from the next track opened, and Reload info restores stored values.
- **Add to Playlist with Quality**: the browser context menu gains a submenu that pins a quality tier (Hi-Res Lossless down to Low) on the tracks or album being added. The pin travels in the entry URL as `tidal://track/<id>?q=<TIER>`, so it survives restarts, playlist saves and drags; the plain "Add to Playlist" keeps following the global preference at play time. A pin is a ceiling, not a guarantee: the usual fallback still applies when Tidal does not carry that tier. Stream cache entries are now keyed by track and requested quality so two pins of the same track cannot serve each other's stream.
- **Clickable drill-down trail**: an album opened from an artist shows "Artist › Album" with the artist as a clickable segment that jumps straight back to that artist's albums; the back chevron carries a tooltip naming its destination.
- **Browser status line**: New preference chooses what the Tidal browser shows when idle — nothing, email, or username (default: email, the previous behaviour).
- **Hidden library-download gate**: The "Save to library" feature (context menu and its Preferences section) is now off unless `tidal.TI_download_on` is set in the fb2k config store; see `docs/hidden-options.md`.
- **Save to library (music.hq).** Personal export feature: a "Save to library (music.hq)" playlist context-menu command downloads the selected tidal:// tracks into a configured library root using the music.hq layout (`[Genre Collection]/Artist/Artist [YYYY] Title/01 - Track.flac`, with `[Releases]` for artists without a folder and `[Compilations]` for VA albums). Genre assignment: an existing artist folder on disk pins the collection automatically; otherwise a remembered per-artist choice applies; otherwise a one-time picker prompts (choices persist). DASH FLAC streams are losslessly remuxed from fMP4 to tagged `.flac` via ffmpeg (stream copy; searched in `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin` — without ffmpeg the raw container is saved untagged as `.m4a`). Fetches `cover.jpg` (1280px, 640px fallback) per album folder, skips files that already exist, reuses the DASH prefetch cache (an already-prefetched track is not re-downloaded), and reports progress plus a final saved/skipped/failed summary to the console. Gated by the new Preferences > Library folder setting — unset (default) hides the menu entirely. New `Core/LibraryLayout` (pure naming/slot/sanitization/ffmpeg-args logic, 66 checks), `Integration/TidalLibrarySaver`, `Integration/TidalSaveMenu`. Runtime flow untested; needs a live save to validate.
- **DASH prefetch.** When a track starts playing, the next tidal:// track in the active playlist is resolved and its DASH segments are assembled in the background into an in-memory blob cache, so opening it is instant instead of stalling for the segment download. Sequential album/playlist playthrough is the target case; the first track picked is never prefetched, and shuffled orderings simply miss the cache. Cache is byte-capped (~320 MB, oldest-first eviction) and cleared on quit. New `Integration/TidalDashCache` (coalescing cache — a play open never double-downloads an in-flight prefetch), `Integration/TidalPrefetch` (play-callback trigger), and pure `Core/DashCachePolicy` (segment-URL generation + eviction, unit-tested).
- `Core/ManifestParser` — BTS/JSON + DASH MPD parsing, SegmentTimeline segment-count math, DRM detection, codec normalization (pins the v0.3.1 DASH semantics).
- `Core/StreamResolutionPolicy` — quality-fallback cascade and downgrade/fail decisions (403-only fallback, DASH acceptance gating, DRM handling).
- `Core/HTTPResponsePolicy` — HTTP status to action/error mapping (429 Retry-After parsing, single 401 refresh-retry, 403/404/5xx).
- `Core/TidalLog` — Foundation-only logging funnel with pluggable backend; fb2k console backend installed at component init.
- `Core/ResponseParser` — JSON to model parsing for all API responses: token/refresh responses (including refresh-token rotation), item lists, the favorites/playlist `item` wrapper, FOLDER filtering, exact-ISRC matching. Replaces 11 inline parsing loops in `JLTidalAPI`, which is now a thin transport.
- `Core/SyncPlanner` — playlist-sync planning: naming round-trip, folder-hierarchy path building, pull change decisions (create/update/unchanged via track-ID set diff), favorites/album rules, push skip and create/update decisions, push track-ID diff. `JLTidalSyncChange`/`JLTidalSyncReport` moved here; `TidalPlaylistSync` keeps orchestration only.
- `Core/BrowserLogic` + `Core/BrowserState.h` — browser panel decisions: the active-list matrix (which of tracks/albums/artists/playlists is shown per mode), pagination gate/threshold and offset/hasMore math, back-button routing, drill-down/root-mode transitions, mode-change no-op rules. The panel enums moved out of the Cocoa header; `JLTidalBrowserController` keeps state and forwards decisions.
- `Tests/` + `Scripts/run_tests.sh` — standalone test binaries (no XCTest, no Xcode) gating `build.sh`; suites for ManifestParser, both policies, URLUtils, TidalSession, StreamCache.

### Fixed
- **Remixes and other versions named in the browser and in saved files.** TIDAL keeps "Kasper Bjorke Remix", "Live", "Remastered" in a separate version field. Playlist tags already added it to the title, but the browser's Title column and "Save to library"/"Save to folder..." (file name and TITLE tag) used the bare title, so every track of a remix album read "Breakfast". All now use one rule, `JLTidalTrack.displayTitle`: "Title (Version)", without doubling a version the title already carries.
- **"Loading more..." stuck inside an album.** An album, artist or playlist opened from a search with more pages inherited that search's "more results" flag; scrolling to its end announced a load that never happened and left the message in the status line.
- **Opening a playlist showed at most its first 100 tracks**, and importing one at most 500, with nothing to say the rest were missing. Both now fetch every page. A playlist that lists tracks but comes back empty says so, and logs it, instead of reading as an empty playlist.
- **The next-track prefetch silently never ran.** Each of its early exits returned without a word, so a prefetch that never started looked exactly like one that missed. It now finds the playing track in the playing playlist when foobar2000's own position lookup gives up, takes the playback queue into account (a queued track is what plays next), and logs why whenever it skips. It also keys its blob on the resolved quality, which is what the decoder reads, and warms the track's metadata, which the decoder blocks on before it opens the stream.
- **Segments download four at a time.** One at a time, each ~700 KB request was bound by round-trip latency rather than bandwidth.
- **A cold track open cancels prefetches for a track that no longer comes next**, instead of competing with it for the same connections.
- **Returning to a just-skipped track no longer fails.** Its cancelled download was still registered, and the new open attached to it and received nothing.
- With debug logging on, every track open logs a timing line (resolve, metadata, stream, decoder), every assembly its size and duration, and every skipped prefetch its reason, so a gap between tracks can be attributed from the console.
- The request pacer no longer waits on the calling thread, so four slow requests can no longer stall the decoder or freeze the panel for the length of their timeouts.
- **A 401 no longer leaves a dead token looking healthy.** The refresh on the retry path answered "still valid" from a local clock check, so a server-invalidated token was re-sent unchanged and every request failed while Preferences reported the token fine. The retry now forces a refresh grant.
- **A transient refresh failure no longer costs the stored session.** Reconnect called sign-out on any failure, including offline, 5xx and 429, and killed the retry timer with it: the outage that made you click Reconnect was the outage that made the refresh fail, and recovery meant a full re-pairing. Refresh errors are now classified, and only the five terminal OAuth codes discard the tokens.
- **A failed startup refresh no longer needs an app restart.** Launching offline, or a hiccup inside the refresh window, parked the service with a valid refresh token but no retry armed, and everything answered "not authenticated" until foobar2000 was restarted. The session is kept, a retry is scheduled, and readiness is derived from the session rather than a parallel state enum.
- **Metadata failures no longer overwrite good tags.** The info reader returned success on abort, timeout and fetch errors, and foobar2000 committed the "Tidal Track <id>" placeholder it then wrote. It now throws, so "Reload info" while offline or rate-limited leaves existing tags alone.
- **Imports stop re-fetching metadata they already have.** A favourites pull of N tracks issued N authenticated requests for data the browser and sync engine held parsed in memory. List responses now seed the resolver's cache.
- **Region-locked and withdrawn tracks fail immediately** instead of costing a 404, or five playbackinfo requests down the quality cascade for a 403, on every play and every prefetch. `allowStreaming` and `streamReady` are parsed and checked first.
- **A 403 is no longer always "Subscription required".** The error body's `subStatus` and `userMessage` are parsed, so a geo-block or a quota reports itself, and only the subscription sub-status drives the quality cascade.
- **v1 mutations are form-encoded.** Favourites add, playlist create and playlist items add posted JSON, which these endpoints ignore; no other working client does this. Needs a live check.
- **ISRC matching uses the official filter endpoint** (`filter[isrc]` on openapi.tidal.com) instead of free-text search over a relevance ranking, where a real match ranked sixth was dropped and push silently omitted the track. Search remains a fallback.
- **A folder-fetch failure no longer proposes mass deletion.** It logged at debug level and substituted an empty folder list, which renamed every foldered playlist and made the planner propose Delete for each one. It is now fatal for the preview, like a failed playlist fetch.
- **Playlist deletion honours the lock.** The component's own sync lock refused the removal while the mapping was dropped anyway, so the Delete was re-proposed forever and push created a remote duplicate. The lock is lifted first and the return value is checked.
- **Pull reports its real outcome.** It announced "Pull complete" over still-empty playlists, and a second sync started inside that window could double every track. Apply now waits for every import, counts failures, and both sync buttons stay disabled until it finishes.
- **Push no longer leaves orphaned empty playlists.** A failed ETag probe after a successful create was swallowed, so the run reported success while an empty playlist sat on the account and the next push created another. The mapping is recorded as soon as the playlist exists, and the failure is reported.
- **A mid-track re-resolve resumes where playback was** instead of restarting at 0:00 while the position clock kept counting, and a seek that hits an expired URL re-resolves instead of failing the track.
- **Requests are paced and retried as a whole.** At most four are in flight at once, so a push no longer fans out one request per item into a rate limit.
- Artist discography includes EPs, singles and compilations, so an artist without a full album no longer reads as having none; album tracks paginate, so a box set past 100 tracks is no longer truncated.
- An error loading an artist's albums is shown as an error instead of "no albums", which previously fell through to top tracks where Back re-ran the same failing request and never escaped. Every drill-down completion now carries the stale-result guard search already had.
- Adding to a locked playlist or autoplaylist no longer silently does nothing and then "plays" a row that was never inserted.
- Artist and playlist thumbnails request a size the CDN actually serves (80x80 returns 403 for those), and a failed image is not re-requested on every scroll.
- Track metadata is wider: every credited artist, the edition suffix in the title, an explicit flag, and ReplayGain from both the catalogue and the stream, so TIDAL tracks sit at the same level as local files.
- Abandoned DASH downloads stop when nothing is waiting for them, instead of running to completion for every skipped track.
- Pasted tidal.com track links are normalised to internal URLs by a link resolver, and album, playlist and artist URLs are no longer admitted into playlists only to fail at play.
- Codec is read from BTS manifests, so a lossless stream is no longer exported to a `.m4a` container; the quality badge now reads `mediaMetadata.tags` in both directions; sample rates render as 44.1kHz rather than 44kHz.
- The sync map moved into the foobar2000 profile (it is migrated automatically), so it travels with a copied or restored profile instead of being silently lost and duplicating every playlist on the next push.
- Config reads use `tryGet`, so the guards around them are no longer dead code against a torn-down service, and in-flight requests are cancelled on quit.

### Changed
- **MQA (HI_RES) retired.** TIDAL removed MQA on 2024-07-24 and marks the value deprecated, so it is gone from the quality preference, the pin submenu and the fallback cascade; a stored MQA preference maps to Lossless. Responses that still report HI_RES are parsed normally.
- **A pinned quality was ignored for every track after the first.** The DASH blob cache was keyed by track alone while the stream cache above it was keyed by track and quality, and the prefetcher dropped the entry's `?q=` pin and resolved at the global preference. Since prefetch runs on every track change, the prefetched tier won for every pinned entry, while the metadata still reported the pin. Blobs are now keyed by track and resolved quality, and the prefetcher resolves at the tier the entry asks for. The same track-only lookup was also serving the library export.
- **Nothing was ever retried.** A 5xx, a 429, a dropped connection or one failed DASH segment each ended as `exception_io_data`, which foobar2000 reads as a broken file and skips, cascading across a playlist. GET and HEAD now retry up to three times at 500/1000/2000 ms for transport errors, 429 and 5xx, honouring `Retry-After` (previously parsed and used only in a log message) up to 8s. Mutations are never replayed. Individual DASH segments retry on the same rules, so one dropped GET no longer discards a nearly complete 50-75 MB assembly.
- **A 401 never actually refreshed the token.** The handler on the retry path answered "still valid" from a local clock check whenever the token had not locally expired, so the retry re-sent the very token the server had just rejected. Server-side invalidation (password change, sign out everywhere) left every request failing while Preferences reported the token healthy. The 401 path now forces a refresh grant.
- **Preview clips played as full tracks.** `assetPresentation` was sent on the request and never read back, so a tier-gated or unsubscribed track yielded a ~30s sample behind a seekbar built from the catalogue duration, cached for 15 minutes. Resolution now fails with the server's own `previewReason`, and the result is never cached. An absent field is treated as a preview.
- **Sync imports could write into the wrong playlist.** Pull apply handed async imports a playlist index and then deleted playlists in the same loop, shifting it; a rename on TIDAL produces exactly that Create-plus-Delete pair. Import targets are now pinned by playlist GUID and re-resolved on completion, dropping the tracks if the playlist is gone rather than appending them to a stranger. Browser imports use the same anchor.
- **Tracks shorter than about two DASH segments failed every time.** The segment-count formula added `r` instead of `r+1` per timeline entry and compensated with a fixed base, which is exact only when exactly one entry carries a repeat. With none it requested one URL too many and the 404 discarded the whole assembly; with two or more it requested too few and silently truncated the tail.
- Dolby Atmos editions no longer replace the stereo master: `immersiveaudio=false` is now sent on playbackinfo, which previously let TIDAL answer with an E-AC-3 or AC-4 asset labelled as low quality.
- Release dates are parsed and rendered in UTC throughout. A date was parsed in the local zone and read back in UTC, so east of Greenwich a 1 January release filed and displayed as the previous year.
- Stream resolution can no longer hang the decoder thread indefinitely; the wait is bounded at 45s like its siblings.
- **Long album titles pushed the back button off-screen.** The panel-narrowing pass drops every control's compression resistance, which let a long breadcrumb squeeze the chevron to zero width. The back button now has an explicit size and the current breadcrumb level truncates instead.
- **Back button skipped a level.** Opening an album from an artist and pressing back returned to the search results instead of that artist's albums, dropping the artist context. Back now steps one level: album tracks reached from an artist return to the artist's album list, and only a drill-down with no artist behind it collapses to the root.
- Decoder open failures are no longer silent: `open_for_decoding` now logs which decoder was selected and the exact exception before fb2k skips the track (previously the console showed "Found decoder, opening..." then nothing).
- Debug-logging preference is now honored after restart (the cached flag was previously only synced when the pref was toggled).
- Logging from static destructors can no longer touch torn-down fb2k services (console backend is dropped on component quit).
- **Playback failed with "Unsupported file format", intermittently across restarts.** Two causes: Tidal's signed CDN URLs end in `...mp4?token=...` and foobar2000 derives the extension from everything after the last dot, so the bogus extension broke both decoder selection and the decoder's own `is_our_path` re-check; and several inputs claim the same extension (foobar2000 registers both an "MP4 Demuxer" and an "MP4 Stream Demuxer") while only one accepts a given stream, so picking the first claimer worked or failed depending on input enumeration order, which varies per launch. Decoder candidates are now gathered by real extension, codec content type and known containers, and each is tried until one accepts the stream — the same fall-through fb2k's own `g_open_from_list` does. The accepting and rejecting inputs are logged by name.
- **Pull sync no longer truncates playlists at 200 tracks.** All sync fetches (user playlists, playlist tracks, favorite tracks/albums) paginate to completeness via a new pure `Core/PaginationPolicy` (10k-item ceiling), and the push diff now sees the full remote track list. Previously a >200-track TIDAL playlist was silently cut to 200 locally on every pull, and >50 playlists produced false delete proposals.
- **A failed remote fetch can no longer wipe a local playlist.** Per-collection fetch errors exclude that playlist from the sync plan and protect it from delete detection instead of diffing as "remote is empty"; a failed playlists-list fetch aborts the whole preview. Partial page sequences are never treated as complete.
- fb2k playlist state is now read only on the main thread in sync previews and ISRC resolution (previously touched from GCD/URLSession threads — crash/corruption risk); planning runs off-main on snapshots.
- Sync mapping state, error capture, and `saveMappings` are serialized on a dedicated queue; preview/push request bursts are bounded to 4 concurrent with per-ISRC dedupe (previously 50 playlists fired 50 simultaneous requests, inviting 429 storms).
- **Token refresh is single-flight.** Concurrent callers now queue and receive the real refresh result; previously they slept 1 second and guessed, causing spurious "not authenticated" playback failures on slow networks and duplicate refresh POSTs that could invalidate a rotated refresh-token family. Sign-out during an in-flight refresh discards the stale result (previously a refreshed session could resurrect after sign-out).
- Two crash fixes from review: nil dictionary key in push-sync apply when a playlist-create response is malformed; `std::string(NULL)` in the 403 re-open path for DASH tracks.
- Album art extractor caches raw cover data (16 MB) instead of re-downloading the same cover for every track of an album; library section loads gained the stale-response generation guard search already had; async art can no longer land on recycled table cells.
- Assorted robustness from a 3-round multi-perspective code review (58 fixes total): JSON type guards across API/models/parser, NSNull ID rejection, keychain failure logging, `TidalPlayNotify` leak fix, obsolete-API cleanup, dedupe of metadata overlay / album-add / sync handlers / OAuth bodies / quality mapping, dead code removal.

### Security
- Content IDs parsed from `tidal://` URLs are validated against type-specific allowlists (numeric for track/album/artist, UUID charset for playlists) before interpolation into authenticated API paths — blocks request forgery via crafted playlist entries with percent-encoded separators. Search and ISRC query values are strictly encoded (a malicious ISRC tag can no longer inject query parameters).
- Path traversal hardening: `.`/`..` filename components, user-entered collection names, and persisted genre-map values are sanitized before building library paths; ffmpeg metadata values are stripped of control characters.
- API request logging redacted to host+path (query strings can carry signed-URL tokens); DASH segment counts clamped at 10k and blob assembly aborts past 1 GB (manifest-bomb hardening).

### Technical
- `TidalModels`, `URLUtils`, and `StreamCache` no longer depend on the fb2k SDK (logging via `TidalLog`); the config-gated raw-MPD console dump moved from `JLTidalPlaybackInfo` to the stream resolver via a new `rawDASHManifest` diagnostic property.
- All planned extractions are complete; the only open backlog item is the runtime verification of the 96kbps quality-fallback report (decision logic is now unit-tested, the listen test remains).
- Auth layering reworked: `JLTidalAPI` no longer imports the auth service — token refresh is injected as a `tokenRefreshHandler` block, breaking the API/Services cycle. The auth service is the sole owner and writer of the session (`atomic readonly` on the API, private `SessionOwner` category); request paths snapshot the session once per request, fixing token/countryCode tearing.
- Test suite grown to 12 binaries / 450+ checks (new `PaginationPolicyTests`, ID-validation and sanitizer cases).

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
