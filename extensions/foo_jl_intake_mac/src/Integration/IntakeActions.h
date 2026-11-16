//
//  IntakeActions.h
//  foo_jl_intake
//
//  The intake context menu, the mutation lane and the collection picker
//  (PLAN.md B6, B7; doc 04 v1.2 "Context actions", "CLI invocation",
//  "Failure behavior").
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
//  line). Such a menu has no quick assign (ActionContext
//  selectionIncomplete): the rows left out may be other roots.
//
//  Dispatch (main thread, from execute_context_action): the item's entry is
//  copied out of the kept table; the host's selection is not used (v2
//  releases it when execute_context_action returns). An entry that is
//  disabled or has no qualifying root runs nothing.
//   - Refresh intake status: serviceReload(true) (the slow-volume reset
//     and a `version` recheck included).
//   - Propose, Approve: run at once.
//   - Assign to X (B7): runs at once, `assign <id> --collection X --by
//     user`, X being the collection the menu showed (kept in the entry).
//   - Assign to other collection… (B7): the picker. The sheet's window is
//     chosen at the click, as for Reject. `collections --json` runs first,
//     off the main thread (read-only: E_CLI_TIMEOUT at 10 s and killed,
//     killed on quit too; the reply is parsed there too). Only when it has
//     answered, on the main thread, an NSAlert opens as a sheet on that
//     window, or, when it can no longer take one, on the main or key
//     window, else app-modal (started from a run-loop callout, never inside
//     a main-queue block, so the main queue keeps draining while it is
//     up). It has an NSComboBox (type-ahead completion) listing the
//     collection names in the CLI's order and the albums it applies to (up
//     to 10, then "and N more"; for one root also its current target).
//     Nothing is preselected: the field starts empty, so an engine proposal
//     is never turned into a user choice by Return. "Assign" is enabled
//     only while the text stands for a listed name (case-sensitive; a
//     spelling that differs only in Unicode normalisation counts, and the
//     listed name's own bytes go to the CLI: IntakeCollections
//     listedCollectionFor). Cancel or Escape runs nothing.
//     Assign checks the lane and the configuration again, then runs
//     `assign <ids> --collection <name> --by user` on the roots the menu
//     captured. One picker flow at a time: a request while `collections`
//     runs or the sheet is open logs one Info line and does nothing. A
//     failed `collections` (an E_* error, a timeout, a reply that is not
//     an envelope or whose data is not an array or has more than 10000
//     entries, a partial reply) or an empty list logs one Error line and
//     shows no sheet; never modal, never inert. Results that arrive after
//     on_quit are dropped.
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
//  On quit (actionsShutdown) a running `collections` call is killed (the
//  picker's read lane is closed) and an open picker does nothing when it
//  ends.
//

#pragma once

#import "../fb2k_sdk.h"

#include "../../../../shared/jl_decorator_api.h"

#include "../Core/IntakeActionTable.h"
#include "../Core/IntakeRootErrors.h"

#include <functional>
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

// Temporary acceptance aid hooks (IntakeTestActions.mm, removed with it):
// how the picker flow runs for a test_actions step.
struct PickerTestHooks {
    enum class Mode {
        Headless,   // no sheet: after `collections`, assign `collection` when
                    // it is listed, through the same code as the sheet's OK
        AutoClose,  // the real sheet, ended as Cancel after closeSeconds
    };
    Mode mode = Mode::Headless;
    std::string collection;   // Headless
    double closeSeconds = 0;  // AutoClose
    // Main thread, each at most once and `report` first: `report` gets the
    // step's one line (Headless: once the assign was started or skipped;
    // AutoClose: when the sheet is up; both: when the flow ends early),
    // `done` runs when the flow has ended. Neither runs after on_quit.
    std::function<void(const std::string &line)> report;
    std::function<void()> done;
};

// Main thread: the "Assign to other collection…" flow for `entry` (see the
// top of this file); `test` null runs it as a click does. Returns what
// happened so far, for a log line.
std::string actionsAssignOther(const ActionEntry &entry, std::shared_ptr<const PickerTestHooks> test);

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
