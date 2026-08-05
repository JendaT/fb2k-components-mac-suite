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
- **Metadb cache migration**: spawned shell helper moves cached metadata rows from each dead UUID into its live target across the main `metadb` table and all `metadb_index_*` tables (copy with `INSERT OR IGNORE` - preserving any rows foobar already cached for the live UUID - then delete the dead-UUID sources in the same transaction, so copies do not accumulate across remount generations).
  - Runs after foobar exits so SQLite write locks are free; aborts if another foobar2000 instance is already running, and a restart via the repair prompt waits for the migration to finish before reopening the app (never concurrent with a live fb2k session).
  - Backs up `metadb.sqlite` (plus WAL/SHM siblings) to `metadb.sqlite.plorg-pre-migration` before writing (single rotating copy; skipped with a logged warning only when disk space is short).
  - Transactional with `.bail on`: any SQL error rolls the entire migration back instead of committing a partial result.
  - Logs to `/tmp/plorg_metadb_migration_<pid>.log`.
  - **Orphan cache detection**: runs on every startup; if any dead UUID holds cached rows that could be moved to a live equivalent, the migrator is scheduled even without a `.fplite` patch. Recovers caches from sessions where the playlist was remapped before this feature existed.
- **Volume self-heal** (closes the remediation gap behind the 2026-07-11 incident): when playlists reference a stale UUID whose volume IS mounted but every foobar registry bookmark is dead, plorg feeds one real file from the volume through the core's location machinery (`process_locations_async`) so foobar2000 registers the volume and mints a fresh security-scoped bookmark, then re-runs the repair to remap the stale playlists onto it - no manual "add a file from the drive" step.
  - Verified against the registry with retries; attempted at most once per mounted path per session.
  - If the core does not persist a bookmark from component-driven resolution (open question in `docs/VOLUME_UUID_SELF_HEAL_PROPOSAL.md`; needs field verification), falls back to a one-click "Choose File..." registration prompt (gated by the restart-prompt preference), with console instructions as the last resort.
  - Preference: "Self-register mounted volumes that have no working bookmark" (default on).
  - Bookmark creation goes through foobar2000 itself; plorg keeps its hard rule of read-only access to `config.sqlite`.
- **`Scripts/metadb_cleanup.sh`**: offline maintenance tool that reclaims metadb space left by pre-1.5.0 copy-only migrations (observed: 4 full copies of a 156k-track library's metadata, 8.7 GB). Deletes rows whose `mac-volume://` UUID is neither referenced by any `.fplite` playlist nor live in plorg's registry snapshot, garbage-collects orphaned `metadb_index_*_data` blobs, VACUUMs, and verifies integrity. Refuses to run while foobar2000 is running (`--dry-run` is read-only and safe anytime); full backup before writing unless `--no-backup`.

### Changed
- **Testable-core refactor** (simplaylist pattern): extracted pure logic from SDK/UI-entangled classes into Foundation-only `src/Core` modules, each covered by standalone clang unit tests that now gate every build (`Scripts/run_tests.sh`, invoked by `build.sh`):
  - `PathCodec` - guillemet escaping and path-encoded foobar name encode/split (from `TreeModel`).
  - `TreeYamlCodec` - tree YAML serialization and both parsers (from `TreeModel`; removes a duplicate parser in `PlaylistOrganizerController`).
  - `TreeOps` - playlist search, path-aware lookup, and import merge semantics (from `TreeModel`).
  - `VolumeSyncLogic` - share-name/config-key parsing, `.fplite` line scanning, BOM-preserving UUID remap, repair planning (filesystem probe injected), orphan-cache migration decisions, and metadb migration SQL builder (from `VolumeSyncService`; removes duplicated scan/remap loops in `UUIDRemappingWindowController`).

### Fixed
- Manual UUID remapping tool (`UUIDRemappingWindowController`) now preserves the UTF-8 BOM when rewriting `.fplite` files (previously stripped it; the automatic sync already preserved it). Both paths now share the same remap implementation.
- **Volume sync outcome log no longer lies**: "All .fplite UUIDs are live; nothing to patch" was emitted whenever nothing was remapped, including when a stale UUID was found with no live replacement. The summary now reports the real outcome, and distinguishes "volume not mounted" from "volume IS mounted but foobar2000 has no working bookmark for this session" (statfs mount-point probe) - the latter tells the user to play/add a file from the volume in fb2k to register it, instead of the dead-end "mount the volume and retry".
- **`/Volumes` monitor repair storm**: each vnode event scheduled an independent, uncancelled 3-second check, so one mount's event burst ran the full registry scan several times in a row (observed 4x within a second). Events now cancel and re-arm a single coalescing block.
- Strict volume-UUID validation (8-4-4-4-12 hex) at all parse boundaries, plus escaping in the generated metadb migration SQL (defense in depth against malformed `.fplite`/config content).
- **Migrator index-table discovery matched the wrong table**: `LIKE 'metadb_index_%'` treats `_` as a single-character wildcard, so it matched the `metadb_indexes` metadata table (columns `name/synced/retention`) and generated an `INSERT ... (key, filename)` that fails to parse. Discovery now uses `GLOB` (literal `_`) plus a strict shape validator (`metadb_index_` + `8_4_4_4_12` hex GUID) enforced both at discovery and inside the SQL builder; covered by unit tests.
- **Restart no longer races the metadb migration**: the relauncher and the migrator both waited only for the old foobar process to exit, so a "Restart Now" reopened foobar2000 while the migration was writing metadb ("database is locked", interrupted migration - the 2026-07-11 incident trigger). The relauncher now waits for the staged migration to complete (bounded at 15 minutes) before reopening the app.
- **Review hardening** (three-pass code review, 2026-07-17):
  - FTH theme parser no longer reads out of bounds on files shorter than 4 bytes; DBPL import no longer silently drops all entries following a malformed length field.
  - Tree YAML parser no longer throws on a truncated quoted value (a bare `"`); a successful config read is no longer misread as a failure (which could fall through to a default tree that overwrites `foo_plorg.yaml`).
  - `.fplite` sample paths that are empty, absolute, or contain `..` components are rejected at the parse boundary (blocks path traversal via crafted playlist content); the manual remap tool validates the target UUID before rewriting and derives sample paths from the same validated parser instead of raw substring extraction.
  - Vox and Strawberry import databases are opened read-only (previously opened read-write on other applications' live databases).
  - Corrupted-playlist removal backs files up to `backup_corrupted_<timestamp>` before deleting; the known-bad playlist list is no longer clobbered when its file exists but cannot be read.
  - Backup timestamp formatters pinned to en_US_POSIX so backup pruning order is locale-independent; manual remap snapshots its selection before background apply and disables the table during the rewrite.
  - Delete-folder dialog now describes actual behavior (playlists move to the parent folder; deletion from foobar2000 only with the recursive checkbox).
  - Build tooling: project-generation failures abort the build instead of silently building a stale project; clang warnings are no longer filtered out of build output; test binaries compile in parallel; `metadb_cleanup.sh` enforces the running-foobar guard when `PLORG_FB2K_DIR` points at the live profile and warns when the registry snapshot is unreadable.
- **Review hardening, round 4** (2026-07-25):
  - Metadb cache migration no longer risks deleting rows instead of migrating them: the generated SQL used a case-insensitive `LIKE` to select rows but a case-sensitive `REPLACE` to rewrite them, so a metadb row storing a lower-case volume UUID was matched, left unchanged by the copy, then deleted. Each `DELETE` is now guarded to remove only rows the copy step actually rewrote.
  - Orphan-cache migration and remap planning now normalize registry volume paths (trailing slash, Unicode form), so a live volume recorded as `/Volumes/music` and a stale one recorded as `/Volumes/music/` are recognized as the same volume instead of silently skipping the migration.
  - Vox import no longer crashes on a playlist whose name is invalid UTF-8 (the undecodable name previously reached the SDK as a NULL pointer); the SimPlaylist drag payload is type-checked before use (a malformed cross-process payload could crash on drop).
  - Repair Volume UUIDs window: closing it with the title-bar button now cancels cleanly (previously leaked the controller and left its background scan running); a backup failure re-enables the window instead of leaving it a dead, disabled shell; re-opening the tool reuses the existing window.
  - Corrupted-playlist props database backup/delete now includes `-wal`/`-shm` siblings; `metadb_cleanup.sh` prints restore guidance if the cleanup itself fails and resists a firmlink-aliased `PLORG_FB2K_DIR` bypass of the running-foobar guard.
  - Strawberry import preview no longer loads a database for a sheet that is never shown; folder checkboxes track the model rather than cell-reuse state; a leftover diagnostic timestamp formatter is pinned to en_US_POSIX.
  - Removed dead public API and unused exported types from `VolumeSyncService.h`, `TreeModel.h`, `PlaylistOrganizerController.h`, and `UUIDRemappingWindowController.h`; documented the main-thread-only contract on the stateful services.

### Documentation
- `../../docs/research/volume-uuid-instability-deep-research.md` — deep research on macOS volume identity, foobar's storage, and prior incident history.
- Updated `../../docs/VOLUME_UUID_ISSUE.md`.

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
