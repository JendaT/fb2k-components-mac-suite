//
//  IntakeActions.h
//  foo_jl_intake
//
//  The intake context menu and the mutation lane (PLAN.md B6; doc 04 v1.2
//  "Context actions", "CLI invocation", "Failure behavior").
//
//  Menu (main thread, from the provider's context_actions): the selected
//  rows go through the decorate pipeline (IntakeNativePath, IntakeView), the
//  roots they map to and the live context (CLI path set, CLI features from
//  the last `version`, inert view, lane busy, confirm_reject) build an
//  ActionTable (IntakeActionTable), which is kept until the next menu. Each
//  item's action_id encodes the menu serial and its index, so a click on an
//  item of an older menu does nothing. The rows may include ones decorate()
//  never saw, so mac-volume conversions run under a per-menu budget: at
//  most one slow conversion per menu (NativePathMenuBudget), after which
//  rows on volumes not yet converted in that menu map to nothing (one Info
//  line).
//
//  Dispatch (main thread, from execute_context_action): the item's entry is
//  copied out of the kept table; the host's selection is not used (v2
//  releases it when execute_context_action returns). An entry that is
//  disabled or has no qualifying root runs nothing.
//   - Refresh intake status: serviceReload(true) (the slow-volume reset
//     and a `version` recheck included).
//   - Propose, Approve: run at once.
//   - Reject…: with confirm_reject on (default), an NSAlert first, as a
//     sheet on the window under the pointer (where the menu was opened),
//     else the main window, else the key window, else app-modal; it lists
//     up to 10 albums ("and N more") with an optional reason field; off:
//     at once, no reason (the item then has no ellipsis). Only when the
//     CLI has `reject`. No alert when the call could not start anyway.
//  A click (or a confirmed Reject) that starts nothing, because the lane
//  is busy or the CLI path is gone, logs one Error line.
//
//  Mutation lane (IntakeMutationLane, main thread): one mutating call at a
//  time. A call that finds the lane busy is not started (one Error line).
//  Calls are built and started on a private serial queue (building stats
//  the CLI and bun paths), with output files in
//  ~/Library/Caches/foo_jl_intake; budget reports and completions come back
//  to the main thread with dispatch_async, never dispatch_sync. After every
//  call: the Debug call line (logCliResult), per-root errors into the store
//  with the status the menu showed as their baseline (IntakeMutationResult
//  decides which root an error belongs to; a root that succeeded loses its
//  old error), one console line, then serviceRefreshAfterCommand(). A real
//  call still running at its 10 s report gets E_CLI_TIMEOUT (doc 03
//  "Timeouts"): one Error line, the error on each of its roots and a
//  refresh to show it; it keeps running, and its result replaces those
//  errors. A dry run's 10 s report releases the lane and its late result
//  is dropped (no dry runs in B6 yet). After on_quit (actionsShutdown)
//  results are dropped: no refresh, no UI; the processes keep running
//  (doc 03: mutating calls are not killed before the 15-minute cap, the
//  runner enforces it).
//
//  Nothing here is modal for an error, and no error makes the provider
//  inert.
//

#pragma once

#import "../fb2k_sdk.h"

#include "../../../../shared/jl_decorator_api.h"

#include "../Core/IntakeActionTable.h"
#include "../Core/IntakeRootErrors.h"

#include <memory>
#include <string>
#include <vector>

namespace intake {

class IntakeView;

// Main thread (provider context_actions).
void actionsBuildMenu(metadb_handle_list_cref sel, pfc::list_t<jl_context_action> &out);

// Main thread (provider execute_context_action).
void actionsExecute(uint32_t actionId);

// Main thread: the table for `roots` (records of a view the caller holds)
// with the live context, exactly as the menu builds it.
ActionTable actionsTableFor(const std::vector<const IntakeRecord *> &roots, const IntakeView *view);

// Main thread: runs `entry` as a click on its menu item does. `skipDialog`
// (the test aid) runs Reject without its confirmation, with `reason`.
// Returns what happened, for a log line.
std::string actionsDispatch(const ActionEntry &entry, bool skipDialog, const std::string &reason);

// Any thread: the per-root command errors (the loader's annotator).
RootErrorStore &actionsErrorStore();

// Main thread: the mutation lane holds a call.
bool actionsLaneBusy();

// Main thread (on_quit): later results are dropped; nothing is killed.
void actionsShutdown();

// Temporary acceptance aid (IntakeTestActions.mm, docs/hidden-options.md):
// main thread, after each successful load; runs foo_jl_intake.test_actions
// once per session.
void testActionsAfterLoad();

} // namespace intake
