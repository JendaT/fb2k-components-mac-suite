# Changelog

All notable changes to Playlist Organizer will be documented in this file.

## [1.5.0] - Unreleased

Playlists on network drives broke on every remount: macOS assigns a fresh volume UUID and `mac-volume://` entries stop resolving. This release repairs that automatically and moves foobar2000's cached metadata along with it. It also carries the work developed as 1.4.0, which was never published.

### Added
- **Automatic Volume UUID Sync**: Repairs stale `mac-volume://` UUIDs in playlists after SMB/Tailscale remounts; runs at startup and on `/Volumes` changes. Off by default.
- **Volume self-heal**: Registers a mounted volume foobar2000 has no working bookmark for, then remaps the stale playlists. Off by default.
- **Metadb cache migration**: Moves cached metadata from the dead UUID to the live one after foobar2000 quits; backed up, transactional, verified and compacted.
- **Restart prompt**: Optional "Restart Now" after a repair. Off by default.
- **Finder file drop**: Drop files or folders onto a playlist node to append them (thanks @Scannou, #36).
- **FTH Theme Import**: Imports tree structure and tracks from old Windows foo_plorg themes, with Windows-to-macOS path mapping (developed as 1.4.0).
- **Corrupted Playlist Detection**: Finds and safely removes playlists foobar2000 cannot load, including ones that crash it (developed as 1.4.0).
- **`Scripts/metadb_cleanup.sh`**: Offline tool that reclaims metadb space left by dead-UUID metadata copies.

### Changed
- **Testable core**: Pure logic extracted into Foundation-only modules; 270 unit checks now gate every build.
- **Network Volumes off by default**: Power-user feature; opt in from Preferences.

### Fixed
- **Restart after repair**: No longer reopens foobar2000 while the database is being written, which caused "database is locked" and "metadb is corrupted" reports.
- **Concurrent migrations**: Only one migration runs per session; two were observed running at once.
- **Database growth**: Migrations now compact the file, which previously kept its largest-ever size permanently.
- **Migration safety**: Integrity-checked after migrating; the backup is restored on failure and removed on success.
- **Lower-case UUIDs**: Cached metadata could be deleted instead of migrated when a UUID was stored in lower case.
- **Volume path matching**: `/Volumes/music` and `/Volumes/music/` are now recognised as the same drive.
- **Config load failure**: No longer mistaken for an empty configuration, which could replace your saved folder tree.
- **Corrupted-playlist removal**: Backs files up before deleting; the quarantine list is no longer wiped when unreadable.
- **Malformed input crashes**: FTH files under 4 bytes, DeaDBeeF bad length fields, truncated YAML quotes, non-UTF-8 Vox names, and bad drag payloads.
- **Path traversal**: Crafted playlist paths can no longer escape their drive; manual remap validates the UUID first.
- **Import databases**: Vox and Strawberry libraries are opened read-only.
- **Repair Volume UUIDs window**: Closing it cancels cleanly, a backup failure re-enables it, and reopening reuses the existing window.
- **Backup pruning**: Locale-independent timestamps keep the newest backups on non-Gregorian calendars.
- **Delete-folder dialog**: Describes what actually happens to the playlists inside.
- **UTF-8 BOM**: Manual remap preserves it when rewriting playlist files.
- **Volume sync log**: Reports the real outcome instead of always claiming nothing to patch.
- **`/Volumes` monitor**: Coalesces event bursts into a single repair.
- **Build tooling**: Failed project regeneration aborts the build; compiler warnings are no longer filtered out.

### Known limitations
- **Self-heal minting**: Unproven in the field; the console states the outcome and a one-click prompt covers failure.
- **Duplicate mounts**: A share mounted under two addresses yields two volumes and two metadata copies; avoid mounting the same share twice at once.

### Documentation
- **Volume UUID research**: `../../docs/research/volume-uuid-instability-deep-research.md` covers macOS volume identity, foobar2000's storage and prior incidents.
- **Issue log**: Updated `../../docs/VOLUME_UUID_ISSUE.md`.

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
