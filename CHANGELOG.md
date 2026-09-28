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
- **SDK**: Built against foobar2000 SDK 2026-10-01; components now compile as C++20 and link the renamed `libpfc.a`.
- **Requires macOS 12**: All components now target macOS 12, as Xcode 27 cannot build for macOS 11.
- Preferences page titles now match foobar2000's built-in style (non-bold)
- Unified copyright notices across all extensions

---

## SimPlaylist

### [Unreleased]

### [1.6.0] - 2026-08-23

Adds the Sort submenu, plus a large bug-fix pass: five ways of silently losing
settings, two ways of hanging the app, and the misplaced drag indicator.

#### Added
- **Sort submenu**: Right-click menu now has Sort (Sort by..., Randomize, Reverse, by album/artist/path/title/track number), acting on the selection when 2+ tracks are selected (#20).

#### Fixed
- Dragging tracks or folders from the album list into the playlist did nothing
- Dropped files whose path contained a space could fail with "Access denied" (scheme-less file URL was imported percent-encoded)
- Dropped Various Artists albums no longer scatter alphabetically by performer (compilations sort by disc/track when their album artists disagree)
- Renaming a custom column no longer gets undone by the next column resize and then deleted on the following launch
- A hiccup registering another component's columns no longer wipes columns from the saved layout
- Clearing the subgroup pattern no longer discards the other subgroups a preset defines
- Preferences no longer silently discards edits when the stored preset index is out of range
- Deleting or reordering playlists no longer saves scroll positions and group data under another playlist's name, or applies a drag reorder to the wrong playlist
- Delete/Backspace with an empty selection hung the app
- An oversized cover was re-decoded on every redraw across four threads for as long as it was on screen
- Album art is capped by memory (256 MB) as well as image count; it could previously reach ~1 GB
- Switching grouping preset did nothing until an unrelated pattern field was edited
- **Preset and display size at launch**: Chosen preset and row size now apply on startup instead of falling back to the first preset and 22 pt rows
- **Glass background toggle**: No longer blanks the panel until restart
- Custom column changes required a restart
- Toggling either subgroup option reused the layout cached under the old setting
- Typing a grouping pattern was sluggish; leaving the field rebuilt the playlist twice
- Drop indicator sat up to 150 px below the cursor in grouped playlists, and the drop landed where the line was drawn
- Home/End jumped to an arbitrary point mid-list in grouped playlists
- Multi-disc albums dropped from the Tidal browser interleaved their discs
- Shift-click after a playlist switch extended from the previous playlist's anchor
- Two open panels interfered: one rebuilding cancelled the other's grouping
- Column headers hidden behind the album-art strip stayed clickable and resizable
- Assorted crash guards from a multi-pass code review

#### Changed
- **macOS 12 required**: Minimum raised from macOS 11; current Xcode no longer builds for 11.
- Row hit-testing in large grouped playlists no longer nests four searches: group header rows are precomputed, taking a 200k-track/20k-group query from 10,338 array lookups to none, with a probe-budget test enforcing it
- Internal cleanup, no behaviour change: ~1,100 lines of legacy rendering code removed, five copies of the group-application sequence merged, the column layout given a single writer, settings changes given a defined order
- Test coverage grew from ~104,000 to ~108,000 assertions, adding suites for the column and preset data formats

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

### [1.5.1] - 2026-09-25

#### Changed
- **Requires macOS 12**: built with Xcode 27, which cannot target macOS 11

#### Fixed
- **Crash on restart after a repair**: the migration now runs on a staged copy and is swapped in by rename, so reopening foobar2000 while it works cannot disturb the live database
- **Database growth**: rows are renamed in place instead of copied and deleted, so the file no longer doubles during a migration and needs no VACUUM
- **Migration speed**: 29.1s down to 4.6s on a 2.35 GB database, byte-identical result
- **Faster restart after a repair**: instant APFS clone for the working copy; relaunch no longer waits on cleanup
- **Reclaiming old bloat**: the staged copy is compacted when mostly free pages, recovering space lost to earlier versions

#### Added
- **`Scripts/volume_registry_prune.sh`**: removes unused volume bookmarks for the music share; dry run by default, refuses to write while foobar2000 runs

### [1.5.0] - 2026-08-26

#### Added
- **Automatic Volume UUID Sync**: Repairs stale `mac-volume://` UUIDs in playlists after SMB/Tailscale remounts. Off by default
- **Volume self-heal**: Registers a mounted volume foobar2000 has no working bookmark for, then remaps the stale playlists. Off by default
- **Metadb cache migration**: Moves cached metadata to the live UUID after foobar2000 quits; backed up, transactional, verified and compacted
- **Finder file drop**: Drop files or folders onto a playlist node to append them (thanks @Scannou, #36)
- **FTH Theme Import**: Imports tree and tracks from old Windows foo_plorg themes (developed as 1.4.0)
- **Corrupted Playlist Detection**: Finds and safely removes playlists foobar2000 cannot load (developed as 1.4.0)
- **`Scripts/metadb_cleanup.sh`**: Offline tool that reclaims metadb space from dead-UUID copies

#### Changed
- **Testable core**: Pure logic extracted into Foundation-only modules; 270 unit checks gate every build
- **Network Volumes off by default**: Power-user feature; opt in from Preferences

#### Fixed
- **Restart after repair**: No longer reopens foobar2000 while the database is being written ("database is locked", "metadb is corrupted")
- **Concurrent migrations**: Only one migration runs per session; two were observed running at once
- **Database growth**: Migrations now compact the file, which previously kept its largest-ever size permanently
- **Lower-case UUIDs**: Cached metadata could be deleted instead of migrated when a UUID was stored in lower case
- **Config load failure**: No longer mistaken for an empty configuration, which could replace the saved folder tree
- **Malformed input crashes**: FTH, DeaDBeeF, YAML, Vox and drag-payload parsers hardened
- **Path traversal**: Crafted playlist paths can no longer escape their drive
- **Import databases**: Vox and Strawberry libraries opened read-only
- **Repair Volume UUIDs window**: Close cancels cleanly; backup failure re-enables it; reopening reuses the window
- **Build tooling**: Failed project regeneration aborts the build; compiler warnings no longer filtered out

### [1.4.0] - developed 2026-02-14, never published (ships in 1.5.0)

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

### [1.4.1] - 2026-10-12

#### Changed
- **Scrobble timing**: Submitted at the next track change, pause, stop or quit instead of mid-play — by [@Scannou](https://github.com/Scannou)
- **Widget layout**: Computed in one geometry pass shared by drawing and click handling.
- **Testable core**: Core logic moved into pure modules; unit tests gate every build.
- **Requirements**: macOS 12 or later (was 11).

#### Fixed
- **Quit mid-track**: The last scrobble is saved at shutdown and submitted on next launch.
- **Listening streak**: No longer one day too high when nothing has been scrobbled today.
- **Stop after scrobble**: A track already scrobbled is no longer queued a second time on stop.

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

### [1.2.0] - 2026-10-02

#### Added
- **Stop After Queue**: Stops playback when the last queued track finishes; Playback menu, context menu or preferences (off by default).
- **Stop only once**: Optional mode that turns Stop After Queue off after it stops playback.
- **Queue restore**: Queue is saved on quit and re-added on launch (on by default).
- **Context menu**: Right-click in Queue Manager for the Stop After Queue toggles.
- **Multi-row drag reorder**: Selected rows move together; previously only the first row moved.

#### Fixed
- **Reorder flicker**: Each reorder no longer rebuilds the view and resets the selection twice.
- **Frozen view**: View no longer stops updating after a failed reorder.
- **Reorder after playlist edits**: Tracks whose source playlist changed are kept instead of lost.
- **Malformed drops**: Drops referencing a nonexistent playlist are rejected.
- **Duration display**: Malformed track lengths show `--:--` instead of garbage.

#### Changed
- **Requires macOS 12**: Built with Xcode 27, which cannot target macOS 11.
- **Column metadata**: Consolidated into a single source of truth; unused `QueueHeaderView` removed.

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

## Spectrum Analyzer

### [0.3.0] - 2026-10-12

#### Added
- **Full-screen view**: Double-click or context menu opens a native full-screen spectrum; Esc or double-click leaves it.
- **Logarithmic (compact bass) scale**: Bottom octaves take far less width than on a pure log axis.
- **RMS averaging**: Averages power per bin over 0-200 ms for even, analyzer-style motion.
- **Spectral slope**: 0-6 dB/octave tilt around 1 kHz.
- **Curve styles**: Filled, Line, Color bars, Line + color bars.

#### Changed
- **Display-synced redraw**: macOS 14+ redraws in step with the screen refresh; motion is frame-rate independent.

### [0.2.0] - 2026-10-09

#### Added
- **Auto bar count**: Fits the panel width (one bar per 2 points), up to 2048 bars; new 384/512 presets.
- **Per-bar frequency labels**: Each bar labelled with its centre frequency in Bars mode.
- **Frequency readout**: Click and hold for the exact frequency under the cursor.
- **Denser frequency axis**: Extra ticks in the 10-20 kHz range; round steps on the linear scale.

#### Changed
- **Settings changes and resizes**: Bars keep their levels instead of blanking.
- **Drawing**: Batched bar paths, one gradient per frame, pixel-snapped bar edges.

#### Fixed
- **Small FFT sizes**: Lowest bands no longer read the DC bin.

### [0.1.0] - 2026-10-03

#### Added
- Initial release, contributed by [Scannou](https://github.com/Scannou)
- **Analyzer core**: Real-time FFT bars from the core visualisation stream; log/linear band mapping; sub-bin low-end bands interpolated; 0..-80 dB display window shared by bars and grid.
- **Dynamics**: Attack/decay smoothing plus three fall timescales (bar, shadow envelope, peak line with hold).
- **Rendering**: Solid / gradient / spectrum bar styles; bars or smooth full-width curve; horizontal or vertical orientation; dB scale and frequency axis; glass background.
- **Preferences**: Bar count up to 256, FFT size, frequency scale/range, smoothing, fall rates, peak hold, grid color/opacity, light/dark colors, 10 color theme presets.
- **Lifecycle**: Streams released via `initquit` before service teardown (fixes abort on quit).

## Vectorscope

### [0.1.0] - 2026-10-12

#### Added
- Initial release, contributed by [Scannou](https://github.com/Scannou)
- **Scope**: Goniometer or Lissajous style with afterglow trace (lines or dots), -6/-12 dB guides and L/R/M/S axes.
- **Band colors**: Optional low/mid/high colored trace.
- **Gain**: Auto gain that keeps the trace inside the scope, or fixed 0 to +36 dB.
- **Correlation meter**: Broadband or low/mid/high bars, configurable position, thickness and recent-range hold.
- **Appearance**: 11 color presets with light/dark colors, glass background.

## Tidal Integration

### [Unreleased]

#### Added
- Save to library (music.hq): personal playlist context-menu export of selected tidal:// tracks into a configured library root using the music.hq layout (genre collection / artist / `Artist [YYYY] Title`, with `[Releases]` and `[Compilations]` slots). Genre resolution: existing artist folder on disk > remembered choice > one-time picker. DASH FLAC remuxed losslessly to tagged `.flac` via ffmpeg; `cover.jpg` fetched per album; existing files skipped. Gated by the Preferences > Library folder setting (unset hides the feature)
- DASH prefetch: the next track in the active playlist is resolved and its segments pre-assembled into an in-memory blob cache while the current track plays, so lossless/hi-res tracks open instantly instead of stalling ~3-4s on the segment download. Byte-capped (~320 MB), cleared on quit
- Pure Core modules extracted from SDK/network code (testability refactor, no functional change): `ManifestParser`, `StreamResolutionPolicy`, `HTTPResponsePolicy`, `ResponseParser` (replacing 11 inline API-parsing loops), `SyncPlanner`, `BrowserLogic`, `DashCachePolicy`, `TidalLog`
- Standalone unit-test suite (425 checks, 11 binaries, ASan+UBSan) gating every build via `Scripts/run_tests.sh`

#### Fixed
- Decoder open failures now log the chosen decoder and the exception instead of silently skipping the track
- Debug-logging preference honored after restart (cache was only synced on toggle)
- Static-destructor logging can no longer touch torn-down fb2k services
- Pull sync no longer truncates playlists at 200 tracks (all sync fetches paginate to completeness); a failed remote fetch can no longer wipe a local playlist (excluded from the plan instead of diffing as empty)
- fb2k playlist state read only on the main thread in sync previews; sync shared state serialized; request bursts bounded to 4 concurrent
- Token refresh is single-flight (concurrent callers get the real result instead of a 1s sleep guess); sign-out during refresh can no longer resurrect a session
- Two crash fixes (nil dictionary key in push-sync apply, std::string(NULL) in DASH 403 re-open) plus 58 review fixes: JSON type guards, album-art data cache, stale-response guards, leak fix, dedupe

#### Security
- tidal:// content IDs validated before use in authenticated API paths (blocks request forgery via crafted playlists); search/ISRC query values strictly encoded; path traversal guards on library export paths; request logs redacted to host+path; DASH manifest bomb hardening

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
