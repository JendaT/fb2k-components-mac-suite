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
//  never saw, so mac-volume conversions run under a per-menu budget
//  (NativePathMenuBudget): a volume with 3 slow conversions in the menu
//  makes no more calls, and its remaining rows map to nothing (one Info
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
//   - Propose, Approve: run at once. B12: a Propose of more than 5 roots
//     runs as the chunked propose (below) instead of one call: it starts
//     the chain, or joins the one running.
//   - Assign to X (B7): runs at once, `assign <id> --collection X --by
//     user`, X being the collection the menu showed (kept in the entry).
//     Then `propose` (B13-lite) for the roots that were resolved at menu
//     time and that the assign did not fail (IntakeAssignPropose; exit 2
//     proposes nothing; new, proposed and approved roots are skipped with
//     one Debug line). The lane is held from the assign's start to the
//     propose's end, and released on every other path (nothing to
//     propose, the propose refused or failed, quit); one refresh after the
//     last call. Propose errors show as usual (tooltip, console line); a
//     root whose propose fails keeps its assignment. B12: more than 5 roots
//     to propose go to the chunked propose (below): the assign's run ends
//     as when nothing is proposed, and the chain's first refresh shows it.
//   - Assign to other collection… (B7): the picker. The sheet's window is
//     chosen at the click, as for Reject. `collections --json` runs first,
//     off the main thread (read-only: E_CLI_TIMEOUT at 10 s and killed,
//     killed on quit too; the reply is parsed there too). Only when it has
//     answered, on the main thread, an NSAlert opens as a sheet on that
//     window, or, when it can no longer take one, on the main, key or
//     foobar2000 main window, else app-modal (started from a run-loop callout, never inside
//     a main-queue block, so the main queue keeps draining while it is
//     up). It has a search field over a list visible from the start
//     (JLIntakeCollectionPicker, IntakeCollectionSearch), in sections:
//     "Suggested" (the selected roots' proposal.ranked[0]: one when they
//     agree, else their distinct values, up to 3; left out when none),
//     "Recent" (the last five collections assigned to, the hidden
//     recent_collections key, names no longer listed dropped) and "All
//     collections" in the CLI's order; headers are not choosable and a name
//     may repeat across sections. Above it, the albums it applies to (up to
//     10, then "and N more"; for one root also its current target).
//     Nothing is highlighted at first, so an engine proposal is never
//     turned into a user choice by Return. Typing filters the list live
//     into one ranked list (substring, ignoring case, diacritics and the
//     square brackets: "folk" finds "[Folktronica & Ezo techno]") and
//     highlights the first match. Keys stay in the field: Up and Down, or a
//     click, highlight a row and show its name in the field. The
//     highlighted row is the choice: Return or a double-click assigns it;
//     Escape or Cancel runs nothing. "Assign" is enabled while a name is
//     highlighted, or the field holds a listed name (case-sensitive; a
//     spelling that differs only in Unicode normalisation counts, and the
//     listed name's own bytes go to the CLI: IntakeCollections
//     listedCollectionFor). Confirming moves the name to the front of
//     Recent.
//     Assign checks the lane and the configuration again, then runs
//     `assign <ids> --collection <name> --by user` on the roots the menu
//     captured, followed by `propose` as for Assign to X. One picker flow
//     at a time: a request while `collections` runs or the sheet is open
//     logs one Info line and does nothing. A
//     failed `collections` (an E_* error, a timeout, a reply that is not
//     an envelope or whose data is not an array or has more than 10000
//     entries, a partial reply) or an empty list logs one Error line and
//     shows no sheet; never modal, never inert. Results that arrive after
//     on_quit are dropped.
//   - Reject…: with confirm_reject on (default), an NSAlert first, as a
//     sheet on the window under the pointer (where the menu was opened),
//     else the main, key or foobar2000 main window, else app-modal; it lists
//     up to 10 albums ("and N more") and has a reason pop-up ("Already in
//     library", "Lower quality than library copy", "Not wanted", "Other…";
//     IntakeRejectReason) above a free-text field. A preset's text is the
//     reason and the field shows it, disabled; "Other…" enables the field
//     (empty: no reason). The last choice is kept for the session only
//     ("Already in library" at first, IntakeRejectReason
//     rejectInitialChoice). Return rejects, Escape cancels. Off: at once, no
//     reason (the item then has no ellipsis). Only when the CLI has
//     `reject`. No alert when the call could not start anyway.
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
//     inside a main-queue block), buttons Execute and Cancel, and two
//     checkboxes (JLIntakeExecuteFollowUps, IntakeExecuteFollowUp): "Swap
//     playlist rows to the library copies when done" and "Then delete the
//     local copies" (enabled only while the first is ticked). Swap opens as
//     last confirmed (hidden configInt execute_swap_after, default 1,
//     written on Execute); delete opens unticked every time and is never
//     saved. Execute leaves out the roots that changed while the sheet was
//     open (no longer approved, another target than the sheet showed, or
//     no target now: one Error line each, IntakeExecutePlan
//     recheckPlaceable), checks the lane and the configuration again and
//     starts the run on the roots that remain, with the follow-ups in its
//     run file. One execute flow at a time (dry run running or sheet open):
//     another request logs one Info line and does nothing.
//   - Resume placement (B8): no confirmation; starts `execute <ids>
//     --resume --json` as a detached run at once.
//   - Swap to library paths (B9, IntakeSwap): the selected rows that map to
//     the item's roots by income path, in the active playlist; no CLI call,
//     no lane (enabled while an execute runs). One swap at a time.
//   - Delete local copy… (B9): `gc <ids> --json` on the mutation lane (class
//     Mutating: reported at 10 s, not killed before 15 minutes), only on
//     roots captured as placed with placed.verified (the permanent guard,
//     IntakeActionTable gcEligibleRoots, in requestForEntry), never while
//     the view is inert. With confirm_gc on (default): the sheet's window
//     and the active playlist are captured at the click; the roots'
//     sidecars are read afresh off the main thread (IntakeSwap
//     swapReadPlacedFiles; no answer within 10 s ends the flow with one
//     Error line); then the entries of every playlist that still point at
//     income paths of these roots are counted (fail closed: a mac-volume
//     row whose path was not converted counts as unchecked), with those
//     Swap never moves (shadows, files files[] does not list); then an
//     NSAlert (IntakeGcPlan: up to 10 local paths, shadows included, "and N
//     more"; the whole-folder note; unreadable roots; the income rows) as a
//     sheet on that window (or the main, key or foobar2000 main window,
//     else app-modal from a run-loop callout), buttons Delete, Cancel and,
//     while income rows remain and Swap can move every one,
//     "Swap, then delete". Delete rechecks the captured roots against the
//     current snapshot (placed with placed.verified; one Error line per
//     root dropped), then the lane and the configuration, then runs gc.
//     "Swap, then delete" swaps those rows first (IntakeSwap), in the
//     captured playlist and then in every other playlist holding them, and
//     runs gc only when no entry of any playlist still points at an income
//     path afterwards and none was unchecked; otherwise one Error line
//     naming the counts and nothing is deleted. One delete flow at a time.
//     With confirm_gc off: gc at once (the item then has no ellipsis).
//     Results as for every mutating call (per-root E_NO_JOURNAL, E_VERIFY,
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
//  Execute follow-ups (IntakeExecuteFollowUp): an execute run whose run
//  file records swap on (own, adopted, or finished by the leftover scan;
//  the last two log "run <stem>: swap/delete as chosen at its start")
//  waits for the refresh after its result (serviceRefreshAfterCommand's
//  `finished`; one that did not succeed stops it, one Info line). Then the
//  rows of its roots now placed with placed.verified are swapped in every
//  playlist (the chain "Swap, then delete" uses, IntakeSwap, no lane);
//  with delete on, the lane is taken, the Delete census counts the entries
//  still on their income paths, and gc runs (runMutation on that token)
//  for the roots that pass the gc guard and whose census is clear: the
//  checkbox is their confirm_gc confirmation, no sheet. The others get one
//  Info line and a tooltip each (baseline: their status then) and a
//  refresh shows them. The lane is released on every path (nothing to
//  delete, a refusal, gc's exit). One chain at a time, queued in the order
//  the refreshes come back; a chain ends when its gc ends. A quit drops
//  the chains not done, and the next start cannot do them (the run file
//  went when the run's result was read): actionsShutdown logs one Info
//  line per run whose follow-ups had not finished, from its end to its
//  chain's end (waiting for the refresh, queued, or swapping; nothing was
//  deleted; IntakeExecuteFollowUp followUpQuitLine). A gc already running
//  is not stopped and finishes on its own: no line for it.
//
//  Leftover runs (actionsStartRunScan, from on_init, once): the cache
//  folder is scanned on the mutation queue (IntakeExecuteTracker
//  scanLeftoverRuns). A live run is adopted (lane held, its roots marked
//  running, its pid watched; one Info line with the pid and ids) and
//  finished as above when it ends; a dead one is finished at once (one Info
//  line, then its console line); orphan files are deleted (one Info line
//  with the count). Until the scan is done no mutating call starts (the
//  menu shows mutating items disabled), and the auto-scan's startup check
//  (B12) waits for it (actionsAfterRunScan).
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
//  Auto-scan (B12, actionsStartAutoScan; IntakeAutoScanDriver decides when
//  and which income): `scan <income> --json` (the income's absolute path
//  instead of a name starting with '-') holds the lane as LaneHolder::Scan
//  from its start to its exit, like a real mutating call (class Mutating:
//  reported at 10 s, killed at the 15-minute cap). Meanwhile the menu's
//  mutating items are disabled and read " (scan running)", and a click
//  that cannot start logs "a background scan is running". Lines, all Info,
//  never an Error line, sheet or alert (IntakeAutoScanResult): "auto-scan:
//  scanning income <name> (new files|startup)" at the start; at 10 s
//  "auto-scan: <name> still running (E_CLI_TIMEOUT: ...)", with no tooltip
//  and no refresh (a scan has no roots); at the end "done in 12.3 s: N new
//  root(s), K kept" (counts read leniently from data[].written and kept),
//  "done ... with errors", "failed: <errors>" or "not started (...)". No
//  per-root error is set for the scan. After a scan that exited 0 or 1, the
//  same lane run proposes the roots it newly wrote that are resolved
//  (PLAN-B12 scope addition 1; IntakeAutoScanResult proposeAfterScan: never
//  a new root, never one that needs review, never one it kept, never the
//  income folder itself; nothing while the provider is inert): one Info
//  line "propose: starting after auto-scan of <name> for N roots: <ids>",
//  then `propose <ids>` on the scan's lane token. The lane stays
//  LaneHolder::Scan until that propose ends, so the menu keeps reading
//  " (scan running)". The propose's errors become tooltips like any
//  propose's, but its console line and its 10 s report are Info (the 10 s
//  report without tooltip or refresh, like the scan's); a cap kill of the
//  propose does not disable the income (only the scan's does). Every path
//  that releases the lane (finish, refusal, E_NO_CLI, cap kill, nothing to
//  propose, the propose's finish or refusal) ends the status bar entry and
//  hands the exit to the driver; one that ran a process refreshes first,
//  once per run. After on_quit the result only releases the lane. More than
//  5 roots to propose go to the chunked propose (below): the run ends with
//  the scan's own result, as when nothing is proposed, and the chain's
//  refresh is its one refresh.
//
//  Chunked propose (B12, IntakeProposeChain): a propose of more than 5
//  roots (kProposeChunkSize; the user's Propose, the propose after an
//  assign, the auto-propose after a scan) runs as a chain of `propose`
//  calls of up to 5 roots, each its own lane run (LaneHolder::Mutating), so
//  no batch holds the lane for 15 minutes and a cap kill loses at most one
//  chunk. 5 or fewer keep their single call. One chain at a time: roots
//  asked for while it runs join it (deduplicated against its pending and
//  handled roots; one Info line, also when none is new, naming the roots it
//  already failed: they are proposed again only after it ends). Before
//  each chunk (also after a wait for the lane) the view is refreshed and
//  every pending root's status re-checked: a root no longer resolved, or
//  not in the view, is skipped (one Debug line); a refresh that did not
//  succeed stops the chain. Between chunks the lane is free (a user's
//  mutating click or an auto-scan may take it; while a chunk runs a click
//  is refused as today); a busy lane, or an Execute follow-up still to run
//  (as actionsLaneFree), is waited for with a 2 s retry (one Info line per
//  wait, one timer at most). After the last chunk the chain ends at once,
//  without the lane. Lines, Info unless a whole chunk failed: "propose:
//  starting for 49 roots, in chunks of 5: <ids>", "propose: chunk 2 of 10
//  starting for 5 roots: <ids>", its 10 s report "propose: chunk 2 of 10
//  still running (E_CLI_TIMEOUT: no reply after 10 s; the chunk
//  continues)" (no tooltip, no refresh), its result line with "(chunk 2 of
//  10)", and at the end "propose: done for 46 of 49 roots in 10 chunks;
//  failed: <ids>". Per-root errors become tooltips as for any propose
//  (baseline resolved). The chain stops (one Info line "propose: stopped
//  after chunk k of n (<reason>); done for 34 of 40 roots; failed: <ids>;
//  M roots not proposed: <ids>", or "stopped before the first chunk") when
//  a chunk was killed at the hard cap, on E_NO_CLI, when a chunk is
//  refused, a refresh before a chunk failed, the view turns inert or the
//  CLI path is gone; per-root and other envelope errors do not stop it. A
//  quit drops it: the chunk running goes on, and the roots not handed out
//  yet get one Info line "propose: M roots not proposed (quit): <ids>".
//
//  gc mute (B12): every gc (Delete local copy…, confirmed or not, and the
//  Execute follow-up's delete on its held token) goes through runMutation,
//  which asks the driver to mute the roots' folders (autoScanMuteGc) right
//  before it dispatches gc and ends the mute (autoScanUnmuteGc) when gc
//  exits or is refused.
//
//  Status bar (B14, IntakeActivityHub): every mutating call, the execute dry
//  run, each detached run (own or adopted), each swap, the Delete flow's
//  sidecar reads and the auto-scan (B12: "Scanning income <name>…") is an
//  entry from the moment it holds its lane token, run stem or serial until
//  every path that lets go of it (result, refusal, timeout) calls
//  activityEnd; the propose after an assign renames the assign's entry and
//  its end folds in the assign's result, and the propose after an
//  auto-scan does the same with the scan's ("Proposing N albums…", then
//  "Scanned <name>, proposed N albums"); the chunked propose has one entry
//  for the whole chain ("Proposing 49 albums…", then "Proposing 10/49:
//  Artist – Album"; "Proposed 49 albums" or "Propose failed: 3 of 49
//  albums"); the dry run's entry outlives its
//  10 s report until its answer, at most 15 minutes, and the scan's its 10 s
//  report until its exit. actionsShutdown clears them. The list of pairs is
//  in IntakeActivityHub.h.
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

#include "../Core/IntakeAutoScan.h"
#include "../Core/IntakeRootErrors.h"

namespace intake {

// Main thread (provider context_actions).
void actionsBuildMenu(metadb_handle_list_cref sel, pfc::list_t<jl_context_action> &out);

// Main thread (provider execute_context_action). `sel` is used only by
// Swap, which copies the rows it needs before returning.
void actionsExecute(uint32_t actionId, metadb_handle_list_cref sel);

// Main thread (on_init, after the service started): the leftover-run scan,
// once per session (see the top of this file).
void actionsStartRunScan();

// Main thread: runs `fn` once the leftover-run scan is done (at once when
// it is); never after on_quit. B12: the auto-scan's startup check waits
// here, so a live execute run adopted by the scan holds the lane before
// the startup scans ask for it.
void actionsAfterRunScan(std::function<void()> fn);

// Any thread: the per-root command errors (the loader's annotator).
RootErrorStore &actionsErrorStore();

// Main thread: the mutation lane holds a call.
bool actionsLaneBusy();

// Main thread (B12, the auto-scan's laneFree): a mutating call could take
// the lane now: on_quit has not run, the leftover-run scan is done, no call
// holds the lane, and no Execute follow-up (swap, then delete) is waiting
// for its reload or running: the lane is free between those steps, and the
// delete step refuses while a scan holds it.
bool actionsLaneFree();

// B12: how actionsStartAutoScan went.
enum class AutoScanStart {
    Started,   // the scan is on its way; `done` runs once, later
    LaneTaken, // the lane is not free (see actionsLaneFree): nothing started
    Refused,   // no CLI configuration (intake not running, no CLI path) or intake is inert: nothing started,
               // one Info line
};

// Main thread (B12, IntakeAutoScanDriver): `scan <income> --json` for
// `job` on the mutation lane (see "Auto-scan" at the top of this file).
// `done` runs once on the main thread with the exit, after the lane is
// released at the end of the run (the propose after the scan included) and
// the refresh asked for when the scan ran, never after
// on_quit; it never runs when this returns anything but Started.
AutoScanStart actionsStartAutoScan(const AutoScanJob &job, std::function<void(AutoScanExit how)> done);

// Main thread (on_quit): later results are dropped; nothing is killed
// (detached runs and their files stay for the next session).
void actionsShutdown();

} // namespace intake
