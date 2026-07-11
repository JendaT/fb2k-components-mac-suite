# Proposal: self-heal stale volume UUIDs when the share is mounted

Status: **proposal, not implemented.** Design for review before building.
Date: 2026-07-11. Context: `docs/VOLUME_UUID_ISSUE.md`, investigation of the
2026-07-11 `CFA535CA-…` playback failure.

## 2026-07-11 addendum: probe results narrow the design space

Two read-only probes on the affected machine settle earlier open questions:

1. **All 18 registry bookmarks fail to resolve** when tested standalone with
   the exact API/options VolumeSync uses (`URLByResolvingBookmarkData`,
   `withoutUI|withoutMounting`). "18 volumes (0 live)" is factually correct —
   liveness detection is not the problem.
2. **The mounted SMB volume exposes NO volume UUID**: both
   `NSURLVolumeUUIDStringKey` and DiskArbitration return nothing for
   `/Volumes/music` (`DADiskCreateFromBSDName` on `//jendalen@Amunet…/music`
   yields no description). Therefore a remap target can NEVER be derived from
   the mount itself on this setup — neither by the automatic sync nor by the
   manual Repair Volume UUIDs tool (whose mounted-volume discovery hits the
   same wall). **Minting a fresh fb2k bookmark is the only viable source of a
   live UUID.** Step 2's spike is now the whole feature, not one option of two.

Also confirmed by git history: plorg has never written `mac.volume.*` entries
or fb2k's `config.sqlite` in any commit, and the automatic + manual repair
tools both first shipped in `cddda2a` (2026-05-17). Historically, live UUIDs
were supplied by **foobar2000 itself minting a fresh registry entry + bookmark
per remount** (hence 18 entries for one share); repair worked whenever the
current session had one. The 2026-07-11 failure is that fb2k did not mint (or
cannot resolve) an entry for the current mount session — that supply drying up
is the actual root cause, and self-heal must replace it.

## Problem being solved

Today, when **every** registry entry for a share is dead (fb2k's stored
security-scoped bookmarks no longer resolve), VolumeSync dead-ends:

```
foobar registry: 18 volumes (0 live)
Stale UUID CFA535CA-… has no live replacement (originalPath: /Volumes/music). Mount the volume and retry.
```

…even though `/Volumes/music` **is** mounted and readable. The repair only ever
consults fb2k's own registry (`readFoobarVolumeRegistry`, read-only). It never
consults the actual mount table, and it cannot mint a fresh bookmark itself, so
`liveUUIDsByPath` is empty and there is nothing to remap the stale UUID onto.
The user must manually drag a folder from the share into foobar2000 to make the
core register a new volume/bookmark. This is the remediation gap (investigation
item 5).

Note this is a **pre-existing gap**, not a refactor regression: the mounted-volume
discovery helpers (`discoverShareToUUIDMapping`, `scanForStaleUUIDsInDirectory:…
currentMounts:`) exist but have never been wired into the repair path.

## Key idea

foobar2000 mints a security-scoped volume bookmark as a side effect of the core
**resolving a file path on that volume**. plorg already invokes that exact
machinery for imports:

```objc
playlist_incoming_item_filter_v2::get()->process_locations_async(paths, …)
```

So the self-heal is: when a stale `.fplite` UUID's `originalPath` is currently
mounted and readable, feed one real file from that path through the core so it
registers the volume and stores a fresh (live) bookmark → a new live UUID
appears in `config.sqlite` → the **existing** repair pass can then remap the
stale UUIDs onto it.

## Proposed flow

1. **Detect the healable condition** (pure, testable — extend `VolumeSyncLogic`).
   After planning, for each unresolved stale UUID (the new
   `unresolvedFpliteUUIDsInIndex:…`), check whether its `originalPath` (or the
   sample-path's volume root) is currently mounted. Mounted-volume enumeration
   already exists in `discoverShareInfo` (`getmntinfo`) — wire it in here
   instead of leaving it dead. Emit a list of
   `{ staleUUID, mountedPath, sampleFilePath }` candidates.

2. **Mint a bookmark via the core.** For one candidate per distinct mounted
   path, resolve a single real file (`mountedPath + samplePath`, verified to
   exist) through `process_locations_async`.
   - **Open question (must verify before building):** does resolving a
     metadb_handle actually cause the core to persist a `mac.volume.<UUID>`
     bookmark, or does that only happen on an explicit user-initiated add to a
     playlist? If resolution alone is insufficient, add the file to a temporary
     hidden playlist and delete it immediately, or use whatever
     `library_manager` / volume-registration entry point the fb2k mac SDK
     exposes. This is the load-bearing assumption of the whole approach.

3. **Re-read the registry and remap.** After the core has (hopefully) minted the
   bookmark, re-run `readFoobarVolumeRegistry` → `liveUUIDsByPath` →
   `planRemapActions`. The stale UUID now has a live target and the existing
   `.fplite` patch + metadb-migration path takes over unchanged.

4. **Garbage-collect dead duplicates (optional, later).** The registry had 16
   dead entries for `/Volumes/music`. These are harmless but accumulate. GC is
   **out of scope for self-heal** and higher-risk: it means writing to
   `config.sqlite`, which must never happen while foobar2000 is running.
   Defer to a separate, explicit, quit-time or user-confirmed operation.

## Fallback if the core cannot mint bookmarks from a component

If step 2's open question resolves to "a component cannot make the core mint a
bookmark," fall back to a **one-click prompt** (reuses the existing opt-in alert
infrastructure, `maybePromptForRestartAfterRepair` /
`kAutoRestartAfterVolumeSync`):

> "N playlist(s) reference `/Volumes/music`, which is mounted but not registered
> with foobar2000. Register it now?" → **Register** runs an `NSOpenPanel`
> pre-pointed at the mounted path (or directly feeds a known file), which is a
> user-initiated add and reliably mints the bookmark. Then auto-rescan.

This is strictly better than today's "Mount the volume and retry" dead-end: the
volume is already mounted, so the user does not have to figure out what to do.

## Constraints and safety

- **Never write `config.sqlite` while fb2k may be running.** Bookmark creation
  goes through the core (which owns the DB); plorg continues read-only access.
  This is a hard rule.
- Keep the file-resolution side effect invisible: no stray tracks left in a
  user playlist, no playback started.
- Gate the whole feature behind a preference (default on, consistent with
  `kAutoVolumeSync`), and rate-limit so a permanently-unmounted share does not
  retry every monitor tick.
- All decision logic (healable-candidate detection, path/mount matching) goes in
  `VolumeSyncLogic` as pure functions with unit tests; only the
  `process_locations` call and the prompt live in the SDK/UI layer.

## Recommended next step

Before writing any of this, run a **one-off spike** to answer step 2's open
question: in a scratch build, resolve a single file from a mounted-but-
unregistered volume via `process_locations_async` and inspect whether a new
`mac.volume.<UUID>.bookmark` row appears in `config.sqlite`. The result decides
between the "automatic mint" path and the "one-click prompt" fallback. Everything
else is straightforward reuse of existing machinery.
