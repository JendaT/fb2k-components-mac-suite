# Deep Research: macOS Network Volume UUID Instability

**Date**: 2026-04-11
**Context**: foobar2000 macOS stores file references as `mac-volume://UUID/path`. SMB network volumes receive ephemeral UUIDs from macOS at mount time. Every remount orphans all playlist entries and creates duplicate metadb rows. This document captures comprehensive research into the problem, its scope, and potential solutions.

---

## Table of Contents

1. [How macOS Identifies Volumes](#1-how-macos-identifies-volumes)
2. [Why SMB Volume UUIDs Are Unstable](#2-why-smb-volume-uuids-are-unstable)
3. [How foobar2000 Stores File References](#3-how-foobar2000-stores-file-references)
4. [Current Damage Assessment](#4-current-damage-assessment)
5. [Existing UUID Remapping Tool](#5-existing-uuid-remapping-tool)
6. [How Other Apps Handle This](#6-how-other-apps-handle-this)
7. [macOS Volume Monitoring APIs](#7-macos-volume-monitoring-apis)
8. [Volume Identity Extraction Strategies](#8-volume-identity-extraction-strategies)
9. [foobar2000 Changelog: Network Volume Fixes](#9-foobar2000-changelog-network-volume-fixes)
10. [Solution Patterns](#10-solution-patterns)
11. [Tailscale-Specific Considerations](#11-tailscale-specific-considerations)
12. [Open Questions and Risks](#12-open-questions-and-risks)

---

## 1. How macOS Identifies Volumes

### Local Volumes (APFS, HFS+)

Local volumes store a persistent UUID on the filesystem itself. This UUID is stable across remounts, reboots, and system changes. It can be retrieved via:

- `NSURLVolumeUUIDStringKey` (NSURL resource key)
- `getattrlist()` with `ATTR_VOL_UUID`
- `DiskArbitration` framework (`kDADiskDescriptionVolumeUUIDKey`)

### Network Volumes (SMB, AFP, NFS)

Network volumes have **no persistent UUID**. The `NSURLVolumeUUIDStringKey` returns `nil` for SMB mounts. Any UUID that macOS assigns internally is:

- **Ephemeral**: generated at mount time, not stored on the remote filesystem
- **Not exposed through standard APIs**: `NSURLVolumeUUIDStringKey` returns nil
- **Unstable**: a new mount gets a new internal identifier

Despite this, foobar2000 obtains a UUID for network volumes (likely via DiskArbitration's `kDADiskDescriptionVolumeUUIDKey` or a similar low-level mechanism). This UUID is valid only for the duration of that specific mount session.

### Available Volume Identification APIs

| API | What It Returns | Works for SMB? |
|-----|----------------|----------------|
| `NSURLVolumeUUIDStringKey` | Volume UUID string | Returns nil |
| `NSURLVolumeURLForRemountingKey` | SMB URL (e.g., `smb://server/share`) | Yes |
| `NSURLVolumeNameKey` | Volume display name | Yes |
| `NSURLVolumeIsLocalKey` | Boolean | Yes (returns NO) |
| `getattrlist()` + `ATTR_VOL_UUID` | `uuid_t` | May return zeros |
| `statfs()` `f_fsid` | Filesystem ID pair | Unstable across remounts |
| `statfs()` `f_mntfromname` | Mount source (e.g., `//user@192.168.1.10/share`) | Yes |
| `statfs()` `f_mntonname` | Mount point (e.g., `/Volumes/music.hq`) | Yes |
| `DiskArbitration` `kDADiskDescriptionVolumeUUIDKey` | Volume UUID | May work, but value is ephemeral |
| `DiskArbitration` `kDADiskDescriptionVolumePathKey` | Mount path | Yes |

### Mount Point Assignment

SMB shares mount at `/Volumes/{ShareName}` with collision avoidance:

- First mount: `/Volumes/music.hq`
- Collision (stale mount point exists): `/Volumes/music.hq-1`
- Second collision: `/Volumes/music.hq-2`

Volume names are normalized to **Unicode Form D** (decomposed) and compared **case-insensitively**. Orphaned mount points from crashes or stale connections cause numbering suffix changes.

Custom mount points can be specified: `mount_smbfs //user@server/share /custom/path`

---

## 2. Why SMB Volume UUIDs Are Unstable

### Triggers for UUID Change

| Trigger | UUID Changes? | Mount Path Changes? |
|---------|--------------|-------------------|
| Reboot | Yes | Possibly (stale mount points) |
| Wake from sleep (SMB disconnects) | Yes (on remount) | Possibly |
| Network change (LAN to Tailscale) | Yes (different IP = different volume) | Yes (if old mount exists) |
| Same IP, same hostname remount | Yes | No (usually) |
| NAS reboot | Yes (on client remount) | No (usually) |
| macOS update | Yes (if mount config changes) | Possibly |
| Stale mount point exists | N/A | Yes (gets `-1` suffix) |

### The LAN/Tailscale Double Problem

When the same SMB server is accessible via:
- LAN: `smb://192.168.1.10/music.hq` -> `/Volumes/music.hq`
- Tailscale: `smb://100.64.0.5/music.hq` -> `/Volumes/music.hq` (or `/Volumes/music.hq-1`)

macOS treats these as **completely separate volumes**. They get separate mount points, separate internal identifiers, and separate bookmarks. There is no built-in mechanism to recognize they point to the same remote share.

### f_fsid Unreliability

The `statfs.f_fsid` field is designed for unique file identification within a volume but:
- Not persistent across unmount/remount cycles for SMB
- Invalid after network interruption
- macOS logs show `smb_remount_with_fsid: Could remount url` failures (error 45)

### NSURL Bookmark Limitations

NSURL bookmarks store volume UUID, path, and inode. For network volumes:
- Volume UUID stored is nil (SMB)
- `URLByResolvingBookmarkData` may attempt to **mount** the volume, causing hangs
- If both path and inode change (which happens on remount), resolution fails completely
- Unicode normalization issues on SMB (`fileSystemRepresentation` decomposes paths)
- Security-scoped bookmarks for SMB had bugs through macOS 26.0 (fixed in 26.1)

### macOS Tahoe (26) Regressions

- Automounting SMB shares no longer works reliably on restart
- SMB signing/encryption changes broke compatibility with many NAS devices
- Partially fixed in macOS 26.4

---

## 3. How foobar2000 Stores File References

### Path Format

All file references use `mac-volume://` URLs:

```
mac-volume://CEF335FD-7517-7476-B480-BBBA66464B89/music.hq/Artist/Album/track.flac
             ^---------- UUID --------------------^ ^----^ ^----- relative path -----^
                                                    mount
                                                    point
```

### Storage Locations

| Location | Format | Purpose |
|----------|--------|---------|
| `.fplite` files | UTF-8 text, one URL per line | Playlist entries |
| `metadb.sqlite` | SQLite database | Track metadata cache |
| `content.sqlite` (library) | SQLite database | Media library index |
| `folders` config | Text | Library folder paths |

### Key SDK Classes

| Class | Purpose |
|-------|---------|
| `playable_location_impl` | Stores `mac-volume://UUID/path` + subsong index |
| `metadb_handle` | Reference to track in metadb database |
| `filesystem` | Abstract handler for local/archive/remote files |
| `playlist_loader` | Playlist file parsing |

### Path Resolution Flow

1. `playable_location` stores path as `mac-volume://UUID/path`
2. `metadb::handle_create()` creates `metadb_handle` for that location
3. `filesystem::g_get_interface()` finds appropriate handler
4. Handler resolves UUID to mount point, constructs native path
5. If UUID doesn't match any mounted volume: **resolution fails** -> "Operation timed out"

### Platform Helpers

In `helpers-mac/fb2k-platform.mm`:
- `urlFromPlatform()`: Converts NSURL/NSString to canonical `mac-volume://` path
- `urlToPlatform()`: Creates NSURL from foobar path via `filesystem::g_get_native_path()`

### Relative Paths

The SDK supports `relative_path_create()` / `relative_path_parse()` for paths relative to playlist location, but this is rarely used. Most entries are absolute `mac-volume://` URLs.

---

## 4. Current Damage Assessment

Data collected 2026-04-11 from `~/Library/foobar2000-v2/`.

### Database Size

| File | Size |
|------|------|
| `metadb.sqlite` | **5.7 GB** (3.99 GB used, 1.7 GB freelist) |
| `library-v2.0/.../content.sqlite` | 96 MB |
| Total foobar2000 data directory | 6.1 GB |

### Duplicate Analysis

| Metric | Count |
|--------|-------|
| Total metadb entries | 225,292 |
| `mac-volume://` entries | 222,407 |
| `file://` entries | 1,136 |
| Other (tidal, mixcloud, soundcloud, `/Volumes/`) | 1,749 |
| **Unique file paths** | **155,059** |
| **Duplicate entries (same path, different UUID)** | **67,348 (30%)** |
| Estimated wasted space | ~1.15 GB |

### Volume UUIDs Found (12 total, same SMB share)

| UUID | Entries | Status |
|------|---------|--------|
| `CEF335FD-7517-7476-B480-BBBA66464B89` | 154,844 | **Current (library)** |
| `E4D2D653-7C09-724D-BBC8-E8E0DCE8AB2F` | 19,148 | Stale |
| `1998A73C-D4D2-23A1-D179-EB8E0C71035A` | 18,286 | Stale |
| `F828CB29-AE7E-F8EF-B365-3B264775FE65` | 11,069 | Stale |
| `CFA535CA-9B1A-B84E-33C6-30D0FABC1BA7` | 9,772 | **Playlists use this (stale!)** |
| `DCB127C0-BC09-D60C-D2DF-A28C573E10CE` | 8,731 | Stale |
| `0016E2CA-5493-D6A0-B129-ED8214CDD607` | 384 | Stale |
| `E1876595-E3BB-8AAF-4A44-D0792D825F2F` | 117 | Stale |
| 4 others | 56 combined | Stale |

### Duplication Severity

| Copies Per File | Unique Files Affected | Wasted Entries |
|----------------|----------------------|----------------|
| 2 copies | 36,002 | 36,002 |
| 3 copies | 1,295 | 2,590 |
| 4 copies | 9,436 | 28,308 |
| 5 copies | 112 | 448 |
| **Total** | **46,845 files** | **67,348** |

### Critical: Library/Playlist UUID Mismatch

The library (`content.sqlite`) and `folders` config currently use UUID `CEF335FD-...`, but **all 24 active playlist `.fplite` files reference UUID `CFA535CA-...`** (set by the UUID remap tool on 2026-03-24). The volume UUID changed *again* after the last manual remap.

Timeline:
1. Various UUIDs accumulated over time (12 total)
2. 2026-03-24: Manual remap unified all playlists to `CFA535CA`
3. Between then and now: volume remounted with UUID `CEF335FD`
4. All playlists now point to stale `CFA535CA` -> items show as empty/unresolved

---

## 5. Existing UUID Remapping Tool

### Architecture

The manual UUID remapping tool was implemented in January 2026 as part of Plorg:

**Files:**
- `UUIDRemappingWindowController.h` (131 lines)
- `UUIDRemappingWindowController.mm` (1343 lines)
- Entry point: `PlaylistOrganizerController.mm` `repairVolumeUUIDs:` (line 3187)

### Data Structures

- **`VolumeUUIDEntry`**: UUID, entry count, active status, mount path, affected playlists, per-playlist counts
- **`MountPointGroup`**: Groups UUIDs by mount point name, identifies active vs orphaned entries
- **`RemappingAction`**: User's remapping decision (source UUIDs -> target UUID)

### Flow

1. User invokes "Repair Volume UUIDs..." from context menu
2. Discovers mounted volumes via `NSFileManager` + DiskArbitration fallback
3. Scans all `.fplite` files for `mac-volume://UUID/` prefixes (background thread)
4. Groups by mount point, identifies active vs orphaned UUIDs
5. Presents UI with checkboxes for selecting source (orphaned) and target (active) UUIDs
6. Creates timestamped backup (`backup_uuid_remap_YYYY-MM-DD_HHmmss/`)
7. Performs string replacement: `mac-volume://OLD_UUID/` -> `mac-volume://NEW_UUID/`
8. Requires foobar2000 restart

### Volume Discovery Methods

1. **Primary**: `NSFileManager mountedVolumeURLsIncludingResourceValuesForKeys:` with `NSURLVolumeUUIDStringKey`
2. **Fallback**: `volumeUUIDForPath:` using DiskArbitration framework (`DADiskCopyDescription`)
3. **Network volume fallback**: `findUUIDForVolumePath:` -- iterates discovered UUIDs, tests file existence on each volume, picks UUID with fewest entries (heuristic: most recently assigned UUID has fewer accumulated entries)

### Scope Options

- **All Playlists**: processes every `.fplite` file
- **Single Playlist**: only the selected playlist (via index.txt UUID -> `.fplite` file lookup)

### Limitations

1. **Manual only**: user must notice the problem and invoke the tool
2. **Requires restart**: foobar must be restarted after remapping
3. **No metadb cleanup**: only fixes playlist files, not the bloated metadb
4. **Heuristic active UUID detection**: "fewest entries wins" can fail if old UUID accumulated fewer entries
5. **No rollback on partial failure**: if file N fails, files 1..N-1 are already modified
6. **No target UUID validation**: user can enter any UUID string, no check that it's actually mounted
7. **No persistence**: doesn't remember UUID history for future auto-suggestions

---

## 6. How Other Apps Handle This

### Summary Table

| App | Storage | Network Volume Handling | Auto-Repair |
|-----|---------|----------------------|-------------|
| iTunes/Music.app | Absolute paths | Shows exclamation mark (missing) | No (manual locate) |
| Plex | Absolute paths in SQLite | Shows "unavailable" | No (users do SQL REPLACE) |
| Lightroom | Absolute paths in catalog | Shows question mark | Semi (Update Folder Location UI) |
| Final Cut Pro | Volume name + path | Won't find media if name changes | Semi (Relink dialog with proximity matching) |
| Logic Pro | Absolute paths | Missing files dialog | No (manual relocate) |
| Kodi/XBMC | Absolute paths | **Path Substitution** in config XML | Yes (config-based) |
| PhotoStructure | `.uuid` file + relative path | Stable via user-controlled UUID file | Yes (fully automatic) |
| Mixxx | Absolute paths | Relink UI | Semi |

### Notable Approaches

**PhotoStructure** (most relevant precedent):
- Places a `.uuid` file in each volume root directory
- Resolution chain: check for `.uuid` file -> try system UUID API -> generate random UUID and write `.uuid`
- Uses `psfile://` URIs with shortened volume UUIDs that remain stable regardless of mount path
- Requires write access to volume root

**Kodi**:
- `advancedsettings.xml` path substitution rules
- Recommends hostname-based SMB paths and hosts file for IP mapping
- Direct database path updates via SQL also supported

**Key insight**: No major media app solves this automatically. The UUID auto-sync we're designing would be genuinely novel.

---

## 7. macOS Volume Monitoring APIs

### NSWorkspace Notifications

| Notification | Fires for SMB? |
|-------------|----------------|
| `didMountNotification` | Unreliable for network volumes |
| `didUnmountNotification` | Unreliable |
| `willUnmountNotification` | Unreliable |
| `didRenameVolumeNotification` | Unreliable |

**Critical**: NSWorkspace specifically excludes network volumes from its notification machinery. These notifications may not fire for SMB mount/unmount events. Must observe on `NSWorkspace.shared.notificationCenter`, NOT `NotificationCenter.default`.

### DiskArbitration Framework

More reliable for network volumes:
- Callbacks: `DADiskAppearedCallback`, `DADiskDisappearedCallback`, `DADiskDescriptionChangedCallback`
- Approval callbacks for mount/eject/unmount
- Matching dictionaries can filter by protocol, volume type
- Requires session scheduling on dispatch queue or run loop

**Caveat**: Some sources say SMB/AFP shares are NOT managed by DiskArbitration and won't appear. Needs empirical testing.

### DispatchSource / kqueue

```objc
int fd = open("/Volumes", O_EVTONLY);
dispatch_source_t source = dispatch_source_create(
    DISPATCH_SOURCE_TYPE_VNODE, fd,
    DISPATCH_VNODE_WRITE | DISPATCH_VNODE_LINK,
    dispatch_get_main_queue());
dispatch_source_set_event_handler(source, ^{
    // Something changed in /Volumes -- enumerate and compare
});
dispatch_resume(source);
```

- Watches `/Volumes` for directory changes (new/removed mount points)
- Fast, event-driven
- Doesn't tell you *what* mounted, just that something changed
- May have sandbox limitations

### FSEvents

- Watches directory trees for filesystem changes
- Can watch `/Volumes` for mount point changes
- Path-based, not descriptor-based
- Less granular than DispatchSource for this use case

### Recommended Approach

1. **DispatchSource** on `/Volumes` for event-driven detection (fast, low overhead)
2. On change: enumerate mounted volumes, compare against known state
3. Extract SMB share identity from `volumeURLForRemountingKey` or `statfs.f_mntfromname`
4. Fall back to periodic polling (every ~60s) as belt-and-suspenders

---

## 8. Volume Identity Extraction Strategies

### The Core Problem

We need a **stable identifier** for a network share that doesn't change across:
- Different IPs (LAN vs Tailscale)
- Remounts
- Reboots
- Mount point collisions

### Strategy Comparison

| Strategy | Stable Across IPs? | Stable Across Remounts? | Implementation |
|----------|-------------------|------------------------|----------------|
| macOS UUID | No | No | `NSURLVolumeUUIDStringKey` |
| Mount path | No (collisions) | No | `statfs.f_mntonname` |
| SMB URL | No (different IP) | Yes (same IP) | `volumeURLForRemountingKey` |
| **Share name only** | **Yes** | **Yes** | Parse from SMB URL or mount path |
| `.uuid` file on volume | Yes | Yes | Read file from volume root |
| Server hostname + share | Mostly (DNS) | Yes | Parse SMB URL, resolve hostname |

### Share Name Extraction

The **share name** is the most stable identifier available without requiring write access to the volume:

From `statfs.f_mntfromname`:
```
//user@192.168.1.10/music.hq  ->  share name: "music.hq"
//user@100.64.0.5/music.hq    ->  share name: "music.hq"
```

From `volumeURLForRemountingKey`:
```
smb://192.168.1.10/music.hq  ->  share name: "music.hq"
```

From mount path (less reliable due to collision suffixes):
```
/Volumes/music.hq    ->  "music.hq"
/Volumes/music.hq-1  ->  "music.hq" (must strip suffix)
```

### Matching Algorithm

For each mounted volume:
1. Get `f_mntfromname` via `statfs()` -> extract share name
2. Get current UUID via DiskArbitration or NSURL APIs
3. Compare share name against known shares in playlists
4. If share name matches but UUID differs -> UUID changed, needs remap

### Limitation: Non-Unique Share Names

If the user has two different SMB servers both sharing a volume called `music`, the share name alone isn't sufficient. Mitigation:
- Also compare total file count or sample file existence
- Ask user to disambiguate on first encounter
- Store server identity alongside share name

In practice this is rare -- most users have one NAS.

---

## 9. foobar2000 Changelog: Network Volume Fixes

From the official foobar2000 Mac changelog, entries related to network volumes:

| Version | Date | Entry |
|---------|------|-------|
| 2.25.7 | 2026-02-19 | Mitigation for bugs in Apple's SMB support and folder watching. Moving folders with specific Unicode characters no longer results in duplicate library items. |
| 2.25.4 | 2025-12-30 | Fixed various regressions with network shares in Media Library preferences page. Fixed error with renaming files on redirected macOS volumes. |
| 2.25.3 | 2025-10-29 | Fixed bad interaction between WebDAV filesystem and media library. |
| 2.25 | 2025-09-01 | Can natively index FTP/WebDAV/SMB network shares. |
| 2.24 | 2024-11-25 | Cuesheet compatibility - allowed absolute path, allowed playback over network. |

From Mac 2.5 beta changelog (Hydrogenaudio wiki):

| Beta | Entry |
|------|-------|
| Beta 5 | Fixed incorrect behavior after a watched media library folder disappears then reappears. |
| Beta 11 | **Fixed lockup bug with stale/dead net shares in Media Library.** |
| Beta 16 | **Ratings and statistics pinned to metadata instead of location.** (Specifically because file locations are unstable on network volumes.) |
| Beta 17 | **Fixed beachballing on app shutdown when indexed network shares cannot be resolved.** |

The Beta 16 change is significant: foobar2000 already recognized that pinning data to file location is fragile and moved playback stats to metadata-based identity. The playlist file format, however, still uses `mac-volume://UUID/path` and has no equivalent migration.

---

## 10. Solution Patterns

### Pattern A: Startup Auto-Repair

**When**: `initquit::on_init`, before foobar loads playlists into memory.

**How**:
1. Enumerate mounted volumes, build `share_name -> current_UUID` mapping
2. Quick-scan `.fplite` files for `mac-volume://` prefixes, extract UUIDs
3. If any playlist UUID doesn't match current UUID for that share -> remap
4. String-replace in `.fplite` files, create backup first
5. foobar then loads the corrected playlists

**Advantage**: Transparent, no user action needed. Playlists are always correct when foobar finishes launching.

**Risk**: Modifying `.fplite` files before foobar loads them. Need to verify foobar hasn't already read them by the time `on_init` runs. If it has, may need to trigger a playlist reload.

**Open question**: Does foobar load playlists before or after `initquit::on_init`? The init order matters critically.

### Pattern B: Runtime Volume Monitor

**When**: Continuously while foobar is running.

**How**:
1. Watch `/Volumes` via DispatchSource for mount/unmount events
2. On new mount: check if its share name matches any stale UUIDs in playlists
3. Remap `.fplite` files in background
4. Trigger foobar playlist reload (if SDK supports it)

**Advantage**: Handles mid-session volume reconnections (e.g., wake from sleep, network change).

**Risk**: Modifying `.fplite` files while foobar has playlists loaded in memory. If foobar caches playlist content in RAM and writes it on quit, our file changes get overwritten. Need to either:
- Use foobar SDK to modify playlist items in memory (preferred if API exists)
- Modify files and force a reload
- Modify files and set a flag to skip foobar's save-on-quit for those playlists

**Open question**: Can `playlist_manager` API modify item paths in loaded playlists? If so, this becomes much simpler -- no file I/O needed, changes are immediate and persistent through foobar's normal save.

### Pattern C: metadb Cleanup

**When**: Periodically or on user request.

**How**:
1. Query metadb.sqlite for all `mac-volume://` entries
2. Group by relative path (strip UUID prefix)
3. For paths with multiple UUIDs: keep only the current UUID entry, delete others
4. VACUUM the database to reclaim freelist space

**Risk**: Direct SQLite manipulation of foobar's database while it's running. Should only be done with foobar stopped, or via the SDK's `metadb` APIs if available.

**Estimated savings**: ~1.15 GB of data + 1.7 GB freelist = 2.85 GB recoverable.

### Pattern D: Persistent UUID Mapping Store

Maintain a config-persisted mapping of `share_name -> [UUID_history]`:

```yaml
volume_mappings:
  music.hq:
    current_uuid: CEF335FD-7517-7476-B480-BBBA66464B89
    known_uuids:
      - CFA535CA-9B1A-B84E-33C6-30D0FABC1BA7
      - E4D2D653-7C09-724D-BBC8-E8E0DCE8AB2F
      - 1998A73C-D4D2-23A1-D179-EB8E0C71035A
      # ... etc
    smb_urls:
      - smb://192.168.1.10/music.hq
      - smb://100.64.0.5/music.hq
    last_seen: 2026-04-11
```

This allows:
- Instant startup check: is the UUID in playlists one of our known UUIDs?
- No need to scan playlists if UUID hasn't changed since last run
- Historical tracking for debugging

---

## 11. Tailscale-Specific Considerations

### The Dual-IP Problem

Tailscale assigns each device a stable `100.x.y.z` IP within the tailnet. When connecting to the same SMB share:

- Home LAN: `smb://192.168.1.10/music.hq` -> UUID-A
- Via Tailscale: `smb://100.64.0.5/music.hq` -> UUID-B

These are treated as completely separate volumes by macOS. Both may be mounted simultaneously (at different mount points), or the user may switch between them.

### Samba Server Configuration

The Samba server may need configuration to accept connections on the Tailscale interface:
- `interfaces` should include `tailscale0`
- `bind interfaces only = no` (or explicitly list Tailscale interface)
- NetBIOS should typically be disabled for Tailscale

### Taildrive Alternative

Tailscale offers "Taildrive" (`100.100.100.100:8080`) as an alternative to SMB. This avoids the dual-IP problem entirely but requires all participants to use Tailscale and may have performance implications.

### Solution Implication

The share name extraction strategy naturally handles the Tailscale case:
- `//user@192.168.1.10/music.hq` -> share name: `music.hq`
- `//user@100.64.0.5/music.hq` -> share name: `music.hq`

Same share name -> same logical volume -> auto-remap works.

---

## 12. Open Questions and Risks

### Critical (Must Answer Before Implementation)

1. **Init order**: Does foobar load playlists before or after `initquit::on_init`? This determines whether startup repair can modify files before they're read.

2. **Playlist reload API**: Can `playlist_manager` reload playlists from disk without a full restart? If yes, both startup and runtime repair become much simpler.

3. **In-memory path modification**: Can `playlist_manager` or `metadb` APIs change the `mac-volume://` path of existing playlist items? If yes, runtime repair can work entirely through the SDK without touching files.

4. **Save-on-quit behavior**: Does foobar write playlist state from memory to `.fplite` on quit? If so, runtime file modifications would be overwritten.

5. **DiskArbitration for SMB**: Do SMB volumes actually appear via DiskArbitration callbacks? Conflicting reports -- needs empirical testing.

### Important (Should Answer)

6. **Share name uniqueness**: Is it safe to assume the user has only one SMB share per share name? If not, need additional disambiguation.

7. **metadb direct access**: Can we safely modify `metadb.sqlite` while foobar is running, or must we use SDK APIs?

8. **UUID format consistency**: Is the UUID format in `mac-volume://` URLs exactly the same format returned by DiskArbitration / NSURL APIs? (Case, dashes, length.) Already confirmed uppercase with dashes in existing code.

9. **Timing of UUID assignment**: At what point during mount does macOS assign the volume UUID? Is there a race condition where foobar could see a volume before its UUID is assigned?

### Nice to Know

10. **foobar2000 developer contact**: Has Peter (foobar dev) been asked about adding native UUID stability? The changelog shows he's aware of network volume issues.

11. **APFS volume UUID stability for SMB**: Does the remote filesystem type (APFS on NAS vs ext4 on Linux) affect UUID assignment behavior on the client side?

12. **Multiple simultaneous mounts**: What happens if both LAN and Tailscale mounts are active simultaneously? Do playlists work with either, or only the one matching their UUID?

---

## References

### Apple Documentation
- [NSURLVolumeURLForRemountingKey](https://developer.apple.com/documentation/foundation/nsurlvolumeurlforremountingkey)
- [getattrlist(2) man page](https://keith.github.io/xcode-man-pages/getattrlist.2.html)
- [DiskArbitration Programming Guide](https://developer-rno.apple.com/library/archive/documentation/DriversKernelHardware/Conceptual/DiskArbitrationProgGuide/ArbitrationBasics/ArbitrationBasics.html)
- [statfs f_fsid documentation](https://developer.apple.com/documentation/kernel/statfs/1523533-f_fsid)

### Third-Party Analysis
- [The Eclectic Light Company: Volume names, mount points and normalisation](https://eclecticlight.co/2023/05/16/volume-names-mount-points-and-normalisation/)
- [PhotoStructure: What is a Volume](https://photostructure.com/faq/what-is-a-volume/)
- [Chris Dzombak: Keeping a SMB share mounted on macOS](https://www.dzombak.com/blog/2024/03/Keeping-a-SMB-share-mounted-on-macOS-and-alerting-when-it-does-down.html)
- [Michael Lynn: Apple's BookmarkData Exposed](http://michaellynn.github.io/2015/10/24/apples-bookmarkdata-exposed/)
- [Eclectic Light: Bookmarks and Aliases](https://eclecticlight.co/2020/05/21/bookmarks-a-type-of-alias-their-access-and-use/)

### foobar2000
- [foobar2000 Mac Changelog](https://www.foobar2000.org/changelog-mac)
- [Hydrogenaudio: Mac 2.5 Beta Changelog](https://wiki.hydrogenaudio.org/index.php?title=Foobar2000:Mac_Version_2.5_Beta_Change_Log)
- [Bombich Software (CCC): Volume Identification](https://bombich.com/en/kb/ccc/5/ccc-found-multiple-volumes-same-universally-unique-identifier)

### Community Discussions
- [Apple Community: macOS adds -1 to network name](https://discussions.apple.com/thread/8172762)
- [Apple Community: Tahoe automount broken](https://discussions.apple.com/thread/256140465)
- [SynoForum: SMB mappings on macOS Tahoe](https://www.synoforum.com/threads/smb-mappings-on-macos-tahoe-26-do-not-yet-autoconnect.15298/)
- [SynoForum: Tailscale and SMB mount](https://www.synoforum.com/threads/tailscale-and-smb-mount.7505/)
