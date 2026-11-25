# foo_jl_intake runtime notes

How the component runs the intake CLI, watches for changes and matches
foobar2000's paths. Every statement here comes from the source files named
in brackets; when this note and a header disagree, the header is right.
Settings are in [`hidden-options.md`](hidden-options.md).

## The CLI runner

### One call

[`src/Core/IntakeCommandArgs.h`, `IntakeProcess.h`, `IntakeCliRunner.h`]

- **No shell.** The argv goes to `posix_spawn` as given, so a collection
  name like `[A & B]` or a reject reason reaches the CLI byte for byte.
  Every call gets `--json`.
- **A `.ts` CLI path runs through bun.** The bun is the configured
  `bun_path`, else the first executable `bun` in `~/.bun/bin`,
  `/opt/homebrew/bin` or `/usr/local/bin`.
- **The environment** is a main-thread snapshot of foobar2000's own, with:
  - `PATH` = the bun folder, then
    `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`, then
    the rest of the inherited `PATH`;
  - `INTAKE_RULES_DIR` = the `rules_dir` setting, only when it is set.
- **Ids only.** A mutating command (propose, assign, approve, reject,
  execute, resume, gc, dry runs included) needs at least one sidecar id
  (`itk_` and 8 hex digits). Without one it is refused and nothing is
  spawned. The component never sends `--all`, `--all-resolved`,
  `--approved` or a bare `gc`.
- **`scan` names one income** (B12, the automatic scan only). It takes no
  ids: exactly one income name from `income --json`, or that income's
  absolute path when the name starts with `-` (the CLI would parse the name
  as a flag). Without one it is refused; there is no `scan --all` and no
  dry run of it.
- **Process hygiene.**
  - The child leads its own process group, so one `kill(-pgid)` reaches
    bun and its helpers.
  - It inherits only stdin (`/dev/null`), stdout and stderr, with an
    empty signal mask and default signal handlers.
  - Its exit is seen by a dispatch source and reaped with `waitpid`, so
    no zombie is left.

### Command classes, timeouts and kill policy

Calls are classified by command, whatever their flags, as doc 03 v1.2
"Timeouts" requires [`IntakeCommandArgs.h` `CommandClass`,
`IntakeProcess.h` `ProcessLimits`]:

| Class | Commands | Output | At 10 s | Killed |
|---|---|---|---|---|
| ReadOnly | `version`, `status`, `collections`, `income` | pipes (stdout capped at 32 MB, stderr at 64 KB) | `E_CLI_TIMEOUT`, then SIGTERM to the group | SIGKILL 2 s after the SIGTERM |
| Mutating | `propose`, `assign`, `approve`, `reject`, `gc`, `scan` (B12), and their dry runs | files | `E_CLI_TIMEOUT` reported; it keeps running and its real result follows | only at the 15-minute hard cap (SIGTERM, SIGKILL 2 s later) |
| ExecuteDryRun | `execute --dry-run` | files | no `E_CLI_TIMEOUT` (doc 03 excepts execute); the mutation lane is released | never |
| Detached | `execute`, `execute --resume` | caller-named files | nothing | never; it survives quitting foobar2000 |

- **Unkillable processes.** A process still alive 2 s after its SIGKILL
  (uninterruptible sleep on a dead share) is reported as abandoned. The
  runner keeps watching the pid and reaps it when it exits.
- **On quit** (`IntakeLoader::shutdown`, `ProcessRunner::closeReadLane`):
  ReadOnly calls are killed and no new one starts. Mutating, dry-run and
  detached calls are left running; their results are no longer handled.
- **Output files** (every class but ReadOnly) go to
  `~/Library/Caches/foo_jl_intake/` [`IntakeCliRunner.h`
  `defaultCliOutputDirectory`]. A mutating call writes
  `intake-<pid>-<seq>-<ms>.out` and `.err`. They are read after exit and
  deleted. A runner's first such call into the folder also deletes
  leftover `intake-*` files whose creating process no longer exists. With files
  instead of pipes, a command that outlives foobar2000 never gets SIGPIPE
  halfway through a sidecar write.

### The mutation lane

The CLI has no locking, so the component runs at most one mutating call at
a time [`src/Core/IntakeMutationLane.h`]:

- A real mutating call holds the lane until it exits (or the 15-minute cap
  ends it).
- A dry run holds it until it exits or until its 10 s report, whichever
  comes first. After the report its late result is discarded.
- `execute` and resume hold it until they exit.
- The automatic scan (B12) holds it from the scan's start until its exit
  and the propose after it. It takes the lane only when it is free; a due
  scan waits.
- Mutating menu items are disabled while the lane is busy, with
  "(execute running)" in their titles during an execute and
  "(scan running)" during the automatic scan. A click that finds the lane
  taken by the scan logs "a background scan is running". Swap to library
  paths runs no CLI call and stays enabled.
- Commands run by hand in Terminal are not covered by the lane.

### Detached execute and resume, and the run files

[`src/Core/IntakeExecuteTracker.h`]

**Files.** Each run uses a stem `execute-YYYYMMDD-HHMMSS-mmm` (local time,
`-2`, `-3`... if taken) in `~/Library/Caches/foo_jl_intake/`:

- `<stem>.json`: the CLI's stdout. stderr goes to `/dev/null`.
- `<stem>.run`: one JSON object, written atomically (`<stem>.tmp`, fsync,
  rename):
  `{"format":1, "command":"execute"|"resume", "pid", "start_sec", "start_usec", "ids", "root_paths", "output"}`.
  It is first written *before* the spawn, without `pid` and the start time
  (provisional). It is rewritten with them as soon as the child exists.

Both files are deleted once the component has read the result.

**Liveness.** A run is live when its pid exists **and** that process's
start time (`proc_pidinfo`) equals the run file's. Image names are never
compared: the CLI may be bun, a wrapper script or a compiled binary.

**At the next start** (`scanLeftoverRuns`, once, before any mutating call
can start):

| What is in the folder | What happens |
|---|---|
| A run file that is live | Adopted: the lane is held and the pid watched until it exits. |
| A run file that is dead | Finished: its output is read and applied, then the files go. |
| A provisional run file, while a process of this user still has the output open (`proc_listpidspath`) | Adopted with that process. |
| A provisional run file, no such process, the output exists | Finished. |
| A provisional run file, no output | Swept: the CLI never started. |
| A run file that does not parse, or an output or temp file with no run file | Swept. |

The runner's own `intake-*` files and anything that is not a regular file
are never touched.

**Exit code of an adopted run.** It was not our child, so there is none. It
is inferred from the envelope: `ok` true is 0; `ok` false with `data` null
or `[]` is 2; otherwise 1. A truncated or empty output is `E_NO_CLI`.

## Watching for changes (FSEvents)

[`src/Core/IntakeWatchSet.h`, `IntakeWatcher.h`, `IntakeWatchFilter.h`,
`IntakeDebounce.h`, `IntakeLoader.h`]

**What is watched.** After every load attempt and every remount the loader
builds the watch set from:

- the `watch_folders` setting;
- the folders from `intake income --json`, when the CLI lists `income`;
- the parent folder of every root of the last good load.

Symlinks are resolved (`lstat`/`readlink`) only for local paths. Local or
network is decided from a fresh `getmntinfo(MNT_NOWAIT)` table, so a share
that mounted during the load is never resolved. With no CLI path the set is
empty.

**The stream.**

- File-level events, 0.5 s latency, delivered on the watcher's own queue.
- It is created without `kFSEventStreamCreateFlagWatchRoot`, which would
  keep each watched folder and its ancestors open and so keep a share busy.
- Stream creation runs on the watcher's queue, never on the caller's thread:
  FSEvents may resolve paths, which is I/O on a share.

**What counts as a change.**

- A sidecar name: exactly the CLI's `isSidecarName` rule. That is
  `.intake.json`, or `.intake.<id>.json` with `<id>` in `[A-Za-z0-9_]`
  (any case). The CLI's `.intake-tmp-*` files and doc 05's
  `.intake-hint.json` do not count.
- A folder that is renamed, moved or removed. Its sidecars move with it
  without events of their own.
- Events FSEvents could not deliver one by one (MustScanSubDirs, dropped
  events, Mount, Unmount) mark the batch as a rescan.
- These rules are the reload's. The automatic scan (B12) gets every event
  before them and has rules of its own (see Automatic income scan below).

**From events to a load.**

- **Debounce.** The first relevant event opens a window. It closes 1 s
  after the latest event, and never later than 3 s after the first. Then
  the loader gets one batch (`IntakeLoader::reloadForChanges`).
- **Coalescing.** One load runs at a time. A reload asked for while a load
  runs (any trigger: an FSEvents batch, the exit of a command the component
  started, a settings change, a mount, Refresh) sets one "reload again"
  flag. Exactly one more load follows.
- **Always a full load.** Every load is a full `status --json`, never
  `--filter`: doc 03 gives filtered calls no cost guarantee. A load started
  only by FSEvents batches lists again just the folders those batches named.
  Any other trigger lists everything.
- **No gap between `status` and the stream.** The loader takes
  `FSEventsGetCurrentEventId()` just before each `status` call. A new
  stream starts from that id, so FSEvents replays what changed since. SMB
  volumes may keep no such history (untested). There the next sidecar event
  or Refresh repairs a change made in that gap.
- **Half-written sidecars.** A `status` reply with `E_PARSE` naming
  sidecars keeps those roots' last record and retries once, 1 s later.
- **Mount or unmount** (NSWorkspace notifications): the slow-volume marks
  are forgotten, the mount table is read again, one reload runs, and the
  stream is restarted with the same paths. The share links are read again
  2 s and 10 s later (see Share links below). With share links configured
  the mount table is also read for the aliases at every load start, on
  Refresh and when the setting changes, so a mount whose notification has
  not come yet is mapped from the next load; with none, only here and at
  the first load.
- **Changes made on the NAS** (not through this Mac) produce no FSEvents
  event. They need Refresh (doc 04 v1.2 "Refresh and invalidation"). Nothing
  polls.
- **Invalidation.** A load fires one invalidate-all only when a row or
  badge renders differently from the last load (`rendersAlike`), on the
  first load and when leaving the inert state. A row-colour change rebuilds
  the last load in the new colours (`IntakeLoader::setPalette`) with at most
  one invalidate-all and no CLI call. Nothing is fired from inside
  `decorate()`.

## Automatic income scan (B12)

[`src/Core/IntakeAutoScan.h`, `IntakeAutoScanResult.h`,
`src/Integration/IntakeAutoScanDriver.h`, `IntakeActions.h`; doc 04
"Automatic income scan"]

`intake scan <income>` runs by itself when new files land in an income
folder. The setting is `auto_scan` ([`hidden-options.md`](hidden-options.md)).

**Which folders.** The income folders that `intake income --json` lists,
only while `version --json` lists `scan` in `commands` (no version
fallback). The loader pairs each one with the spelling FSEvents reports,
taken from the watch set it builds on its own queue (`autoScanIncomes`:
`/private/var/...` for `/var/...` on a local disk, a share path as
written), and hands the list over with every load attempt
(`LoaderStatus::autoScanIncomes`). A load that leaves the provider inert
hands none (`autoScanAfterLoad`): after a failed version gate the status
still holds the last passing version's commands and income folders, and
nothing mutating may go to that CLI. Folders only in `watch_folders` are
never scanned.

**From events to a scan.**

- **The sink.** The watcher calls its event sink once per FSEvents
  callback with every event (path, flags, event id), before its own filter,
  rescans and markers included (`IntakeWatcher` `EventSink`).
  `autoScanSink` matches them on the watcher's queue against an immutable
  snapshot of the income folders and gc mutes (`autoScanHits`, string work
  only) and posts one block to the main thread when something counted.
- **What counts.** An event under an income folder (the income with the
  longest folder holding it, ASCII case ignored) with Created, Renamed or
  Modified. Removal only or metadata only does not count. MustScanSubDirs,
  UserDropped and KernelDropped count for the income holding the path and
  every income under it (every income when there is no path). Mount,
  Unmount, HistoryDone and EventIdsWrapped never count.
- **Ignored**, with everything under them, by any path component below the
  income folder: `.intake*.json`, `.DS_Store`, `._*`, `.dat.nosync*`,
  `Thumbs.db`, `desktop.ini`, `@eaDir`, `.AppleDouble`, `__MACOSX`, names
  ending in `.part`, `.tmp`, `.download`, `.crdownload` or `.incomplete`,
  and the folders scan and gc write themselves: `*.unpacked`,
  `*.unpacked.partial`, `.intake-gc-*`.
- **Quiet period.** An income is due 60 s after its latest counted event.
  Later events postpone it.
- **Open files.** A file event with Created and none of Modified, Renamed,
  Removed or Cloned marks the path open (FSEvents reports the content
  change when the writer closes the file); a later event for the path with
  any of them closes it. An open path holds its income, for at most 30 min
  from when it opened. A clone (`cp -c`, `ditto`, a Finder copy within one
  APFS volume) arrives as `Cloned`, then `Created Cloned`, and no Modified
  ever follows (checked with a scratch FSEvents probe on APFS), so Cloned
  counts as closed.
- **One at a time** (`AutoScanScheduler`, main thread). One job in flight
  (presence check or scan); the income pending longest first; one pending
  entry per income. Events during an income's job give it exactly one more
  scan, 60 s after the latest.
- **Wakeups.** One `dispatch_after` on the wall clock (a Mac that slept
  past it fires on waking), at the scheduler's next due time, replaced only
  by an earlier one. While the lane is busy a due income is retried every
  5 s.
- **Startup.** After the session's first Ready load, with `auto_scan` on,
  once the leftover-run scan is done (`actionsAfterRunScan`), every income
  folder the presence check finds local is due at once. One on a network
  volume waits for events; a missing one gets nothing.

**Presence check** (`checkPresence`, on a serial utility queue, never the
main thread or the watcher's queue), before every scan and at startup: a
fresh `getmntinfo(MNT_NOWAIT)` table (`readMountTable`), then
`classifyIncome` with `posixLinkReader`, which runs `lstat`/`readlink` only
on paths the table puts on a local filesystem and stops at a network mount
point without examining it, the mount point included. A local folder then
gets one `lstat`, which must show a directory. A folder on a mounted share
counts as present unexamined. Missing (an absent folder, an unmounted
share, a symlink loop): no scan, one Debug line.

**The run** (`actionsStartAutoScan`, main thread).

- It starts only when the lane is free (not after quit, the leftover-run
  scan done, nothing holding the lane, no Execute follow-up waiting for its
  reload or running: the lane is free between those steps, and the
  follow-up's delete refuses while a scan holds it), the CLI is configured
  and the provider is not inert. It takes the lane as `LaneHolder::Scan`,
  begins its status-bar entry and starts `scan <name> --json` (class
  Mutating: output files in the cache folder, reported at 10 s, killed at
  the 15-minute cap).
- At 10 s: one Info line, no tooltip, no reload; the entry stays.
- Its exit (`autoScanOutcome`): `E_NO_CLI` ends the run; the cap kill ends
  it and the income is not scanned automatically again this session (one
  Info line); every other outcome goes on to the propose.
- **The propose after it** (`proposeAfterScan`): after exit 0 or 1, the
  rows of the reply's `data[].written` with a string id and `status`
  exactly `resolved`, each once, in the scan's order, except a root that is
  the income folder itself, go to `propose <ids>` on the same lane token
  (`LaneRun::ProposeAfterScan`). `data` is not pinned by doc 03 and is
  read leniently. The lane stays `LaneHolder::Scan`, so the menu keeps
  "(scan running)". The propose's root errors become tooltips (baseline
  resolved); its console line and its 10 s report are Info.
- **The end** (`endAutoScanRun`, the only path that lets go of the token):
  the lane is released, the entry ends, one reload is asked for when a
  process ran, and the driver gets the exit and arms the next wakeup. After
  `on_quit` only the lane is released.

**gc mute.** gc renames a root's files into its `.intake-gc-<id>/` staging
folder, and the events at the old paths would look like arrivals.
`runMutation`, which every gc goes through (Delete local copy…, confirmed
or not, and the Execute follow-up's delete), calls `autoScanMuteGc` with the
roots' paths right before it dispatches gc: the paths are rewritten to the
FSEvents spelling (`autoScanMutePaths`) and muted from
`FSEventsGetCurrentEventId()` on. When gc exits or is refused,
`autoScanUnmuteGc` sets the end id the same way. Events under those paths
with ids in between never count, whenever the sink sees them. The mute is
removed with the first callback carrying an id past its end, or 10 min
after gc ended.

**Setting and quit.** `auto_scan` is applied in `on_init` before the
service starts, and at once on a change (one Info line): off drops the
pending scans and the sink matches nothing, while a running scan finishes
with the propose after it; on starts nothing until the next counted event.
`on_quit` calls `autoScanShutdown` right after `actionsShutdown`: nothing
is scheduled or started afterwards, a running scan goes on (mutating calls
are not killed before the cap) and its result only releases the lane. The
driver's state is leaked like IntakeActions', and every main-queue block
checks the stopped flag.

**Console lines** (Info, never Error, never a sheet):

```
[intake] auto-scan: scanning income local (startup)
[intake] auto-scan: scanning income local (new files)
[intake] auto-scan: local still running (E_CLI_TIMEOUT: no reply after 10 s; the scan continues)
[intake] auto-scan: local done in 12.3 s: 2 new roots, 1 kept
[intake] auto-scan: local done in 12.3 s with errors: 2 new roots, 1 kept; <errors>
[intake] auto-scan: local failed: <errors>
[intake] auto-scan: local cancelled
[intake] auto-scan: local not started (<refusal>)
[intake] auto-scan: local not started: intake is not running or has no CLI path
[intake] auto-scan: local not started: intake is inert: <reason>
[intake] auto-scan: income local is not scanned automatically again this session (its scan was stopped at the 15-minute cap)
[intake] propose: starting after auto-scan of local for 2 roots: itk_0000000a itk_0000000b
[intake] propose: still running after auto-scan of local (E_CLI_TIMEOUT: no reply after 10 s; the propose continues)
[intake] propose: not started after auto-scan of local (<refusal>)
[intake] propose: not run after auto-scan of local: intake is not running or has no CLI path
[intake] propose: not run after auto-scan of local: intake is inert: <reason>
[intake] auto-scan: the CLI 0.2.1 does not offer scan; income folders are not scanned automatically
[intake] auto-scan off: income folders are no longer scanned automatically
[intake] auto-scan on: new files in an income folder are scanned
```

`<errors>` is up to three `CODE: msg (path)` joined with `; `, then
`(+N more)`. The propose's own result line follows its start line. At
Debug: an income that became pending (`auto-scan: new files in income
local; scanning it once they stopped for 60 s`), each income's startup
classification, a missing folder, each gc mute, and the roots written but
not proposed (`auto-scan: local: no propose for 2 roots: itk_0000000c
(new), ...`). A resolved root that needs review is proposed too (the
user's choice, 2026-11-25; `--all-resolved` would skip it).

**Limits.**

- FSEvents reports only changes made through this Mac: files written into
  a network income folder by another machine start no scan. FSEvents on
  SMB is untested.
- Only local income folders get the startup scan, so files that reached a
  network one while foobar2000 was not running wait for the next event
  there.
- The CLI keeps a folder's existing sidecar, so tracks that arrive in a
  folder after it was scanned are not added (a slow download with a gap
  between tracks). Only a CLI change can fix that.
- A file created and never closed holds its income for the full 30 min.
- The CLI has no locking: a scan run by hand in Terminal can race the
  component's.

## `mac-volume://` paths

The measurements are in
[`docs/intake-mac-paths.md`](../../../docs/intake-mac-paths.md) (the S0
probe, 2026-11-15). What the component does with them:

- **Converted inline on the decorate path** [`src/Integration/IntakeNativePath.h`]:
  - foobar2000 stores share tracks as `mac-volume://<UUID>/<path>`.
    `filesystem::g_get_native_path` turns that into `/Volumes/<mount>/<path>`
    in about 1 µs, with no I/O, and is thread-safe. So each row is
    converted inline, with no cache.
  - Other schemes (`tidal://`, `soundcloud://`, ...) are no match at once,
    without calling the SDK.
  - Nothing on the decorate path calls `stat`: on the share it took 7 to
    139 ms.
- **Slow-volume guard** [`src/Core/IntakeSlowVolumeGuard.h`]:
  - The probe only covered mounted volumes. A stale UUID or an unmounted
    share was not measured, so every conversion is timed.
  - Three calls in a row over 20 ms on one UUID mark it slow. Its rows then
    get no match without calling the SDK, with one Info line per UUID.
  - The marks are cleared on a mount change or Refresh, followed by an
    invalidate-all.
- **The same share mounted twice** [`src/Core/IntakeMountAliases.h`,
  `src/Integration/IntakeMounts.mm`]:
  - The Mac can mount one share at `/Volumes/<share>` and at
    `/Volumes/<share>-1`. Which mount gets which name depends on mount
    order. foobar2000 may resolve to one and the CLI report the other.
  - So paths under an `smbfs` mount are matched by a share-relative key
    (`/smbfs:<share>/...`). The share name comes from the mount source:
    user and host are ignored, and the name is lowercased.
  - The table comes from `getmntinfo(MNT_NOWAIT)` (no server contact) and
    is rebuilt on mount and unmount.
  - An unmounted share is absent from the table: its rows match nothing
    and never hang.
- **Swap to library paths** [`src/Integration/IntakeSwap.h`]:
  - `filesystem::g_get_canonical_path` maps a `/Volumes/...` path back to
    `mac-volume://<UUID>/...`, and `metadb::handle_create` on that returns
    the playlist's own handle (no duplicate metadb entry).
  - Swap therefore builds the library path on the mount whose
    `mac-volume` form the playlist's items already use. Failing that, it
    uses the mount whose form foobar2000 resolves back to that mount. If
    neither fits, the row is skipped ("no matching mount").
- **Title-formatting fields** [`src/Core/IntakeVolumeTable.h`,
  `src/Integration/IntakeFieldProvider.h`]:
  - `process_field` may make no foobar2000 call but reading its handle,
    so it cannot use `g_get_native_path`. A volume table (`<UUID>` ->
    root) stands in for it. foobar2000's `<UUID>` is not the macOS volume
    UUID, so the table comes from foobar2000: per mount under `/Volumes`,
    `g_get_canonical_path("<mount>/")` then `g_get_native_path` of the
    `mac-volume://<UUID>/` it returns, on a background queue (a share that
    does not answer never blocks the main thread). Re-seeded on mount,
    unmount and Refresh.
  - Stale volume ids (an earlier mount of the share that foobar2000 still
    resolves) are learned from rows the decorate path converted: the
    native path minus the row's remainder is the root. This runs before a
    field is first used too: SimPlaylist keeps the decorations of rows it
    drew and does not decorate them again when a field column is added,
    so a gate on first use left those ids unknown. That check also
    tests the assumption that the remainder is stored raw, not
    percent-encoded: a volume that fails it is not learned (one Debug
    line).
  - Field values are cached by the hosts until `metadb_io::dispatch_refresh`.
    The refresh is throttled to once per second and limited to playlist
    rows under changed roots (SimPlaylist re-lays out, and v2 regroups, on
    each refresh). Items in no playlist are not refreshed.

## Share links

[`src/Core/IntakeWatchSet.h` (readShareLink), `IntakeMountAliases.h`,
`IntakeLoader.h`; doc 04 "Share links"]

After the plorg migration ([`docs/shadow-link.md`](../../../docs/shadow-link.md))
foobar2000 keeps share tracks as `file://<link>/<rel>` under a local
symlink that a mount agent re-points. The `share_links` setting names the
links; each maps to where it points.

- **When they are read:** at the start of every load, before the CLI is
  asked anything; on a mount or unmount notification, and again 2 s and
  10 s after it, because the agent re-points the link once it sees the
  mount; on Refresh and Reload now; and when the setting changes. Nothing
  watches the link itself, so a re-point with none of these is picked up
  at the next one. With no link configured none of these reads runs,
  apart from the one that drops the old links when the setting is
  emptied.
- **How:** on the loader queue, with the same fresh
  `getmntinfo(MNT_NOWAIT)` table. `lstat`/`readlink` run only on paths
  that table puts on a local filesystem, so nothing inside a network
  mount is examined, the share's mount point included.
- **Cost of a change:** an unchanged result publishes nothing. A changed
  one rebuilds the last load's keys and publishes them (no CLI call), with
  an invalidate-all only when a row can decorate differently. The next
  load started by FSEvents still lists only the folders its batches named,
  unless a root's own key moved (only a root spelled through a link can).
- **Log:** each ignored link and each link off the share, one Info line
  when it appears; `mount aliases changed: ...` at Info on every change of
  the table (`docs/hidden-options.md`, `share_links`).
