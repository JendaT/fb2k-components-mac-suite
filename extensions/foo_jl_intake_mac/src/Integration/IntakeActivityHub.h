//
//  IntakeActivityHub.h
//  foo_jl_intake
//
//  The session's activity model (IntakeActivity) for the status bar of
//  ongoing operations (PLAN-B14 section 2): the one place the hooks in
//  IntakeActions and IntakeSwap write to, and the one the status provider
//  reads from.
//
//  Hooks (main thread). activityBegin() when an operation has taken what it
//  needs (the lane token, the run stem, the swap); activityEnd() wherever it
//  lets go of it, on every path: result, refusal, timeout. The pairs, by key
//  (IntakeActivity.h):
//   - lane token: runMutation begins (propose, assign, approve, reject, gc;
//     the Execute follow-up's gc too); onFinished, onRefused and
//     proposeAfterAssignOrEnd's end of the run end it; the propose after an
//     assign renames it (AssignThenPropose), and its end folds in the
//     assign's result (activityAfterAssign: an assign that failed for some
//     roots ends the entry failed). The execute dry run begins in
//     actionsExecutePlacement and ends in onExecuteDryRun (its answer, a late
//     one included: the 10 s report frees the lane but the entry stays, Q2)
//     or onRefused. The runner never kills a dry run, so its answer may
//     never come (a hung share): the entry also has a deadline at the
//     mutating calls' 15-minute cap (ProcessLimits::hardCapSeconds), where
//     it ends failed "no answer within 15 min"; an answer after that finds
//     it ended. reportBudget never ends an entry.
//   - lane token, B12's auto-scan: actionsStartAutoScan begins it ("Scanning
//     income <name>…") once it holds the lane; endAutoScanRun ends it on
//     every path that releases the lane (its finish, with the roots it
//     wrote as the count; a refused request; E_NO_CLI; the cap kill). The
//     propose after it (proposeAfterScanOrEnd) renames it (ScanThenPropose,
//     "Proposing N albums…"), and that propose's finish or refusal ends it
//     through endAutoScanRun with the scan's result folded in
//     (activityAfterScan: a scan with errors ends the entry failed). The
//     10 s reports do not end it.
//   - run stem: startDetachedRun and onRunScan's adopted runs begin
//     (activityBeginRun); finishRun (at tracker.remove) and onRunRefused end.
//   - swap serial: swapStart begins, its finish ends.
//   - census serial: actionsDeleteLocal's sidecar reads begin;
//     onDeleteFilesRead (activityReadsResult: failed when a file list
//     could not be read) or its 10 s timeout end.
//   - quit: actionsShutdown calls activityClear(), which drops everything
//     and fires the change handler once; later hooks do nothing.
//  Loads and Refresh are not entries.
//
//  Execute n/m (IntakeRunProgress): activityBeginRun seeds the run's root
//  statuses from the current view; every published view (IntakeService's
//  publish handler, loader queue) is handed to activityViewPublished, which
//  does nothing unless a run is tracked, and otherwise steps each run's
//  progress on the main thread and reports done/total and the album placing
//  now.
//
//  The provider's side (main thread): activityModel() to read the line and
//  the items at activityNowMs(); activitySetChangeHandler() for one handler
//  that is called after every change that may alter the line or the list,
//  and again when a result's 10 s run out or a deadline falls (the hub
//  keeps one dispatch_after at the model's nextExpiry, on the wall clock
//  like activityNowMs, so it also fires on time after the Mac slept). The
//  handler runs on the main thread. The status provider
//  (IntakeStatusProvider.mm) installs it from on_init.
//
//  The state is leaked on purpose (like the actions' state): hooks may run
//  after on_quit.
//

#pragma once

#include "../Core/IntakeActivity.h"

#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace intake {

class IntakeView;

// --- the provider's side (main thread) ---

const ActivityModel &activityModel();
// Unix epoch milliseconds: the `now` of every hook and query.
int64_t activityNowMs();
// Replaces the change handler (empty: none).
void activitySetChangeHandler(std::function<void()> handler);

// --- hooks (main thread) ---

void activityBegin(const std::string &key, ActivityKind kind, size_t count, const std::string &firstLabel);

// An execute or resume run under activityRunKey(stem), with its progress
// seeded from the current view.
void activityBeginRun(const std::string &stem, CliCommand command, const std::vector<std::string> &ids,
                      const std::string &firstLabel);

// The running entry under `key` ends with `result` `afterMs` from now
// unless something ends it before (the execute dry run's 15 minutes).
void activityDeadline(const std::string &key, int64_t afterMs, const ActivityResult &result);

void activityRename(const std::string &key, ActivityKind kind, size_t count, const std::string &firstLabel);

// The one end helper: every path that lets go of what a begin took calls
// it. An unknown or already ended key does nothing.
void activityEnd(const std::string &key, const ActivityResult &result, std::optional<size_t> count = std::nullopt);

// Quit: drops every entry, fires the change handler once; hooks do nothing
// afterwards.
void activityClear();

// Any thread: a view was published (IntakeService). Cheap when no run is
// tracked.
void activityViewPublished(const std::shared_ptr<const IntakeView> &view);

// "Artist – Album" of root `id` in the current view, else the folder of
// `rootPath`, else the id.
std::string activityLabelFor(const std::string &id, const std::string &rootPath = std::string());

} // namespace intake
