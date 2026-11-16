//
//  IntakeActions.h
//  foo_jl_intake
//
//  The intake context menu, the mutation lane, the collection picker, the
//  detached execute and resume runs, Swap to library paths and Delete local
//  copy (PLAN.md B6, B7, B8, B9; doc 04 v1.2 "Context actions", "CLI
//  invocation", "Failure behavior").
//
//  Menu (main thread, from the provider's context_actions): the selected
//  rows go through the decorate pipeline (IntakeNativePath, IntakeView), the
//  roots they map to and the live context (CLI path set, CLI features from
//  the last `version`, inert view, lane busy, confirm_reject, confirm_gc)
//  build an ActionTable (IntakeActionTable), which is kept until the next
//  menu. B9: a row that maps to no root by its path but is a placed root's
//  library copy (the view's library index, IntakeView libraryRecordFor:
//  a row already swapped) adds that root for Delete local copy… only. Each
//  item's action_id encodes the menu serial and its index, so a click on an
//  item of an older menu does nothing. The rows may include ones decorate()
//  never saw, so mac-volume conversions run under a per-menu budget: at
//  most one slow conversion per menu (NativePathMenuBudget), after which
//  rows on volumes not yet converted in that menu map to nothing (one Info
//  line). Such a menu has no quick assign (ActionContext
//  selectionIncomplete): the rows left out may be other roots.
//
//  Dispatch (main thread, from execute_context_action): the item's entry is
//  copied out of the kept table; the host's selection is used only by Swap,
//  which copies its rows (handles) at once (v2 releases it when
//  execute_context_action returns). An entry that is disabled or has no
//  qualifying root runs nothing.
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
//     window, or, when it can no longer take one, on the main, key or
//     foobar2000 main window, else app-modal (started from a run-loop callout, never inside
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
//     else the main, key or foobar2000 main window, else app-modal; it lists
//     up to 10 albums ("and N more") with an optional reason field; off:
//     at once, no reason (the item then has no ellipsis). Only when the
//     CLI has `reject`. No alert when the call could not start anyway.
//   - Execute placement… (B8): describe, then confirm. The sheet's window
//     is chosen at the click, as for the picker. `execute <ids> --dry-run
//     --json` runs on the lane (class ExecuteDryRun: no E_CLI_TIMEOUT,
//     never killed); if it has not answered within 10 s the lane is
//     released (one Info line) and its late result is dropped, and the
//     sheet comes anyway: it lists every captured root without a target
//     and says the check did not finish in 10 s (IntakeExecutePlan
//     planUnchecked); Execute then runs on all of them (the CLI checks each
//     again). When it answers, on the main thread (IntakeExecutePlan): roots it
//     refused get their error as a tooltip (baseline: the menu's status;
//     one console line, then a refresh to show it); with no placeable root,
//     one Error line and no sheet. Otherwise an NSAlert lists up to 10
//     "artist – album → target (n files, k shadows skipped)" rows, then the
//     excluded roots with their error, as a sheet on that window (or the
//     main, key or foobar2000 main window, else app-modal from a run-loop callout, never
//     inside a main-queue block), buttons Execute and Cancel. Execute leaves
//     out the roots that changed while the sheet was open (no longer
//     approved, or another target than the sheet showed: one Error line
//     each, IntakeExecutePlan recheckPlaceable), checks the lane and the
//     configuration again and starts the run on the roots that remain. One
//     execute flow at a time (dry run running or sheet
//     open): another request logs one Info line and does nothing.
//   - Resume placement (B8): no confirmation; starts `execute <ids>
//     --resume --json` as a detached run at once.
//   - Swap to library paths (B9, IntakeSwap): the selected rows that map to
//     the item's roots by income path, in the active playlist; no CLI call,
//     no lane (enabled while an execute runs). One swap at a time.
//   - Delete local copy… (B9): `gc <ids> --json` on the mutation lane (class
//     Mutating: reported at 10 s, not killed before 15 minutes), only on
//     roots captured as placed (the permanent guard, IntakeActionTable
//     gcEligibleRoots, in requestForEntry). With confirm_gc on (default):
//     the sheet's window is chosen at the click; the roots' sidecars are
//     read afresh off the main thread (IntakeSwap swapReadPlacedFiles);
//     then an NSAlert (IntakeGcPlan: up to 10 local paths, shadows
//     included, "and N more"; the whole-folder note; unreadable roots) as a
//     sheet on that window (or the main, key or foobar2000 main window,
//     else app-modal from a run-loop callout), buttons Delete, Cancel and,
//     while rows of these roots in the active playlist still point at their
//     income paths, "Swap, then delete". Delete rechecks the captured roots
//     against the current snapshot (placed with placed.verified; one Error
//     line per root dropped), then the lane and the configuration, then
//     runs gc. "Swap, then delete" swaps those rows first (IntakeSwap) and
//     runs gc only when no row of these roots in that playlist still points
//     at an income path afterwards; otherwise one Error line naming the
//     count and nothing is deleted. One delete flow at a time. With
//     confirm_gc off: gc at once (the item then has no ellipsis). Results
//     as for every mutating call (per-root E_NO_JOURNAL, E_VERIFY,
//     E_BAD_STATUS tooltips; "gc: done for N roots" / "gc failed for ...").
//  A click (or a confirmed Reject or Execute) that starts nothing, because
//  the lane is busy or the CLI path is gone, logs one Error line.
//
//  Detached runs (B8, IntakeExecuteTracker): `execute <ids> --json` and
//  `execute <ids> --resume --json` run in their own process group with
//  stdin /dev/null, stdout to <stem>.json in ~/Library/Caches/foo_jl_intake
//  and stderr to /dev/null (never killed, survive quitting foobar2000). Its
//  run file <stem>.run (ids, root paths, output name, command) is written
//  before the spawn, without a pid (nothing is spawned when it cannot be
//  written: one Error line), and rewritten atomically with the pid and
//  start time as soon as the child exists; one Info line names the pid and
//  the run file. So a run whose foobar2000 is gone before the pid is known
//  is still found by the next session (IntakeExecuteTracker: by the process
//  that has its output open). A run holds the mutation lane until
//  it is finished: every mutating item is disabled and titled "(execute
//  running)", Resume is disabled on its roots, Refresh stays enabled.
//  Progress shows through the FSEvents watcher (the CLI flips the sidecars
//  to placing, then placed); nothing polls. On exit (the runner's PROC
//  source and waitpid for our own child; a ProcessExitWatch, whose
//  waitpid gets ECHILD, for an adopted one) the output is parsed by the
//  envelope rules (an adopted run's exit code is inferred from the
//  envelope), per-root errors are set (baseline: the status the next load
//  shows; a resume row "reverted_to_approved" is a failure with baseline
//  approved), one console line in the B6 format ("execute: done for N
//  roots", "resume failed for 1 root: ..."), serviceRefreshAfterCommand(),
//  the lane is released and both files are deleted. After on_quit results
//  are dropped and the files stay: the next session finishes the run.
//
//  Leftover runs (actionsStartRunScan, from on_init, once): the cache
//  folder is scanned on the mutation queue (IntakeExecuteTracker
//  scanLeftoverRuns). A live run is adopted (lane held, its roots marked
//  running, its pid watched; one Info line with the pid and ids) and
//  finished as above when it ends; a dead one is finished at once (one Info
//  line, then its console line); orphan files are deleted (one Info line
//  with the count). Until the scan is done no mutating call starts (the
//  menu shows mutating items disabled), and the test_actions aid waits for
//  it (actionsAfterRunScan).
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
//  is dropped (the execute dry run, B8). After on_quit (actionsShutdown)
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

// Main thread (provider execute_context_action). `sel` is used only by
// Swap, which copies the rows it needs before returning.
void actionsExecute(uint32_t actionId, metadb_handle_list_cref sel);

// Main thread: the table the menu builds for `handles` (rows matched by
// income path or, for Delete, through the library index), with the live
// context; for the test aid's `rows` step.
ActionTable actionsTableForHandles(metadb_handle_list_cref handles);

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

// Temporary acceptance aid hooks (IntakeTestActions.mm, removed with it):
// how Execute placement… and Resume placement run for a test_actions step.
struct ExecuteTestHooks {
    enum class Mode {
        Headless,   // execute: no sheet; after the dry run, confirm at once
        AutoClose,  // execute: the real sheet, ended as Cancel after closeSeconds
    };
    Mode mode = Mode::Headless;  // ignored by resume
    double closeSeconds = 0;     // AutoClose
    // Main thread, each at most once and `report` first: `report` gets the
    // step's one line (Headless and resume: once the run was spawned or
    // could not start, the dry run's summary first for Headless; AutoClose:
    // when the sheet is up; all: when the flow ends early), `done` runs
    // when the step may go on (spawned, sheet closed, or ended early).
    // Neither runs after on_quit.
    std::function<void(const std::string &line)> report;
    std::function<void()> done;
};

// Main thread: Execute placement… for `entry` (see the top of this file);
// `test` null runs it as a click does. Returns what happened so far.
std::string actionsExecutePlacement(const ActionEntry &entry, std::shared_ptr<const ExecuteTestHooks> test);

// Main thread: Resume placement for `entry`; `test` null runs it as a click
// does. Returns what happened so far.
std::string actionsResume(const ActionEntry &entry, std::shared_ptr<const ExecuteTestHooks> test);

// Temporary acceptance aid hooks (IntakeTestActions.mm, removed with it):
// Swap and Delete local copy… for a test_actions step. Main thread, each at
// most once and `report` first; neither runs after on_quit.
struct SwapTestHooks {
    std::function<void(const std::string &line)> report;  // the swap's console line, or why nothing ran
    std::function<void()> done;
};

struct DeleteTestHooks {
    enum class Mode {
        Delete,          // no sheet: the confirmation answered "Delete"
        SwapThenDelete,  // no sheet: answered "Swap, then delete"
        AutoClose,       // the real sheet, ended as Cancel after closeSeconds
    };
    Mode mode = Mode::Delete;
    double closeSeconds = 0;  // AutoClose
    // `report` gets the step's line: what the confirmation lists and what
    // followed (gc started, not run, the swap's line); AutoClose: when the
    // sheet is up. `done` runs when the step may go on.
    std::function<void(const std::string &line)> report;
    std::function<void()> done;
};

// Main thread: Swap to library paths for `entry` on the rows of `handles`
// (see the top of this file); `test` null runs it as a click does.
std::string actionsSwap(const ActionEntry &entry, metadb_handle_list_cref handles,
                        std::shared_ptr<const SwapTestHooks> test);

// Main thread: Delete local copy… for `entry`; `test` null runs it as a
// click does. Returns what happened so far.
std::string actionsDeleteLocal(const ActionEntry &entry, std::shared_ptr<const DeleteTestHooks> test);

// Main thread: the test aid's `runs` line: the tracked runs (command, pid,
// state, ids) and the lane, e.g. "1 live: execute pid 4242 adopted
// (itk_00000010); lane busy (execute)" or "none; lane free".
std::string actionsRunsDescription();

// Main thread (on_init, after the service started): the leftover-run scan,
// once per session (see the top of this file).
void actionsStartRunScan();

// Main thread: runs `fn` once the leftover-run scan is done (at once when
// it is); never after on_quit.
void actionsAfterRunScan(std::function<void()> fn);

// Any thread: the per-root command errors (the loader's annotator).
RootErrorStore &actionsErrorStore();

// Main thread: the mutation lane holds a call.
bool actionsLaneBusy();

// Main thread (on_quit): later results are dropped; nothing is killed
// (detached runs and their files stay for the next session).
void actionsShutdown();

// Temporary acceptance aid (IntakeTestActions.mm, docs/hidden-options.md):
// main thread, after each successful load; runs foo_jl_intake.test_actions
// once per session.
void testActionsAfterLoad();

} // namespace intake
