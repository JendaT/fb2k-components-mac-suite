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
//     line per session while auto_scan is on). After the first Ready load
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
//  lane free calls autoScanStartDue, which starts the scan.
//
//  Presence (utility queue only, never the main thread or the watcher's
//  queue): the mount table first (readMountTable, MNT_NOWAIT), then
//  classifyIncome with posixLinkReader, which never examines anything at or
//  under a network mount point, and one local lstat for S_ISDIR when the
//  folder is local.
//
//  Shutdown (autoScanShutdown, on_quit right after actionsShutdown): the
//  scheduler is turned off, the snapshot emptied and a stopped flag set;
//  every main-queue block (sink posts, presence results, wakeups) checks
//  it. The state is leaked on purpose, like IntakeActions' (blocks may run
//  after on_quit).
//
//  Thread-safety: everything here is main-thread only except autoScanSink,
//  which runs on the watcher's queue.
//

#pragma once

#include "../Core/IntakeAutoScan.h"
#include "../Core/IntakeLoadPolicy.h"

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

// Main thread (on_quit, after actionsShutdown). Idempotent.
void autoScanShutdown();

} // namespace intake
