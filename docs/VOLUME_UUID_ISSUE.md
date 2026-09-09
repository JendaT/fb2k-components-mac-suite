# Network Volume UUID Instability on macOS

## Problem

foobar2000 macOS uses `mac-volume://UUID/path` URLs to reference files on mounted volumes. This works well for local volumes (USB, internal drives) where UUIDs are stable and stored on the filesystem itself.

However, **network volumes (SMB/AFP/NFS) receive dynamically assigned UUIDs from macOS at mount time**. When a network share reconnects, the NAS reboots, or the share is remounted differently, macOS assigns a new UUID. This causes playlist entries and metadb records using the old UUID to become orphaned -- foobar cannot resolve them to the current mount, resulting in "Operation timed out" errors or empty/unanalyzed playlist items.

## Severity (as of 2026-04-11)

The problem is worse than originally documented. A real-world setup with one SMB share (`music.hq`) accessible via both LAN and Tailscale has accumulated:

- **12 different volume UUIDs** for the same share
- **67,348 duplicate metadb entries** (30% of the database)
- **5.7 GB metadb** (should be ~4 GB; 1.7 GB freelist waste + 1.15 GB duplicate data)
- All 24 playlists pointing to a stale UUID (broken on every launch)

The manual UUID remapping tool cannot keep up -- every reboot, sleep/wake, or network change creates a new UUID.

## Implemented Solutions

### Manual UUID Remapping Tool (2026-01)

Implemented in `UUIDRemappingWindowController`. Scans `.fplite` files, identifies orphaned UUIDs, provides UI for remapping. Works but requires manual intervention and foobar restart. See [design doc](design/2026-01-13-volume-uuid-remapping.md).

### Automatic UUID Sync (implemented, plorg 1.5.0)

Automatic startup and runtime UUID synchronization. See [deep research](research/volume-uuid-instability-deep-research.md) for comprehensive analysis covering macOS internals, foobar SDK, industry solutions, and design patterns.

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
