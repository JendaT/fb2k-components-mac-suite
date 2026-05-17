# Changelog

All notable changes to Playlist Organizer will be documented in this file.

## [1.5.0] - Unreleased

> Not yet end-to-end verified. Committed for tracking; needs more field testing
> with disconnect / reconnect cycles on SMB / Tailscale shares.

### Added
- **Automatic Volume UUID Sync**: Headless service that auto-repairs stale `mac-volume://` UUIDs in network-share playlists caused by SMB / Tailscale remounts assigning fresh ephemeral UUIDs.
  - **Bookmark-based discovery**: reads foobar's own `config.sqlite` and classifies each `mac.volume.<UUID>.bookmark` as live or dead by resolving the security-scoped bookmark (`URLByResolvingBookmarkData` with `WithoutUI | WithoutMounting`). Works for SMB shares where macOS UUID APIs (`NSURLVolumeUUIDStringKey`, DiskArbitration) return null.
  - **`.fplite` patching**: rewrites dead UUIDs to live equivalents for the same `originalPath`, preserving UTF-8 BOM, with timestamped backups (keeps 5 most recent).
  - **Sample-path bootstrap fallback** for UUIDs not in foobar's registry: probes file existence on currently-mounted volumes.
  - **Two trigger points**: `initquit::on_init` at startup, and a `/Volumes` `dispatch_source` VNODE monitor (3-second debounce) for mid-session mount changes.
  - Diagnostic snapshot persisted to `~/Library/foobar2000-v2/plorg_volume_uuids.json`.
  - Preference: "Auto-repair volume UUIDs on startup (network drives)" (default on).
- **Opt-in auto-restart prompt** after a successful repair.
  - Modal "Restart Now / Later" dialog; "Restart Now" spawns a detached shell helper that waits for foobar to exit then re-opens the app.
  - Preference: "Prompt to restart automatically when repairs are applied" (default off).
- **Metadb cache migration**: spawned shell helper duplicates cached metadata rows from each dead UUID into its live target across the main `metadb` table and all `metadb_index_*` tables (`INSERT OR IGNORE` preserves any rows foobar already cached for the live UUID).
  - Runs after foobar exits so SQLite write locks are free.
  - Logs to `/tmp/plorg_metadb_migration_<pid>.log`.
  - **Orphan cache detection**: runs on every startup; if any dead UUID holds cached rows that could be moved to a live equivalent, the migrator is scheduled even without a `.fplite` patch. Recovers caches from sessions where the playlist was remapped before this feature existed.

### Documentation
- `docs/research/volume-uuid-instability-deep-research.md` — deep research on macOS volume identity, foobar's storage, and prior incident history.
- Updated `docs/VOLUME_UUID_ISSUE.md`.

## [1.4.0] - 2026-02-14

### Added
- **FTH Theme Import**: Import playlist tree structure and tracks from old Windows foo_plorg theme files
  - Parses tree markers from .fth theme files to reconstruct folder hierarchy
  - Imports tracks from .fplite files with automatic path conversion
  - Windows-to-macOS path mapping with configurable drive letter mappings
  - Handles relative Windows paths, UNC paths, and file:// URLs
  - Lenient percent-encoding decoder for malformed URLs
  - Duplicate tree detection to avoid importing redundant data
  - Import summary report with found/missing track statistics
- **Corrupted Playlist Detection**: Detect and safely remove corrupted playlists
  - File-based checks: missing .fplite, empty content, unreadable content, invalid format (Windows paths)
  - Crash marker system: automatically identifies playlists that cause SDK-level crashes
  - Known bad playlist tracking persisted across sessions
  - Safe filesystem-based removal (bypasses SDK to avoid crash-on-remove)
  - Preference: "Check for corrupted playlists on startup"
  - "Check Now" button in preferences for on-demand scanning

### Fixed
- Nil safety in path encoding prevents crash when tree nodes have nil names
- Import exception handling now properly resets view state (no more blank view on failure)
- Playlist item count access skipped for known-bad playlists to prevent startup crashes

## [1.3.2] - 2025-01-15

### Added
- **Network Volume UUID Remapping**: Tool to repair orphaned playlist entries caused by network volume UUID changes
  - Scans playlists for mac-volume:// references and identifies orphaned UUIDs
  - Browse button detects current UUID for mounted volumes (including network shares)
  - Automatic backup before applying changes
  - Shows restart notification after successful remapping
  - Access via Plorg menu > Network Volume UUID Remapping

## [1.2.0] - 2025-12-30

### Added
- **Transparent Background Option**: Preference to toggle glass effect background
- New checkbox in Appearance section (requires restart to apply)

## [1.1.0] - 2025-12-28

### Added
- **Tree Lines Display**: Optional Windows Explorer-style tree connection lines
- New preference toggle in Appearance section to enable/disable tree lines
- Works best for single-level folder nesting

## [1.0.0] - 2025-12-22

### Initial Release
- Hierarchical playlist organization with folders
- Unlimited folder nesting depth
- Drag & drop to reorder playlists and folders
- Customizable node display formatting with title formatting syntax
- Auto-sync with foobar2000 playlist changes
- Human-readable YAML configuration storage
- Import/Export functionality for sharing configurations
- Path mapping for portable library configurations
- Native macOS UI (NSOutlineView)
- Dark mode support
