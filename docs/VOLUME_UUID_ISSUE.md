# Network Volume UUID Instability on macOS

## Problem

foobar2000 macOS uses `mac-volume://UUID/path` URLs to reference files on mounted volumes. This works well for local volumes (USB, internal drives) where UUIDs are stable and stored on the filesystem itself.

However, **network volumes (SMB/AFP/NFS) receive dynamically assigned UUIDs from macOS at mount time**. When a network share reconnects, the NAS reboots, or the share is remounted differently, macOS may assign a new UUID. This causes playlist entries and metadb records using the old UUID to become orphaned - foobar cannot resolve them to the current mount, resulting in "Operation timed out" errors when accessing those tracks.

In a real-world case, a single playlist had 1654 tracks pointing to `mac-volume://2C4962D1-.../music.hq/...` while the current mount used `mac-volume://CEF335FD-.../music.hq/...`. The metadb contained three different UUIDs for the same `/Volumes/music` share accumulated over time.

## Proposed Solution: UUID Remapping Tool

A cleanup utility could:

1. **Scan all playlists** for `mac-volume://` URLs
2. **Group by mount point** - extract the first path component after UUID (e.g., `music.hq`)
3. **Identify active vs orphaned UUIDs** - check which UUIDs resolve to currently mounted volumes
4. **Present UI for remapping** - "Map orphaned `/music.hq/` (UUID: 2C4962D1..., 1654 tracks) to active `/music.hq/` (UUID: CEF335FD...)?"
5. **Batch replace** across affected playlists and optionally metadb

## Alternative: More Stable Network Volume Identification

Instead of relying solely on macOS-assigned UUIDs for network mounts, foobar could:

- Store additional metadata (server hostname, share name, mount point) alongside the UUID
- Use a hash of server+share as a secondary identifier
- Detect when a "new" UUID points to the same network path as an orphaned one

## Scope

This affects playlist management globally - any component storing `mac-volume://` URLs faces this issue. The Playlist Organizer (plorg) would be the appropriate place for such a cleanup tool since it already handles cross-playlist operations.

## Impact on SimPlaylist Cover Art (Fixed 2026-05-24)

`mac-volume://UUID/path` URIs also affect SimPlaylist's file-based cover art lookup.
`AlbumArtCache` used a two-stage approach: (1) direct `NSFileManager` file lookup,
(2) `album_art_extractor::g_open` for embedded art. Both failed for external volumes:

- **Stage 1** — `NSFileManager` only handles POSIX paths. `mac-volume://` paths are
  passed verbatim, `fileExistsAtPath:` returns NO, and no external art file is found.
- **Stage 2** — `album_art_extractor` only reads art **embedded in the audio file**
  itself. Albums that store art exclusively as a companion file (`cover.jpg`, etc.)
  return nothing.

**Why the albumart component worked**: it uses `album_art_manager_v2`, a higher-level
fb2k SDK API that handles all fb2k path schemes natively (including `mac-volume://`)
and searches both embedded and companion/external art files.

**UUID resolution is not feasible**: fb2k's UUID in `mac-volume://UUID` does **not**
match any macOS-exposed volume identifier — not `NSURLVolumeUUIDStringKey`, not
`diskutil`'s Volume UUID, not the IOKit MediaUUID. The UUID source is fb2k-internal.
Any scheme that tries to enumerate mounted volumes and match by UUID will silently fail.

**The fix (`AlbumArtCache.mm`, 2026-05-24):**

Stage 2 is replaced with `album_art_manager_v2::open()`, the same API the albumart
component uses. A bleed-through guard is applied via `query_paths()`: the manager
can return library-wide stub art for tracks that have no art at all; we prevent this
by only accepting the result when the art source path lives in the same directory
as the track. Embedded art (no external source path) is always accepted.

Additionally, the `noImageKeys` session blacklist now purges entries for newly-mounted
volumes on `NSWorkspaceDidMountNotification`, matching both POSIX (`/Volumes/…`) and
`mac-volume://UUID/…` key formats, so art that failed to load before a drive finished
mounting is automatically retried.

## Workaround (Manual)

For immediate fixes, orphaned UUIDs can be replaced via sed in playlist `.fplite` files (which are CSV format):

```bash
# Backup first
cp playlist-XXX.fplite playlist-XXX.fplite.backup

# Replace orphaned UUID with current one
sed -i '' 's/OLD-UUID/CURRENT-UUID/g' playlist-XXX.fplite
```

Requires foobar2000 restart to reload the modified playlists.
