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

### [Unreleased]

#### Fixed
- Home key jumped to an arbitrary point mid-list instead of the first track in grouped playlists (End was wrong the same way but masked by clamping)
- An album cover too large to cache was re-decoded on every redraw, on up to four threads, for as long as it was on screen
- Invalid grouping patterns previewed as the track's filename instead of reporting themselves as invalid
- An out-of-range stored preset index left the preferences page showing blank pattern fields and silently discarding every edit
- Typing a grouping pattern compiled and ran it on the main thread on every keystroke; leaving the field rebuilt the playlist twice
- Column headers scrolled behind the album-art strip remained clickable, draggable and resizable
- Custom column edits could be reverted by a stale copy held by the preferences page
- Shift-click after a playlist switch extended the selection from the previous playlist's anchor
- Drop indicator appeared up to ~150 px below the cursor when dragging into grouped playlists, and the drop landed at the indicator — drop positions were scored against uniform row heights that ignored taller group headers
- Delete/Backspace with an empty selection hung the app
- With multiple SimPlaylist panels open, one panel's rebuild cancelled another's in-progress group detection
- Album art cache is now bounded by decoded size (256 MB) as well as image count, which previously allowed ~1 GB resident
- Assorted crash guards and correctness fixes from a multi-pass code review

#### Changed
- Removed ~1,100 lines of unreferenced legacy rendering code (node/boundary drawing, disabled flat mode, `GroupNode`/`GroupBoundary`)
- Unified the group-data application sequence that was duplicated across five call sites and had drifted between copies

### [1.5.1] - 2026-07-07

#### Added
- "Keep playback in its playlist" behavior option (default on) — prevents ReFacets library browsing from redirecting playback continuation; finishing a track no longer jumps playback to the browsed selection

### [1.5.0] - 2026-07-02

#### Added
- "Focus Playing Now" context menu item — selects the playing track and scrolls it to the center of the view, switching playlists when needed
- Cover art for tracks on external volumes with smarter companion-file matching (thanks @Scannou, #27)

#### Fixed
- Per-playlist scroll positions restore pixel-exactly across playlist switches and restarts (previously drifted by up to a full screen per round trip; ungrouped and very large playlists never saved their position at all)
- Stale selections: external selection changes are no longer silently ignored after clicking an already-selected track
- Playing column ">" no longer lingers on the previous track (thanks @Scannou, #28)
- Metadata broadcast after playlist refresh/switch (thanks @Scannou, #25)
- Cover art bleed-through between neighboring albums (thanks @Scannou, #23)

#### Changed
- Core playlist logic extracted into pure, unit-tested modules (~108k checks gating every build); codebase optimization and testability, no functional change intended

### [1.4.6] - 2026-05-17

#### Added
- Cmd+Z / Cmd+Shift+Z undo/redo for playlist modifications
- Finder open override (replace / append / send to named playlist)
- Pattern Help side panel with live preview and typo warnings
- Scrollable preferences page

#### Fixed
- Background metadata refresh: `?` rows now resolve immediately after foobar2000 reads tags
- Default preset uses `$if2(%album artist%,%artist%)` fallback
- Improved title-format help text with worked examples

### [1.4.5] - 2026-04-29

#### Added
- Optional album duration appended to group headers (toggle in Display Settings)

#### Fixed
- Groups now refresh as track metadata is resolved during import
- Column widths no longer reset when adjacent UI panels are resized; auto-resize distributes space proportionally (thanks @Scannou, #19)

### [1.4.4] - 2026-04-06

#### Added
- Queue # column showing queue position per track (brackets or accent color style)
- Double-click preserves playback queue (enabled by default)
- Behavior preferences section

#### Fixed
- Q key now queues all selected tracks, not just the focused one

### [1.4.3] - 2026-03-24

#### Fixed
- **Space key**: Now toggles play/pause instead of track selection; starts playback when stopped.
- **Scroll rendering**: Tracks no longer appear blank when scrolling to albums outside the initial viewport.
- **Import sort order**: Tracks sorted by metadata (album artist, album, track number) instead of filename.

### [1.4.0] - 2026-02-10

#### Added
- Drag tracks from SimPlaylist to Finder to copy files out (preference toggle for move-by-default)
- Debug rendering diagnostics overlay for blank/unmapped rows

#### Fixed
- Album art cache eviction: replaced NSCache with manual LRU dictionary to prevent blink/disappear during fast scrolling
- Stale subgroup caches on empty playlists

### [1.3.4] - 2026-02-08

#### Fixed
- Blank rows appearing during scroll due to NSScrollView copy-on-scroll preserving stale pixels after group data changes

### [1.3.3] - 2026-02-07

#### Fixed
- Album art and group column misaligned with Group Header Spacing (incorrect height calculation for header rows)
- View jumps on auto-advance in long playlists (metadata updates no longer trigger full rebuild)
- Enter key now correctly plays focused track

### [1.3.2] - 2026-02-03

#### Added
- Group Header Spacing setting: Compact / Normal (+6px) / Larger (+12px)

#### Fixed
- Glass background toggle no longer requires restart
- Subgroup headers in style 3 now display before their tracks
- Memory safety: replaced unsafe `__weak` pointers in C++ containers with NSHashTable
- Cache memory pressure: bounded formatted values cache with proper eviction
- Path traversal: playlist name sanitization prevents directory escape

### [1.3.1] - 2026-01-26

#### Fixed
- Orphaned custom columns: renaming a custom column no longer causes it to become unmanageable
- Orphaned columns automatically cleaned up on startup

### [1.3.0] - 2026-01-13

#### Added
- Glass background option (transparent background using NSVisualEffectView)
- Custom Columns preferences page with user-defined columns
- Column menu overhaul: built-in, SDK, and custom column sections
- Shared UIStyles component for centralized styling

#### Changed
- Refactored to use shared UIStyles.h for colors and fonts
- Playback statistics now sourced from SDK only

#### Fixed
- Album art blinking during fast scrolling

### [1.2.1] - 2026-01-11

#### Changed
- Removed "Solid" option from Header Accent (too similar to selection color)

### [1.2.0] - 2026-01-11

#### Added
- Header Size setting: Compact (22px) / Normal (28px) / Large (34px)
- Header Accent setting: None / Tinted
- URL drop support from external sources

#### Changed
- Column header styling matches default foobar2000 playlist
- Focus ring uses system accent color

### [1.1.7] - 2026-01-06

#### Fixed
- Threading crash: selection sync now dispatches SDK calls on main queue
- Vertical text centering within row height

#### Added
- Row Size setting: Compact / Normal / Large
- '#' column toggle in column menu

### [1.1.6] - 2026-01-03

#### Fixed
- Context menu crash on foobar2000 2.26+ (incorrect C++ to ObjC pointer bridge)

### [1.1.5] - 2026-01-03

#### Added
- Option-key modifier for drag operations: hold Option to copy instead of move

### [1.1.4] - 2026-01-02

#### Fixed
- Cross-playlist drag support with true move behavior
- Cloud file paths (mac-volume://, mixcloud://, etc.)
- Multi-item drag, folder drop ordering, focus after drop/delete
- Drop indicator jumping, items misplaced in padding area
- UI blink when deleting items

### [1.1.3] - 2025-12-30

#### Fixed
- Delete tracks, drag and drop reordering, and external file drop now work correctly

### [1.1.2] - 2025-12-29

#### Fixed
- Excessive spacing in style 4 (header under album art)

### [1.1.1] - 2025-12-29

#### Fixed
- Album art blinking during rapid scrolling (cache eviction)

#### Changed
- Increased album art cache from 200 to 500 images

### [1.1.0] - 2025-12-28

#### Added
- Header Display Styles: four configurable modes (above tracks, art-aligned, inline, under art)
- Subgroup Support: disc numbers within album groups
- Now Playing Highlight (yellow shading)
- Dim Parentheses Text option
- Reorganized Preferences UI

#### Fixed
- Hidden tracks at end of multi-disc albums
- Subgroup detection showing disc headers mid-album
- Settings change losing scroll position

### [1.0.0] - 2025-12-22

#### Added
- Initial release
- Album grouping with cover art display
- Virtual scrolling for large playlists
- Keyboard navigation, selection sync, drag & drop
- Configurable album art size and context menu support

---

## Playlist Organizer

### [1.5.0] - Unreleased

> Not yet end-to-end verified. Committed for tracking and ongoing test.

#### Added
- **Automatic Volume UUID Sync**: headless service that auto-repairs stale `mac-volume://` UUIDs in `.fplite` playlists caused by SMB / Tailscale remounts assigning fresh ephemeral UUIDs
- Bookmark-based discovery via foobar's `config.sqlite` (handles SMB shares where macOS UUID APIs return null)
- Startup hook (`initquit::on_init`) plus runtime `/Volumes` VNODE monitor for mid-session mount changes
- Atomic `.fplite` rewrite with UTF-8 BOM preservation and timestamped backups (5 retained)
- Opt-in auto-restart prompt with detached shell helper for clean relaunch
- Background metadb cache migration: moves cached metadata rows from dead UUIDs into live ones across `metadb` and `metadb_index_*` tables (transactional, backup before writing, waits for exclusive DB access); also scans for orphan caches on each startup
- **Volume self-heal**: when a volume is mounted but foobar2000 has no working bookmark for it, plorg resolves one real file through the core so it mints a fresh bookmark, then remaps stale playlists automatically; one-click registration prompt as fallback (preference, default on)
- `Scripts/metadb_cleanup.sh`: offline tool to delete dead-UUID metadata copies and VACUUM the metadb (backup + integrity check; refuses to run while foobar2000 is running)
- Documentation: `docs/research/volume-uuid-instability-deep-research.md`

#### Changed
- Testable-core refactor (simplaylist pattern): pure logic extracted into Foundation-only Core modules (`PathCodec`, `TreeYamlCodec`, `TreeOps`, `VolumeSyncLogic`) with standalone clang unit tests gating every build; deduplicates YAML parsing and fplite scan/remap loops across UI controllers

#### Fixed
- Manual UUID remapping tool now preserves the UTF-8 BOM when rewriting `.fplite` files (shares the remap implementation with the automatic sync)
- Volume sync outcome log reports the real result (stale-but-unrepairable vs genuinely all-live) and detects "mounted but unregistered in foobar2000" instead of advising to mount an already-mounted volume
- `/Volumes` monitor coalesces event bursts into a single repair (previously up to 4 redundant registry scans per mount event storm)
- Strict volume-UUID validation and SQL escaping in the metadb migration builder
- Migrator index-table discovery no longer matches the `metadb_indexes` metadata table (SQL `LIKE` `_` wildcard bug); GLOB + strict shape validation
- Restart no longer races the metadb migration: relauncher waits for the migration to finish before reopening foobar2000 (was: "database is locked" + interrupted migration)
- Three-pass code review hardening: malformed-input crash fixes (FTH/DBPL/YAML parsers), path-traversal rejection in `.fplite` sample paths, manual remap target-UUID validation, read-only opens for Vox/Strawberry import databases, backup-before-delete for corrupted-playlist removal, locale-pinned backup timestamps, corrected delete-folder dialog text, build script no longer masks project-generation failures
- Fourth review pass: metadb migration no longer deletes lower-case-UUID rows instead of migrating them (case-insensitive LIKE vs case-sensitive REPLACE); registry volume paths normalized so trailing-slash/Unicode variants match; Vox-import and SimPlaylist-drag crash fixes; Repair Volume UUIDs window no longer leaks or dead-locks its UI on title-bar close or backup failure; dead public API removed and main-thread contracts documented

### [1.4.0] - 2026-02-14

#### Added
- FTH Theme Import: import playlist tree structure and tracks from old Windows foo_plorg theme files, with Windows-to-macOS path mapping
- Corrupted Playlist Detection: file-based corruption checks plus crash-marker system for SDK-level crashers; safe filesystem-based removal; preference and "Check Now" button

#### Fixed
- Nil safety in path encoding prevents crash on nil tree node names
- Import exception handling resets view state on failure
- Playlist item count access skipped for known-bad playlists to prevent startup crashes

### [1.3.2] - 2026-01-15

#### Added
- Network Volume UUID Remapping tool: manual repair window for orphaned playlist entries; scans for `mac-volume://` references, detects current UUID for mounted volumes, backs up before applying

### [1.3.0] - 2026-01-03

#### Added
- Drag-hover-expand: hover over folders to auto-expand, hover over playlists to activate them
- Accept track drops from SimPlaylist onto playlists (appends to end)
- Playlist item count updates immediately after drop
- Option key modifier: hold Option during drag for Copy operation (default is Move)

### [1.2.0] - 2025-12-30

#### Added
- Transparent background option (glass effect, requires restart)

### [1.1.0] - 2025-12-28

#### Added
- Tree Lines Display: optional Windows Explorer-style tree connection lines

### [1.0.0] - 2025-12-22

#### Added
- Initial release
- Hierarchical playlist organization with folders
- Drag & drop reordering
- Customizable node display formatting with title formatting syntax
- Auto-sync with foobar2000 playlist changes
- YAML configuration storage with import/export

---

## Waveform Seekbar

### [1.2.0] - 2026-07-02

#### Added
- Glass background option: translucent blur background, same effect as SimPlaylist; toggles live without restart
- Background color wells support transparency; translucent background tints the glass blur
- "Preferences..." context menu item opens the seekbar preferences page directly

#### Fixed
- Choppy playback cursor movement (redraw threshold now pixel-based, animated cursor effects redraw continuously)
- Played-portion shading no longer paints the opaque background color over the glass blur
- Stale waveform scans no longer overwrite the current track on rapid track changes
- Cache store/lookup race and listener deadlock fixes

### [1.1.0] - 2025-12-29

#### Added
- Context menu with right-click on waveform seekbar
- Lock Width / Lock Height options to prevent resizing
- Lock settings persist across restarts

### [1.0.0] - 2025-12-28

#### Added
- Initial release
- Complete waveform display with click-to-seek
- Stereo and mono display modes
- Waveform styles: Solid, HeatMap, Rainbow
- Cursor effects: Gradient, Glow, Scanline, Pulse, Trail, Shimmer
- BPM sync from ID3 tags
- SQLite waveform caching with zlib compression

---

## Last.fm Scrobbler

### [Unreleased]

#### Changed
- Core logic extracted into pure, unit-tested modules gating every build (playback state machine, Last.fm signing/parsing, error policy, queue/dedup, streak validity, streak discovery walk, widget layout math). No functional change intended.
- Widget layout computed in a geometry pass shared by drawing and hit-testing (was a side effect of drawing)

#### Fixed
- Latent double-queue of an already-scrobbled track on playback stop
- Streak inflated by one day when the user had not scrobbled today

### [1.4.0] - 2026-05-17

#### Added
- Scrobble Queue table in preferences with multi-select delete

#### Fixed
- Scrobbles lost for artists with `&`, `=`, `+`, `#` in name — by [@Scannou](https://github.com/Scannou)
- Album art not appearing until view switch
- UI freeze during cache save
- Nil pointer crashes in image loading
- Double-scrobble on rapid track changes

#### Changed
- Async album art downloads with NSCache
- Hardened auth flow, keychain storage, and notification observers

### [1.3.0] - 2026-02-13

#### Added
- Recent Tracks view mode with album art and relative timestamps
- View mode switcher pill (Charts / Tracks)
- Track count selector (10 / 30 / 50)
- Left/right arrow navigation between view modes
- Scrollable content area for tracks list and album grid
- Live Now Playing indicator (zero API calls)
- Auto-refresh on scrobble (15s debounced)

### [1.2.0] - 2026-02-01

#### Added
- Artist image scraping from Last.fm website
- Track images via album artwork lookup
- Widget background customization (color picker and glass effect)
- Reload button and rank display in tooltip

#### Changed
- Sticky footer, centered bubble view, removed rank badges
- Error handling: partial failures shown in footer

#### Fixed
- Animation duplicate issue during layout transitions

### [1.1.0] - 2025-12-30

#### Added
- Stats widget for foobar2000 layout system
- Top albums grid display (weekly/monthly/all time)
- Profile image, username, scrobbled today counter
- Album artwork loading with caching
- Click albums/profile to open on Last.fm

### [1.0.0] - 2025-12-26

#### Added
- Initial release
- Last.fm authentication via web browser
- Automatic scrobbling after 50% or 4 minutes played
- Now Playing notifications
- Offline queue with automatic retry

---

## Album Art

### [1.1.0] - 2026-07-09

#### Added
- Fetch Missing Artwork: search Cover Art Archive, iTunes, Deezer, and TIDAL (optional) for album art via right-click
- Lightbox preview with type filters and multi-type selection; save to album folder and/or embed into file tags
- Unit test suite gating every build

#### Fixed
- Save-to-folder failed for track paths containing spaces
- Restarted searches could complete with stale or missing results
- Thumbnails could attach to the wrong results; footer clicks could open the wrong image
- First search after startup could falsely report offline; offline state now actually disables the menu item
- Track changes now cancel in-flight searches and clear stale results
- "Save Selected" could silently save fewer images than claimed; lightbox window leaked on every presentation
- Remembered "embed" preference was ignored for multi-image saves; remembered choices can now be reset from the context menu

### [1.0.2] - 2025-12-30

#### Fixed
- Layout compression when no album art is available

### [1.0.1] - 2025-12-29

#### Fixed
- Album art images affecting parent container width, causing column resizing between tracks

### [1.0.0] - 2025-12-28

#### Added
- Initial release
- Multiple artwork types: front cover, back cover, disc art, icon, artist photo
- Selection-based display with now playing fallback
- Interactive navigation arrows on hover
- Context menu for type switching
- Per-instance configuration and layout parameters

---

## Queue Manager

### [Unreleased]

#### Added
- Multi-row drag reorder (previously only the first selected row moved)

#### Changed
- Pure logic extracted into SDK-free Core units (QueueReorderPlanner, QueueFormatting, QueueDropParser) with unit tests gating every build
- Column metadata consolidated into a single source of truth; dead QueueHeaderView removed; real component GUIDs and corrected metadata

#### Fixed
- Build failure after shared UIStyles.h dropped `selectedBackgroundColorForGlass()`; selection now uses `selectedBackgroundColor()` like SimPlaylist
- Code review cleanups: duration formatting UB on malformed track lengths, duplicated title-format error handling, orphan sentinel consistency, selection recolor efficiency
- Reorder debounce flag never suppressed callbacks (redundant double reload per reorder); reorder now exception-safe with stale items re-added as orphans; SimPlaylist drops validate the source playlist index

### [1.1.2] - 2026-02-09

#### Changed
- Switched from custom QueueHeaderView to native NSTableHeaderView for proper resize support

#### Fixed
- Column resize via header divider dragging
- SimPlaylist drag/drop NSDictionary format handling

### [1.1.0] - 2026-01-22

#### Changed
- Custom header bar matching SimPlaylist architecture
- Glass/vibrancy refactor using shared UIStyles.h helpers

#### Fixed
- Drag & drop from SimPlaylist (new NSDictionary pasteboard format)
- Header appearance matching SimPlaylist dark mode

### [1.0.0] - 2025-12-29

#### Added
- Initial release
- Queue display with position, artist/title, and duration columns
- Double-click to play, delete to remove, multi-selection
- Internal drag reordering and SimPlaylist drop support
- Glass/vibrancy background option
- Status bar showing item count

---

## Effects DSP

### [1.0.0] - 2026-02-14

#### Added
- Initial release (macOS port of foo_dsp_effect by mudlord)
- 11 audio effects: Echo, Tremolo, IIR Filter, Reverb, Phaser, WahWah, Chorus, Vibrato, Pitch Shift, Tempo Shift, Rate Shift
- Native macOS configuration UIs (programmatic, no XIB)
- Real-time safe audio processing
- Universal binary (arm64 + x86_64)

---

## Biography

### [1.1.0] - 2026-07-17

#### Added
- Artist image gallery (Fanart.tv, TheAudioDB, Deezer) with full-screen lightbox viewer
- MusicBrainz MBID lookup when Last.fm returns none (unlocks Fanart.tv coverage)
- Wikipedia biography fallback resolved via MusicBrainz -> Wikidata -> Wikipedia
- Dual-layer artist image cache with request coalescing

#### Changed
- Testable-core refactor (SimPlaylist pattern): SDK-free Core logic with 9 unit test suites gating the build

#### Fixed
- Data race in the gallery coordinator's multi-source completion tracking
- Fanart.tv client crash on malformed MusicBrainz IDs

### [1.0.0] - 2025-12-30

#### Added
- Initial release
- Artist biography display from Last.fm API
- Automatic updates on track/artist change with debounce
- SQLite caching with staleness detection
- Offline fallback, loading spinner, error state with retry

---

## Cloud Streamer

### [0.1.0] - 2025-12-30

#### Added
- Initial experimental release
- Stream Mixcloud and SoundCloud content directly in foobar2000
- Internal URL schemes (mixcloud://, soundcloud://) and web URL support
- Automatic metadata extraction (title, artist, duration, thumbnail)
- Chapter/tracklist support for DJ sets (embedded CUE sheet)
- Stream URL caching with automatic expiry refresh
- Requires yt-dlp

---

## Playback Controls

### [0.1.0] - 2025-12-30

#### Added
- Initial release
- Transport buttons: Play/Pause (state-aware), Stop, Previous, Next
- Volume slider with dB display
- Customizable track info rows using titleformat expressions
- Drag-to-reorder buttons in editing mode
- Compact and normal display modes

## Tidal Integration

### [Unreleased]

Testability refactor following the simplaylist 1.5.0 pattern. No functional change intended.

#### Added
- Pure Core modules extracted from SDK/network code: `ManifestParser` (BTS/DASH parsing), `StreamResolutionPolicy` (quality fallback), `HTTPResponsePolicy` (status-to-error mapping), `ResponseParser` (JSON to models, replacing 11 inline loops in the API client), `TidalLog` (Foundation-only logging funnel)
- Standalone unit-test suite (194 checks, 7 binaries, ASan+UBSan) gating every build via `Scripts/run_tests.sh`

#### Fixed
- Debug-logging preference honored after restart (cache was only synced on toggle)
- Static-destructor logging can no longer touch torn-down fb2k services

### [0.3.1] - 2026-06-17

LOSSLESS FLAC playback now works for LOSSLESS subscribers by default. DASH segment parser rewritten against `python-tidal` semantics.

#### Added
- LOSSLESS FLAC by default for LOSSLESS subscribers (preference checkbox ticked by default; untick to fall back to 320kbps HIGH)
- Raw MPD manifest XML logged when DASH is enabled, for easier diagnosis

#### Fixed
- Segment count derived from `<SegmentTimeline><S r="N"/>` elements (was: `mediaPresentationDuration / segmentDuration`, undercounted)
- `media[$Number$=0]` treated as the init segment, no separate init download (was: separate init + media[1..N], producing malformed fMP4)
- FLAC content type routed via `audio/x-flac` so fb2k picks the FLAC decoder (was: always `audio/mp4`)
- DASH codec normalisation for `flac`, `mp4a.*`, `ec-3`, `ac-4`

### [0.3.0] - 2026-05-17

Fixes the long-standing "playback stops until restart" cascade and restores drag-drop to SimPlaylist + free column resizing. Adds token-state visibility, Year/Tracks columns in the album browser, and an experimental DASH toggle for true LOSSLESS.

#### Added
- Album browser: Year and Tracks columns
- Preferences: token status line with expiry countdown and last-refresh outcome
- Preferences: experimental DASH toggle for true LOSSLESS (off by default, untested)
- Stream-open diagnostics and premature-EOF detection always logged

#### Fixed
- Playback cascade through the playlist on aborted preloads (decoder treated cancellations as track failures)
- Tidal browser column can be resized freely in fb2k layouts
- Drag-drop to SimPlaylist (URL emitted as NSPasteboardTypeURL)
- Reconnect button no longer hangs on success path
- Refresh-token rotation honoured; 401 auto-retry transparent

#### Changed
- Quality-fallback log is unambiguous about silent API downgrades
- Refresh/token logs always visible regardless of debug-logging setting

### [0.2.0] - 2026-02-13

#### Added
- Initial public release: browser, search, library, playlists, sync, ISRC matching, album art
