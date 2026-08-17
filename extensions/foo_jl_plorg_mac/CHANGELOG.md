# Changelog

All notable changes to Playlist Organizer will be documented in this file.

## [1.5.0] - Unreleased

Playlists on network drives used to break every time the share remounted:
macOS hands out a fresh volume UUID, and every `mac-volume://` entry in your
playlists silently stops resolving, so tracks show up as missing. 1.5.0 repairs
that automatically, and moves foobar2000's cached metadata across with it so
the library does not have to re-scan.

Coming from 1.3.0? This release also carries the work that was developed as
1.4.0 in February 2026 but never published - FTH theme import and
corrupted-playlist detection - listed under "Also in this release" below.

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
  - Runs after foobar exits so SQLite write locks are free, and refuses to start if any foobar2000 instance is running. When the repair prompt asked for a restart, the same process reopens the app once the migration is finished and verified - so foobar2000 can never be running while metadb is written.
  - Backs up `metadb.sqlite` (plus WAL/SHM siblings) to `metadb.sqlite.plorg-pre-migration` before writing (skipped with a logged warning when disk space is short), integrity-checks the result, restores that backup if the check fails, and otherwise removes it.
  - Transactional with `.bail on`: any SQL error rolls the entire migration back instead of committing a partial result. Compacts the database afterwards so migrations cannot inflate it over time.
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
- **"Restart Now" no longer reopens foobar2000 while the database is being written** - the cause of both the original "database is locked" failure and the later "metadb is corrupted, recovering" reports. Restarting and migrating were two separate processes coordinating through the presence of a temporary file, which the relauncher treated as "migration finished". That file also disappeared when the migration was skipped, when a second migrator finished first while the original was still writing, and when a 15-minute timer expired on large databases - each time letting foobar2000 open the database mid-write. Migrating and restarting are now a single ordered sequence: migrate, verify, vacuum, then reopen.
- **Only one migration runs per session.** Repair runs at startup and on every mount change, and each pass used to schedule its own migrator - two were caught running at once, writing the same backup file simultaneously. Later passes now just update the plan the single scheduled migration will use.
- **The database no longer grows without ever shrinking.** Moving cached metadata to a new UUID frees space *inside* the file that SQLite never hands back to the disk, so it kept its largest-ever size permanently - one library went from 2.35 GB back up to 6.94 GB in six days, 62% of it empty. The migration now compacts the file afterwards, while foobar2000 is closed; skipped with a note in the log if the disk is short on space.
- **Migrations are verified and no longer leave a permanent second copy.** The database is integrity-checked after migrating, the pre-migration backup is restored automatically if that check fails, and otherwise removed - previously it was rewritten every time and never deleted, permanently doubling disk usage.
- **Data-safety fixes found by four rounds of code review** (2026-07-17 to 08-11):
  - Cached metadata could be **deleted instead of migrated** when a volume UUID was stored in lower case - the migration matched those rows case-insensitively but rewrote them case-sensitively, so the copy silently did nothing and the delete still ran. Deletions are now restricted to rows the copy actually rewrote.
  - A volume recorded as `/Volumes/music` and one recorded as `/Volumes/music/` are now recognised as the same drive, instead of silently skipping the migration.
  - A failed config read is no longer mistaken for an empty configuration, which could replace your saved folder tree with a default one.
  - Removing corrupted playlists now backs the files up first, and the quarantine list is no longer wiped when it cannot be read.
  - Crash fixes on malformed input: FTH theme files under 4 bytes, DeaDBeeF playlists with a bad length field, truncated quotes in `foo_plorg.yaml`, playlist names that are not valid UTF-8 on Vox import, and malformed drag payloads from other components.
  - Playlist files with crafted paths can no longer escape the drive they belong to; the manual remap tool validates the UUID you type before rewriting anything.
  - Vox and Strawberry libraries are now opened read-only during import - previously plorg opened another application's live database for writing.
  - Repair Volume UUIDs window: closing it with the red button cancels cleanly instead of leaving its scan running; a backup failure re-enables the window instead of leaving it dead; reopening the tool reuses the existing window.
  - Backup timestamps are locale-independent, so pruning keeps the newest backups on non-Gregorian calendars.
  - Delete-folder dialog now describes what actually happens (playlists move to the parent folder; they are only deleted from foobar2000 if you tick the recursive option).
  - Build tooling: a failed project regeneration now aborts the build instead of silently packaging a stale one, and compiler warnings are no longer filtered out of the build log.

### Also in this release
Developed as 1.4.0 (February 2026) and never published separately, so it ships here:

- **FTH Theme Import**: import your playlist tree and tracks from an old Windows foo_plorg theme file.
  - Reconstructs the folder hierarchy from the theme's tree markers and imports the tracks from the accompanying `.fplite` files.
  - Windows-to-macOS path mapping with configurable drive-letter mappings; handles relative Windows paths, UNC paths and `file://` URLs, and tolerates malformed percent-encoding.
  - Skips trees that would duplicate what you already have, and reports how many tracks were found vs missing.
- **Corrupted Playlist Detection**: finds playlists foobar2000 cannot load and removes them safely.
  - Detects missing, empty, unreadable and wrong-format (Windows-path) `.fplite` files.
  - A crash-marker system identifies playlists that crash foobar2000 from inside the SDK, remembers them across sessions, and skips reading their track counts so startup survives.
  - Removal works on the files directly, avoiding the SDK call that crashes on exactly these playlists.
  - Preference: "Check for corrupted playlists on startup", plus a "Check Now" button.
- Fixed alongside those: a crash when a tree node had no name, a blank panel after a failed import, and startup crashes caused by reading track counts of known-bad playlists.

### Known limitations
- **Self-heal's automatic bookmark minting is still unproven in the field.** Whether resolving a file through the core is enough to make foobar2000 persist a bookmark is answered explicitly in the console on the next remount; if it turns out not to work, the one-click "Choose File…" prompt covers it.
- **A share mounted twice under different server addresses still yields two volumes.** macOS mounts `//host/music` and `//192.168.x.x/music` as separate volumes (`/Volumes/music` and `/Volumes/music-1`), and foobar2000 caches metadata separately for each. Plorg records only the mount point, so it cannot tell them apart. Avoid mounting the same share under two addresses at once.

### Documentation
- `../../docs/research/volume-uuid-instability-deep-research.md` — deep research on macOS volume identity, foobar's storage, and prior incident history.
- Updated `../../docs/VOLUME_UUID_ISSUE.md`.

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
