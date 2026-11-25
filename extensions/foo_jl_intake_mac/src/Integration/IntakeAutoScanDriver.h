//
//  IntakeAutoScanDriver.h
//  foo_jl_intake
//
//  B12, the integration side of the automatic income scan (the pure part is
//  Core/IntakeAutoScan): `intake scan <income>` runs by itself when new
//  files land in an income folder. This module owns the session's
//  AutoScanScheduler and the snapshot the watcher's sink matches events
//  against, and feeds the scheduler from three places:
//   - The watcher's event sink (IntakeService gives IntakeWatcher
//     autoScanSink): on the watcher's queue, one FSEvents callback's events
//     against the snapshot (the income entries and gc's mutes;
//     autoScanHits, pure string work), and one block to the main thread
//     only when something counted (an income with new files, a file opened
//     or closed, a mute passed), which notes it in the scheduler.
//   - Every load attempt (IntakeService's onLoadFinished hands the status to
//     autoScanAfterLoad on the main thread): the income entries
//     (LoaderStatus::autoScanIncomes, the loader's watch set spelling) go to
//     the scheduler and the snapshot, or none while the CLI's `version`
//     does not list `scan` (then nothing is scanned automatically; one Info
//     line per session while auto_scan is on) and none while the load left
//     the provider inert (doc 03 "Inert state", e.g. a failed version gate:
//     nothing mutating goes to that CLI). After the first Ready load
//     of the session, with auto_scan on, once the leftover-run scan is done
//     (actionsAfterRunScan), the presence check runs for every income
//     folder on a utility queue: each local one is due for one startup scan
//     at once (noteStartup); one on a network volume is scanned on events
//     only, a missing one not at all.
//   - The auto_scan setting (autoScanSetEnabled, from on_init and
//     IntakeService::applySettings): off drops the pending scans, the sink
//     matches nothing and a scan in flight is dropped when it exits; on
//     starts nothing by itself (the next event does).
//  After each of them the next wakeup is armed at the scheduler's
//  nextWakeup: one dispatch_after on the wall clock (so it fires on time
//  after the Mac slept), replaced only by an earlier one. A wakeup that
//  finds nothing due yet (later events postponed it; the lane is busy: the
//  5 s retry) arms the next one; one that finds an income due with the
//  lane free starts the job.
//
//  A job (PLAN-B12 step 5): next() hands out the income; its presence is
//  checked on a utility queue; back on the main thread, a job dropped
//  meanwhile (auto_scan off, the income removed) ends there, a missing or
//  unmounted folder ends it (one Debug line; Idle), and otherwise
//  IntakeActions' actionsStartAutoScan takes the lane (LaneHolder::Scan)
//  and starts `scan <income> --json`: a lane taken meanwhile (a click, the
//  leftover-run scan, an Execute follow-up waiting for its reload) puts it
//  back (Pending, retried 5 s later), no CLI configuration or an inert
//  provider ends it (Refused). A started scan is Running until
//  IntakeActions hands back its exit (Finished, Refused for E_NO_CLI or a
//  refused request, CapKilled at the 15-minute cap, after which the income
//  is not scanned again this session: one Info line). Every path ends with
//  the scheduler's exit and the next wakeup. The scan's own lines, status
//  bar entry and refresh are IntakeActions'.
//
//  gc mutes (PLAN-B12 step 6): gc renames a root's files into its staging
//  folder, and those renames at the old paths would look like arrivals.
//  IntakeActions' runMutation calls autoScanMuteGc before it dispatches a
//  gc (a click, or the Execute follow-up's delete on its held token): the
//  roots' folders, rewritten to the spelling FSEvents reports through the
//  income entries (autoScanMutePaths), are muted from the current FSEvents
//  event id on; autoScanUnmuteGc, when gc exits or does not start, sets the
//  end id. The sink drops the events under those folders with ids in
//  between, whenever it sees them; the mute goes with the first callback
//  that carries a later id, or 10 minutes after gc exited.
//
//  Presence (utility queue only, never the main thread or the watcher's
//  queue): the mount table first (readMountTable, MNT_NOWAIT), then
//  classifyIncome with posixLinkReader, which never examines anything at or
//  under a network mount point, and one local lstat for S_ISDIR when the
//  folder is local.
//
//  Shutdown (autoScanShutdown, on_quit right after actionsShutdown): the
//  scheduler is turned off, the snapshot and the mutes emptied and a
//  stopped flag set; every main-queue block (sink posts, presence results,
//  scan exits, wakeups, mute timers) checks it. A scan still running goes
//  on (mutating calls are not killed before the 15-minute cap) and its
//  result is dropped. The state is leaked on purpose, like IntakeActions'
//  (blocks may run after on_quit).
//
//  Thread-safety: everything here is main-thread only except autoScanSink,
//  which runs on the watcher's queue.
//

#pragma once

#include "../Core/IntakeAutoScan.h"
#include "../Core/IntakeLoadPolicy.h"

#include <cstdint>
#include <string>
#include <vector>

namespace intake {

// The watcher's queue (IntakeWatcher's event sink): see the top of this
// file. Reads only the snapshot; posts to the main thread.
void autoScanSink(const std::vector<AutoScanEvent> &events);

// Main thread, after every load attempt (see the top of this file).
void autoScanAfterLoad(const LoaderStatus &status);

// Main thread: the auto_scan setting, from on_init (before the service
// starts) and on every change.
void autoScanSetEnabled(bool enabled);

// Main thread (IntakeActions runMutation): a gc on `rootPaths` (the CLI's
// spelling) is about to be dispatched; its renames under those folders are
// no arrivals from now on (see the top of this file). Returns the mute's
// handle for autoScanUnmuteGc, or 0 when nothing was muted (no root in an
// income folder, the CLI has no scan, after on_quit).
uint64_t autoScanMuteGc(const std::vector<std::string> &rootPaths);

// Main thread: that gc has exited (or did not start). 0 does nothing.
void autoScanUnmuteGc(uint64_t muteId);

// Main thread (on_quit, after actionsShutdown). Idempotent.
void autoScanShutdown();

} // namespace intake
