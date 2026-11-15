# foobar2000 macOS paths for the intake component

Findings of the S0 path probe (foo_jl_intake, 2026-11-15) on foobar2000 2.26 preview with SimPlaylist v2 as the decorator host. The probe was a temporary read-only build: it sampled playlist and library item paths, converted them and logged the cost and calling thread. It ran once and was then removed (commit 5f85b224 adds it; the commit that adds this document removes it).

Paths below are placeholders. `<UUID>` is foobar2000's volume id, `<share>` an SMB share name.

## What foobar2000 stores

- Tracks on network shares are stored as `mac-volume://<UUID>/<path relative to the mount point>`. In the probed profile, 84,140 of 86,903 playlist items used this scheme. The rest were `file://` (1,406), `tidal://` (1,350) and `soundcloud://` (7).
- `file://` items pointing at a path that no longer exists stay as they are (a former third-party mount under `~/Library/Group Containers/…`).
- The media library held 10 items, all `file://`. Playlists, not the library, are where share tracks live.

## `filesystem::g_get_native_path`

| Question | Answer |
|---|---|
| Does `mac-volume://` convert? | Yes, to `/Volumes/<mount point>/<path>`. Every sample converted, with no exceptions. |
| Cost | First call of the session about 0.7 ms (service lookup). After that 1–3 µs for a new path, about 0.9 µs mean for a repeated one (1,000-call loop, max 15 µs). |
| Does it do I/O? | No sign of it: microseconds, while a `stat` of the converted path on the share took 7–139 ms (median 42 ms). |
| Thread safety | 160 concurrent calls from 6 global-queue threads: identical results, no exceptions. |
| Host thread | SimPlaylist v2 calls `decorate()` on its serial queue `com.foobar2000.simplaylist.decorations`, off the main thread. Conversion there costs the same as anywhere else. |
| Main thread | 40 calls, mean 1.8 µs, max 8.4 µs. |
| Non-file schemes | `tidal://`, `soundcloud://`: returns false and leaves the path unchanged. |

**Decision:** convert synchronously in `decorate()`. The per-path cache planned for B3 (IntakeNativePath) is not needed. Never `stat` on the decorate path: a share `stat` costs tens of milliseconds.

## The same share mounted twice

The probed Mac had the same SMB share mounted twice: once by its LAN name at `/Volumes/<share>` and once by a VPN address at `/Volumes/<share>-1`. macOS picks the `-1` suffix by mount order, so which mount point gets which name can change from one login to the next.

foobar2000's `<UUID>` resolved to `/Volumes/<share>-1`. The intake CLI reports root paths under whichever mount point its config names. A plain prefix match would then miss every row whenever the two disagree.

**Consequence for the component:** before matching, map each path under a network mount to a share-relative key, using the mount table:
- `getmntinfo(MNT_NOWAIT)` gives each mount point with its source (`//user@host/<share>`) and filesystem type, without network I/O.
- Two `smbfs` mounts with the same share name are treated as the same share; the user and host parts of the source are ignored.
- Root paths from the CLI and converted item paths both go through the same mapping, so either mount point matches.
- The table is rebuilt at load and on `NSWorkspaceDidMountNotification` / `NSWorkspaceDidUnmountNotification`.

The pure part (mount list in, rewrite out) is Core and unit-tested; reading the mount table is Integration.

## Canonical paths and metadb handles (for Swap, B9)

- `filesystem::g_get_canonical_path("/Volumes/<share>-1/<path>")`, with or without `file://`, returns `mac-volume://<UUID>/<path>`. foobar2000 maps a mounted volume path back to its own scheme.
- `metadb::handle_create` with that canonical path returns the **same** handle object as the playlist item: no duplicate metadb entry. `file://` items behave the same way.
- Not measured: what the canonical form of the *other* mount point of the same share (`/Volumes/<share>`) is. If it gets a different `<UUID>`, swapping through it would create duplicate handles, which is the failure in `docs/VOLUME_UUID_ISSUE.md`. Swap therefore builds the library path on the mount point whose canonical form matches the playlist's existing items, and logs a skip when none does.

## Probe method

1. 3 s after start, on the main thread: read every playlist's item paths and the library's (48 ms for 132 playlists), and pick up to 30 `mac-volume://`, 5 `file://` and 5 other samples.
2. On a private serial queue: convert each sample twice and `stat` the result; then a 1,000-call loop on one path, then concurrent calls through `dispatch_apply`.
3. Back on the main thread, only because no call in step 2 exceeded 50 ms: convert again, then the canonical-path and `handle_create` checks.
4. `decorate()` logged the first 8 rows of the first batch (64 rows) with the calling thread.
