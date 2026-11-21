//
//  IntakeExecuteFollowUp.h
//  foo_jl_intake
//
//  Execute placement…'s follow-ups as data (doc 04 "Context actions",
//  Execute bullet): Swap to library paths and Delete local copy, chosen in
//  the Execute sheet and run when the detached run ends. Pure: Integration
//  (IntakeActions.mm) shows the checkboxes, keeps the choice in the run file
//  (IntakeExecuteTracker RunFollowUps), waits for the reload after the run,
//  swaps, counts the playlist rows and runs gc.
//
//  The sheet: "Swap playlist rows to the library copies when done" (default
//  on) and "Then delete the local copies" (default off), enabled only while
//  the first is ticked and shown unticked while disabled; ticking the first
//  again brings back the tick it had (followUpCheckboxes). The run gets
//  chosenFollowUps: delete only with swap. The last confirmed choice is kept
//  in two hidden configInts (execute_swap_after, execute_delete_after: 0
//  off, any other value on).
//
//  When the run ends (own, adopted, or finished by a later session), after
//  its result and the reload that follows:
//   1. Swap (planFollowUpSwap): the run's roots that are now `placed` with
//      placed.verified, each once, in run order. The others are left out
//      (the run's own console line and tooltips already report them).
//   2. Delete, when chosen (planFollowUpGc), after the swap: a root is
//      deleted only when it passes the gc guard against the current
//      records (still listed, `placed`, placed.verified, non-empty id:
//      IntakeGcPlan recheckGcRoots, IntakeActionTable gcEligibleRoots) and
//      its census is clear: no playlist entry still points at its income
//      paths, and no entry anywhere was left unchecked (a slow volume:
//      unchecked entries cannot be attributed to a root, so they stop every
//      root). A census that could not run (`refusal`: no data, inert, the
//      lane busy, ...) skips every root. Each skipped root gets a reason;
//      the others go ahead. The ticked checkbox is the confirm_gc
//      confirmation for exactly the roots that go ahead.
//
//  Thread-safety: pure functions.
//

#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "IntakeActionTable.h"
#include "IntakeExecuteTracker.h"
#include "IntakeStatusModel.h"

namespace intake {

// --- the sheet ---

// The hidden settings' defaults (configInts execute_swap_after and
// execute_delete_after).
inline constexpr int64_t kExecuteSwapAfterDefault = 1;
inline constexpr int64_t kExecuteDeleteAfterDefault = 0;

// A stored follow-up switch: 0 is off, any other value on.
inline bool followUpSetting(int64_t stored) {
    return stored != 0;
}

struct FollowUpCheckboxes {
    bool swapOn = true;
    bool deleteEnabled = true;  // clickable: only while swap is on
    bool deleteOn = false;      // shown ticked: only while enabled
};

// What the two checkboxes show for the swap tick and the delete tick the
// user wants (remembered, or ticked before swap was unticked).
FollowUpCheckboxes followUpCheckboxes(bool swapTicked, bool deleteWanted);

// The choice the run records: delete only with swap.
RunFollowUps chosenFollowUps(bool swapTicked, bool deleteTicked);

// The run has something to do when it ends: a recorded choice with swap on.
bool hasFollowUps(const RunFollowUps &followUps);

// --- after the run ---

using FollowUpRecordLookup = std::function<const IntakeRecord *(const std::string &id)>;

struct FollowUpSwapPlan {
    std::vector<std::string> swap;                                // run order, each once
    std::vector<std::pair<std::string, std::string>> notSwapped;  // id, why (Debug lines)
};

// Step 1 (see the top): `runIds` against the records after the reload.
FollowUpSwapPlan planFollowUpSwap(const std::vector<std::string> &runIds, const FollowUpRecordLookup &lookup);

struct FollowUpSkip {
    std::string id;
    std::string why;
    // The tooltip's baseline (IntakeRootErrors): the root's status now,
    // Unknown when it is no longer listed.
    IntakeStatus baseline = IntakeStatus::Unknown;
};

struct FollowUpGcPlan {
    std::vector<ActionRoot> gc;         // swap order: for gc
    std::vector<FollowUpSkip> skipped;  // swap order
};

// Step 2 (see the top). `swapped`: the roots step 1 swapped; `lookup`: the
// records now; `incomeEntries`: per root id, the playlist entries the
// census still finds on its income paths after the swap (absent: none);
// `unchecked`: entries the census could not check, every playlist;
// `refusal`: non-empty when the census could not run.
FollowUpGcPlan planFollowUpGc(const std::vector<std::string> &swapped, const FollowUpRecordLookup &lookup,
                              const std::unordered_map<std::string, size_t> &incomeEntries, size_t unchecked,
                              const std::string &refusal);

// "delete-local: itk_x: local copy kept after run <stem>: <why>" (Info).
std::string followUpSkipLine(const std::string &stem, const FollowUpSkip &skip);
// "delete-local: local copy kept: <why>" (the root's tooltip).
std::string followUpSkipTooltip(const FollowUpSkip &skip);

// "run <stem>: swap/delete as chosen at its start (swap only)" or
// "(swap, then delete)": the Info line when the follow-ups of a run from an
// earlier session start.
std::string earlierRunFollowUpLine(const std::string &stem, const RunFollowUps &followUps);

} // namespace intake
