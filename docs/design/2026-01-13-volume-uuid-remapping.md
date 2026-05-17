# Design: Network Volume UUID Remapping Tool

**Created**: 2026-01-13
**Status**: Approved
**Author**: via Claude Code

## 1. Overview

### Problem Statement

foobar2000 macOS uses `mac-volume://UUID/path` URLs to reference files on mounted volumes. While this works reliably for local volumes (USB, internal drives) where UUIDs are stored on the filesystem, network volumes (SMB/AFP/NFS) receive dynamically assigned UUIDs from macOS at mount time.

When a network share reconnects, the NAS reboots, or the share is remounted differently, macOS may assign a new UUID. This causes playlist entries using the old UUID to become orphaned - foobar cannot resolve them to the current mount, resulting in "Operation timed out" errors.

**Real-world example**: A single playlist had 1654 tracks pointing to `mac-volume://2C4962D1-.../music.hq/...` while the current mount used `mac-volume://CEF335FD-.../music.hq/...`. The metadb contained three different UUIDs for the same `/Volumes/music` share accumulated over time.

### Goals

- Provide a user-friendly tool to repair orphaned playlist entries caused by UUID changes
- Support mount point name remapping (e.g., `music` -> `music.hq`) for path reorganization
- Integrate seamlessly with Playlist Organizer's existing workflow
- Ensure data safety with preview and backup mechanisms

### Non-Goals (Out of Scope)

- Modifying metadb entries (playlist files only)
- Automatic/silent remapping without user confirmation
- Preventing UUID instability at the OS level
- Creating a permanent stable identifier system for network volumes

## 2. Background

### Current State

Users experiencing this issue must currently:
1. Manually identify the old and new UUIDs
2. Use command-line tools like `sed` to replace UUIDs in `.fplite` files
3. Restart foobar2000 to reload modified playlists

This is error-prone and requires technical knowledge most users don't have.

### Prior Art

**PathMappingWindowController** (`extensions/foo_jl_plorg_mac/src/UI/PathMappingWindowController.mm`):
- Existing component that handles Windows drive letter → macOS path mapping during Strawberry import
- Scans `.fplite` files for unique path prefixes
- Presents a UI for mapping discovered paths to local equivalents
- Uses background scanning with progress indication
- Follows the delegate pattern for completion callbacks

The UUID remapping tool should follow this established pattern.

### File Format

Playlist files (`.fplite`) are CSV format with one entry per line:
```
mac-volume://2C4962D1-XXXX-XXXX-XXXX/music.hq/Artist/Album/track.flac
mac-volume://CEF335FD-XXXX-XXXX-XXXX/music.hq/Artist/Album/other.flac
```

## 3. Detailed Design

### 3.1 User Experience

**Entry Point**: Context menu in Playlist Organizer
- Right-click anywhere in the tree view
- Select "Repair Volume UUIDs..."

**Workflow**:

```
1. User invokes "Repair Volume UUIDs..."
2. Tool scans all playlist files for mac-volume:// URLs
   - Progress bar: "Scanning playlists... (42/100)"
3. Groups entries by mount point name (path after UUID)
4. Queries system for currently mounted volumes and their UUIDs
5. Presents UI showing:
   - Discovered mount points with their UUIDs and entry counts
   - Which UUIDs are "active" (resolve to current mounts)
   - Which are "orphaned" (no matching current mount)
6. User selects remapping actions via checkboxes
7. Preview shows affected files and changes
8. User clicks Apply; tool re-validates volume state:
   - Re-query mounted volumes
   - Verify target UUIDs are still active
   - Verify source UUIDs are still orphaned (not reconnected)
   - If target UUID no longer active: show alert, require rescan
   - If source UUID now active: auto-remove from pending set, notify user
9. Tool creates backups and applies changes
   - Progress bar: "Applying changes... (15/23 files)"
10. Post-apply verification:
    - Check target volumes still mounted
    - If unmounted: warn "Target volume is no longer mounted. Changes applied but may not work until volume reconnects."
11. Summary dialog shows results
```

**Example UI State**:
```
Mount Point: music.hq
  Target: CEF335FD-... (1854 entries) [ACTIVE - /Volumes/music.hq]

  Remap to target:
  [x] 2C4962D1-... (1654 entries)
  [x] A1B2C3D4-... (423 entries)

  [ ] Also rename mount point to: [          ]
```

**Summary Dialog**:
```
Remapping Complete

Modified: 23 playlist files
Skipped: 2 files (see details)
Total entries updated: 2,077
Malformed entries skipped: 3

Backup saved to:
~/Library/foobar2000-v2/playlists-v2.0-backup/2026-01-13T10-30-00/

[Show in Finder]  [OK]

Note: Restart foobar2000 to apply changes.
```

Note: "Show in Finder" uses `NSWorkspace.selectFile(_:inFileViewerRootedAtPath:)` to highlight the backup directory directly.

### 3.2 Technical Approach

#### Volume Discovery

```objc
// Get currently mounted volumes with their UUIDs
NSArray<NSURL *> *volumes = [[NSFileManager defaultManager]
    mountedVolumeURLsIncludingResourceValuesForKeys:@[NSURLVolumeUUIDStringKey, NSURLVolumeNameKey]
    options:NSVolumeEnumerationSkipHiddenVolumes];

for (NSURL *volumeURL in volumes) {
    NSString *uuidString;
    [volumeURL getResourceValue:&uuidString forKey:NSURLVolumeUUIDStringKey error:nil];
    // uuidString matches the UUID in mac-volume:// URLs
}
```

#### URL Parsing

Extract components from `mac-volume://` URLs:
```
mac-volume://2C4962D1-XXXX-XXXX-XXXX/music.hq/Artist/Album/track.flac
             ^------------------------^ ^-------^ ^---------------------^
             UUID                       Mount     Relative path
                                        Point
```

**Validation Requirements**:
- URL must start with `mac-volume://`
- UUID must be 36 characters in standard format: `XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX`
- Must have at least one path component after UUID (the mount point)
- Malformed entries are skipped with a logged warning, not treated as errors
- UUID comparison is case-insensitive (macOS UUIDs may vary in case)

#### Matching Logic

1. Parse all `mac-volume://` URLs from playlist files
2. Group by first path component (mount point name)
   - Use **case-insensitive** comparison for grouping (macOS filesystems are case-insensitive)
   - Resolve symlinks using `realpath()` before comparing mount paths
3. For each group:
   - Check if any UUID matches a currently mounted volume
   - Mark matched UUIDs as "active"
   - Mark unmatched as "orphaned"
4. Handle edge cases:
   - Same UUID appearing with different mount points
   - Multiple active volumes with same mount point name: display full paths (e.g., `/Volumes/music.hq` vs `/Volumes/music.hq-1`) and require user to select canonical location

#### Replacement Strategy

For each orphaned UUID in a mount point group:
1. Find the target UUID (must be an active UUID that resolves to a current mount)
2. Optionally apply mount point rename
3. Replace: `mac-volume://OLD-UUID/old-mount/path` → `mac-volume://NEW-UUID/new-mount/path`

**Target UUID Validation**: The UI must only allow selecting an active UUID as the target. If no active UUID exists for a mount point group, the user must:
- Manually enter a UUID (advanced, with warning), OR
- Mount the target volume first, then rescan

### 3.3 API / Interface

#### UUIDRemappingWindowController

```objc
/// Error domain for UUID remapping operations
extern NSErrorDomain const UUIDRemappingErrorDomain;
typedef NS_ERROR_ENUM(UUIDRemappingErrorDomain, UUIDRemappingErrorCode) {
    UUIDRemappingErrorBackupFailed = 1,
    UUIDRemappingErrorFileWriteFailed = 2,
    UUIDRemappingErrorFileLocked = 3,
    UUIDRemappingErrorVolumeUnmounted = 4,
};

@protocol UUIDRemappingWindowDelegate <NSObject>
/// Called on main thread when remapping completes (with or without errors).
/// @param changedFiles Full paths to successfully modified playlist files
/// @param errors Array of NSError for files that failed (empty if all succeeded)
/// @note Unlike PathMappingWindowDelegate, this includes errors parameter because
///       UUID remapping has more failure modes (volume unmount, file locks, etc.)
- (void)uuidRemappingDidComplete:(UUIDRemappingWindowController *)controller
                   changedFiles:(NSArray<NSString *> *)changedFiles
                         errors:(NSArray<NSError *> *)errors;

/// Called on main thread when user cancels or closes window during operation.
- (void)uuidRemappingDidCancel:(UUIDRemappingWindowController *)controller;

@optional
/// Called on main thread for critical failures (backup creation failed, etc.)
/// If not implemented, controller shows alert and calls didCancel.
- (void)uuidRemappingDidFail:(UUIDRemappingWindowController *)controller
                       error:(NSError *)error;
@end

@interface UUIDRemappingWindowController : NSWindowController

@property (nonatomic, weak) id<UUIDRemappingWindowDelegate> delegate;

/// Begins asynchronous scanning of playlist files at the specified directory.
/// Returns immediately. Shows window and displays progress.
/// Scanning runs on background thread; delegate methods called on main thread.
/// Closing the window during scan triggers uuidRemappingDidCancel.
/// @param playlistsDir Directory containing .fplite files to scan
- (void)beginScanningWithPlaylistsDir:(NSString *)playlistsDir;

@end
```

#### Data Structures

```objc
// Represents a discovered mount point with its UUIDs
@interface MountPointGroup : NSObject
@property (nonatomic, copy) NSString *mountPointName;  // e.g., "music.hq"
@property (nonatomic, strong) NSArray<VolumeUUIDEntry *> *uuidEntries;
@property (nonatomic, strong, nullable) VolumeUUIDEntry *activeEntry;  // nil if none active
@end

// Represents a single UUID and its usage
@interface VolumeUUIDEntry : NSObject
@property (nonatomic, copy) NSString *uuid;
@property (nonatomic, assign) NSUInteger entryCount;  // Playlist entries, not unique tracks
@property (nonatomic, assign) BOOL isActive;  // Resolves to current mount
@property (nonatomic, copy, nullable) NSString *mountPath;  // /Volumes/... if active
@property (nonatomic, strong) NSSet<NSString *> *affectedPlaylistPaths;  // Full paths
@end

// User's remapping decision for a mount point
@interface RemappingAction : NSObject
@property (nonatomic, strong) MountPointGroup *group;
@property (nonatomic, copy) NSString *targetUUID;
@property (nonatomic, copy) NSString *newMountPointName;  // nil = keep original
@property (nonatomic, strong) NSSet<NSString *> *sourceUUIDs;  // UUIDs to replace
@end
```

### 3.4 Data Model

#### Scan Results Cache

During scanning, build an in-memory index (conceptual JSON representation):

```
{
  "music.hq": {
    "CEF335FD-...": {
      "entryCount": 1854,
      "active": true,
      "mountPath": "/Volumes/music.hq",
      "playlistPaths": ["/path/to/playlist-001.fplite", ...]
    },
    "2C4962D1-...": {
      "entryCount": 1654,
      "active": false,
      "playlistPaths": ["/path/to/playlist-003.fplite", ...]
    }
  },
  "backup-drive": {
    ...
  }
}
```

#### Playlist File Location

Playlist files are stored at:
```
~/Library/foobar2000-v2/playlists-v2.0/
```

This path should be resolved using fb2k SDK APIs if available, or the known default. Note: The directory name includes the format version (`2.0`), not just `v2`.

## 4. Implementation

### 4.1 Key Components

| Component | Responsibility |
|-----------|----------------|
| `UUIDRemappingWindowController` | Main UI controller, coordinates workflow |
| `PlaylistScanner` | Scans `.fplite` files, extracts `mac-volume://` URLs |
| `VolumeDiscovery` | Queries macOS for mounted volumes and their UUIDs |
| `RemappingEngine` | Applies URL replacements to playlist files |
| `BackupManager` | Creates timestamped backups before modifications |

### 4.2 Dependencies

**Internal:**
- Playlist Organizer's existing infrastructure
- Shared UI components (`PreferencesCommon.h`, `UIStyles.h`)

**System:**
- Foundation framework for volume enumeration
- AppKit for UI

**fb2k SDK:**
- Playlist file location discovery (if API available)
- Potentially: notify fb2k to reload modified playlists

### 4.3 File Modification Strategy

1. **Backup First**: Before any modifications, copy affected `.fplite` files to timestamped backup location:
   ```
   ~/Library/foobar2000-v2/playlists-v2.0-backup/2026-01-13T10-30-00/
   ```
   Note: Timestamp uses hyphens instead of colons (filesystem-safe).

   **Backup Retention**: Keep the last 5 backup directories. On each run, prune older backups automatically. Summary dialog shows backup location and offers "Show in Finder" for manual access.

2. **File Coordination**: Use `NSFileCoordinator` to safely access files that may be open by foobar2000:
   ```objc
   NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
   [coordinator coordinateWritingItemAtURL:fileURL
                                   options:NSFileCoordinatorWritingForReplacing
                                     error:&error
                                byAccessor:^(NSURL *newURL) {
       // Perform modification here
   }];
   ```
   If coordination fails (file locked), report error and skip that file.

3. **Atomic Writes**: Use simple atomic write (handles temp file + rename internally):
   ```objc
   NSError *error = nil;
   BOOL success = [newContent writeToFile:filePath
                               atomically:YES
                                 encoding:NSUTF8StringEncoding
                                    error:&error];
   ```

4. **Partial Failure Handling**: On failure during modification phase:
   - Continue attempting remaining files (don't abort batch)
   - Collect all errors and present summary at end
   - If critical failure (disk full), offer rollback from backup
   - Never leave user without knowing which files succeeded/failed

5. **Reload Notification**: After changes, user must restart foobar2000 to reload modified playlists. Display clear message: "Restart foobar2000 to apply changes."

## 5. Considerations

### 5.1 Edge Cases

| Case | Handling |
|------|----------|
| No orphaned UUIDs found | Show "All playlists are healthy" message |
| Multiple active volumes with same mount point | Warn user, require explicit selection |
| UUID appears with multiple different mount points | Group by mount point, handle separately |
| Empty playlists | Skip during scan |
| Non-UTF8 playlist content | Handle gracefully, skip affected files |
| Playlist in use by foobar | May fail to write; prompt user to close |

### 5.2 Error Handling

| Error | Response |
|-------|----------|
| Cannot read playlist file | Log warning, continue with others |
| Cannot write playlist file | Show error, offer to skip or abort |
| Backup directory creation fails | Abort with clear error message |
| No playlists directory found | Show "No playlists found" message |

### 5.3 Performance

- **Scanning**: Background thread with progress indication
- **File I/O**: Batch reads, avoid repeated file opens
- **Memory**: Stream large files if needed (unlikely for playlists)
- **Cancellation**: Support cancellation during scan phase

Typical scenario: ~100 playlists, ~50K total entries. Should complete in <5 seconds.

### 5.4 Security

- Only reads/writes to known playlist directory
- Validates URLs before parsing (no arbitrary file access)
- Creates backups with restricted permissions
- No network access required

**Sandbox Consideration**: Verify foobar2000 macOS sandbox entitlements. If sandboxed, access to `~/Library/foobar2000-v2/` may require appropriate entitlements. The backup directory must be in an accessible location (likely same directory as playlists, which we already have access to).

### 5.5 Localization

All user-facing strings must use `NSLocalizedString(@"key", @"comment")` for future localization support. Create `UUIDRemapping.strings` for this feature.

Key strings requiring localization:
- Menu item: "Repair Volume UUIDs..."
- Window title: "UUID Remapping"
- Progress messages: "Scanning playlists...", "Applying changes..."
- Status labels: "ACTIVE", "ORPHANED"
- Summary dialog text
- Error messages

Use `NSNumberFormatter` with `NSNumberFormatterDecimalStyle` for locale-appropriate number formatting (entry counts, file counts).

### 5.6 Accessibility

VoiceOver and keyboard navigation support required:

- **Outline/table views**: Provide accessibility descriptions for mount point groups
- **Checkboxes**: Use meaningful labels like "Remap UUID 2C49... (1654 entries)" not just the UUID
- **Status indicators**: Orphaned/Active status must be conveyed via accessibility labels, not just visual styling
- **Progress**: Announce progress changes via `NSAccessibilityPostNotification`
- **Buttons**: All buttons need accessibility labels ("Show backup in Finder", "Apply remapping")
- **Keyboard**: Support Tab navigation, Space to toggle checkboxes, Return to apply

## 6. Alternatives Considered

### Alternative A: SDK-Based Playlist Modification

Modify playlists through fb2k SDK APIs rather than direct file editing.

**Pros:**
- No file format dependency
- Changes reflected immediately without restart
- SDK handles locking/concurrency

**Cons:**
- May not have API access to modify playlist item paths
- More complex implementation
- SDK behavior may vary between versions

**Why rejected:** Direct file modification is simpler and follows existing PathMappingWindowController pattern. SDK approach can be explored as future enhancement if needed.

### Alternative B: External Script Tool

Provide a standalone Python/shell script instead of integrated UI.

**Pros:**
- Simpler to implement
- Can be used without running foobar

**Cons:**
- Poor user experience
- Requires technical knowledge
- No preview/confirmation flow

**Why rejected:** Users already struggle with manual sed commands. Integrated UI is essential for accessibility.

### Alternative C: Automatic Detection on Volume Mount

Detect when a volume mounts and auto-prompt for remapping.

**Pros:**
- Proactive problem prevention
- More convenient timing

**Cons:**
- Requires background process/daemon
- Complex to implement reliably
- May be annoying if volumes change frequently

**Why rejected:** Overengineered for initial implementation. Can add as enhancement later.

## 7. Open Questions

- [ ] Is there an SDK API to programmatically reload playlists after modification, or must user restart foobar?
- [ ] Should we persist a "known UUID mappings" history to auto-suggest remappings?
- [ ] What's the exact path discovery method for playlists directory via SDK vs hardcoded default?
- [ ] Should the tool warn if applying changes while foobar has unsaved playlist modifications?
- [ ] Does `NSURLVolumeUUIDStringKey` return the exact same UUID format as `mac-volume://` URLs? (Verify empirically before implementation)
- [ ] Should the tool support `.fpl` files in addition to `.fplite`, or is `.fplite` the only format used for mac-volume:// URLs?
- [ ] What happens if user has unsaved playlist edits in foobar2000 and restarts after our modifications? (foobar2000's save-on-exit behavior needs investigation)
- [ ] Does foobar2000 use file-level locking (flock/POSIX locks) on playlist files? NSFileCoordinator only helps if both parties participate.
- [ ] Do AFP, SMB, and NFS volumes all expose UUIDs via `NSURLVolumeUUIDStringKey`? Test empirically, especially for NFS.
- [ ] Should read-only playlist directories be detected upfront during scan rather than failing at apply time?
- [ ] Should the window be modal or modeless? If modeless, what happens if invoked twice?
- [ ] What logging prefix to use? `[PlOrg]` or `[PlOrg/UUID]`?

## 8. Future Enhancements

1. **Remember mappings**: Store UUID→UUID mappings for future automatic suggestions
2. **Auto-detect on mount**: Prompt when orphaned UUIDs could be resolved by newly mounted volume
3. **metadb support**: Extend to fix metadata database entries (requires SDK investigation)
4. **Undo support**: Allow reverting changes from backup without manual file restoration
5. **Batch volume management**: Generalized "Volume Manager" panel showing all known volumes and their status

---

## Appendix

### References

- PathMappingWindowController.mm - Existing path mapping implementation
- [Apple: Mounted Volume Keys](https://developer.apple.com/documentation/foundation/nsurlresourcekey)
- foobar2000 macOS playlist format (.fplite)

### Changelog

| Date | Change |
|------|--------|
| 2026-01-13 | Initial draft |
| 2026-01-13 | Review 1: Fixed playlists path, added file coordination, URL validation, threading docs, partial failure handling |
| 2026-01-13 | Review 2: Fixed PathMappingWindowController path, added error callback to delegate, volume re-validation before apply, backup retention policy, improved UI mockups, renamed trackCount to entryCount |
| 2026-01-13 | Review 3: Bidirectional race condition fix (source + target validation), post-apply volume check, case-insensitive mount point matching, symlink resolution, sandbox notes, malformed entries in summary |
| 2026-01-13 | Review 4: Added error domain/codes, updated API to match existing pattern (playlistsDir parameter), added localization and accessibility sections, documented delegate protocol divergence rationale |
| 2026-01-13 | Review 5: Final review - Approved for implementation |
