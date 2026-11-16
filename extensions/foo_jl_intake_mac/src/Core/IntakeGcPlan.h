//
//  IntakeGcPlan.h
//  foo_jl_intake
//
//  "Delete local copy…" as data (doc 04 v1.2 "Context actions"; doc 03 v1.2
//  `gc` semantics; PLAN.md B9, 3.8): the confirmation's text and the recheck
//  of the captured roots when it is confirmed. Pure: Integration
//  (IntakeActions.mm) reads the sidecars, counts the playlist rows and
//  shows the alert.
//
//  What the confirmation lists: the sidecar files[] of each root, as
//  root_path + "/" + files[].path, shadows included (gc removes every local
//  copy: "shadows included: all local copies go", commands-p3.ts cmdGc).
//  Not `gc --dry-run`: doc 03 v1.2 defines no reply for it, and CLI 0.3.0
//  answers only {id, root_path, dry_run, action, files: <count>}, without
//  the paths. A whole-folder root's other files (covers, cues, logs) are
//  deleted too but are not in files[]; the text says so in one line
//  instead of listing them. Up to 10 paths, then "and N more". A root whose
//  sidecar could not be read is named with the reason; Delete still runs gc
//  on it (gc re-verifies against the journal before it deletes anything).
//
//  "Swap, then delete" is offered while playlist rows of these roots, in any
//  playlist, still point at their income paths and Swap can move every one
//  of them (GcIncomeRows::offerSwap). Rows Swap never moves (a quality
//  shadow, a file files[] does not list: no library copy) are named
//  instead, and rows whose mac-volume path could not be converted (a slow
//  volume) are named as not checked: "Swap, then delete" deletes nothing
//  while any is left.
//
//  Recheck on confirm (recheckGcRoots): the lane was free while the alert
//  was open, so every captured root must still be in the current snapshot,
//  placed, with placed.verified; the others are dropped with a reason each.
//  The permanent guard (IntakeActionTable gcEligibleRoots) applies after it
//  in requestForEntry, whatever this returns.
//
//  Thread-safety: pure functions.
//

#pragma once

#include <cstddef>
#include <functional>
#include <string>
#include <utility>
#include <vector>

#include "IntakeActionTable.h"
#include "IntakeSwapPlanner.h"

namespace intake {

// The playlist rows that still point at the income paths of the roots,
// across every playlist (IntakeActions counts them).
struct GcIncomeRows {
    size_t rows = 0;           // playlist entries on an income path of these roots
    size_t inFirst = 0;        // of them, in the playlist Delete was opened from
    size_t playlists = 0;      // playlists holding them
    size_t noLibraryCopy = 0;  // of them, entries Swap never moves (shadow, not in files[])
    size_t unchecked = 0;      // mac-volume entries whose path was not converted: unknown
    // "Swap, then delete" can end in gc: income rows, and Swap moves each.
    bool offerSwap() const { return rows > 0 && noLibraryCopy == 0; }
    // No entry points at an income path, and none was left unchecked.
    bool clear() const { return rows == 0 && unchecked == 0; }
};

// One root of the confirmation.
struct GcConfirmRoot {
    ActionRoot root;
    bool filesKnown = false;     // its sidecar was read
    std::string filesError;      // why not, when !filesKnown
    bool wholeFolder = false;    // `.intake.json`: artifacts are deleted too
    std::vector<std::string> localPaths;  // root_path + "/" + files[].path, shadows included
};

// root_path + "/" + files[].path for every entry, shadows included.
std::vector<std::string> gcLocalPaths(const PlacedRootFiles &files);

// The confirmation for `roots` once their sidecars were read.
GcConfirmRoot gcConfirmRoot(const ActionRoot &root, const PlacedRootFiles *files, const std::string &error);

// Every local path of `roots`, in order.
std::vector<std::string> gcAllPaths(const std::vector<GcConfirmRoot> &roots);

// "Delete the local copy of this album?" / "Delete the local copies of N
// albums?"
std::string gcConfirmTitle(size_t roots);

// The alert's text: up to `maxListed` paths, one per line, then "and N
// more"; the whole-folder note; the unreadable roots; the rows that still
// play these files ("in the active playlist" when all are in the playlist
// Delete was opened from, else "in N playlists"), those without a library
// copy, the unchecked ones; then that the library copies stay.
std::string gcConfirmText(const std::vector<GcConfirmRoot> &roots, const GcIncomeRows &income,
                          size_t maxListed = 10);

// The test aid's summary: "N path(s): a | b | c (+K more); Swap, then
// delete offered (R income row(s)[ in P playlist(s)])", "...; Swap, then
// delete not offered (R income row(s), K without a library copy)" or
// "...; Swap, then delete not offered (no income row)", then
// "; U row(s) not checked (slow volume)" when U > 0. Up to `maxListed`
// paths.
std::string gcConfirmSummary(const std::vector<GcConfirmRoot> &roots, const GcIncomeRows &income,
                             size_t maxListed = 3);

struct GcRecheck {
    std::vector<ActionRoot> keep;                             // still placed and verified
    std::vector<std::pair<std::string, std::string>> dropped; // id -> why
};

// See the top of this file. `lookup` gives the current record for an id
// (nullptr: no longer listed).
GcRecheck recheckGcRoots(const std::vector<ActionRoot> &roots,
                         const std::function<const IntakeRecord *(const std::string &id)> &lookup);

} // namespace intake
