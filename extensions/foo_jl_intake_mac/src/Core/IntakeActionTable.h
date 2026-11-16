//
//  IntakeActionTable.h
//  foo_jl_intake
//
//  The context menu as data (doc 04 v1.2 "Context actions"; PLAN.md B6,
//  risks 3a and 6). SDK-free: Integration maps the selected rows to records
//  (the same per-row pipeline as decorate), builds the table here, turns it
//  into a flat jl_context_action list and keeps it until the host invokes
//  an item: `action_id` indexes this table (encodeActionId), so a state
//  change between the menu and the click can never retarget an item.
//
//  Selection -> roots: the rows' records, deduplicated by id, in selection
//  order (selectionRoots). m is their count.
//
//  Enable rule (doc 03 v1.2 "Legal source statuses", narrowed by doc 04):
//
//    Action                        enabled on roots in
//    Propose                       resolved
//    Assign to X (<= 4)            one root selected: new, resolved, proposed,
//                                  approved, with a `ranked` entry other than
//                                  the target (alternates from `ranked` only)
//    Assign to other collection…   new, resolved, proposed, approved
//    Approve                       proposed, target_path not null
//    Reject…                       new, resolved, proposed, approved; only
//                                  listed when the CLI has `reject`
//    Execute placement…            approved, target_path not null
//    Resume placement              placing, CLI with per-root resume
//                                  (cliSupportsCommand), no live run on it
//    Swap to library paths         placed with placed.verified
//    Delete local copy…            placed with placed.verified (never
//                                  rejected, never a root that is not placed)
//
//  An unknown target_path (CLI before 0.3.0) does not block Approve or
//  Execute: the CLI's own refusal is shown instead (doc 04 v1.2).
//
//  Table rules:
//   - No CLI path: no items at all.
//   - Otherwise "Refresh intake status" is always the last item, enabled.
//   - An inert view, or a selection that maps to no root: Refresh only.
//   - Every exposed action is listed (Assign to X only for one selected
//     root with alternates); it is enabled when at least one selected root
//     qualifies, runs on those roots only, and its title carries "(n of m)"
//     when 0 < n < m. Roots go by id: no entry ever runs with zero ids, and
//     no all-roots form exists here (IntakeCommandArgs refuses both too).
//   - Mutating items are disabled while the mutation lane is busy, with
//     " (execute running)" while an execute holds it.
//   - Title: base, " (n of m)", " (execute running)", then "…" when the
//     action asks first (actionAsksFirst): "Reject (4 of 5)…".
//   - Order: the fixed doc 04 order (kOrder), Refresh last, except that
//     "Assign to other collection…" is the first item when the review rule
//     (IntakeReviewRule, amber) fires on a selected root it runs on (doc 04
//     v1.2: "first when amber"; PLAN.md B7, REQ-31).
//  Quick assign ("Assign to X", B7): one entry per alternate (at most 4),
//  only for exactly one selected root; the entry carries its collection,
//  so the click runs `assign <id> --collection X --by user` with the name
//  the menu showed. None when the selection is incomplete (rows the menu
//  could not map may be other roots, so m is only a lower bound).
//  The menu shows menuActions(): Propose, Assign to X, Assign to other
//  collection…, Approve, Reject… and Refresh (B7). Execute and Resume (B8),
//  Swap and Delete (B9) are already decided here and stay hidden until
//  then. b6Actions() is the B6 subset, kept for tests.
//
//  Thread-safety: pure functions.
//

#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "IntakeCapabilities.h"
#include "IntakeCommandArgs.h"
#include "IntakeStatusModel.h"

namespace intake {

enum class IntakeAction : uint8_t {
    Propose,
    AssignTo,
    AssignOther,
    Approve,
    Reject,
    Execute,
    Resume,
    Swap,
    DeleteLocal,
    Refresh,
};

// "propose", "assign", "assign-other", "approve", "reject", "execute",
// "resume", "swap", "delete-local", "refresh".
const char *actionName(IntakeAction action);

// True for the actions that run a mutating CLI call through the lane:
// every action but Swap (a playlist operation) and Refresh.
bool actionIsMutating(IntakeAction action);

// The CLI command a mutating action runs; false for Swap and Refresh.
bool actionCommand(IntakeAction action, CliCommand &out);

// "Propose", "Assign to <collection>", "Reject", ...: the title without
// "(n of m)" or an ellipsis.
std::string actionBaseTitle(IntakeAction action, const std::string &collection = std::string());

// The actions the context menu shows (B7: Propose, Assign to X, Assign to
// other collection…, Approve, Reject…, Refresh).
const std::vector<IntakeAction> &menuActions();

// The B6 subset (Propose, Approve, Reject…, Refresh).
const std::vector<IntakeAction> &b6Actions();

struct ActionContext {
    bool cliConfigured = false; // cli_path is set
    bool inert = false;         // the view is inert (doc 03 "Inert state")
    CliVersionInfo cli;         // the last passing `version` (feature detection)
    bool laneBusy = false;
    bool executeRunning = false;           // the lane holder is an execute or resume
    std::vector<std::string> liveRunIds;   // roots with a live execute run (B8)
    bool confirmReject = true;             // confirm_reject: Reject asks first
    // Some selected rows were left unmapped (NativePathMenuBudget): they
    // may be roots, so m is only a lower bound.
    bool selectionIncomplete = false;
};

// Choosing the action opens a dialog first, so its title ends in an
// ellipsis (U+2026, the last character, after any "(n of m)"): Assign to
// other collection (the picker), Execute placement (always asks), Delete
// local copy, and Reject while confirm_reject is on.
bool actionAsksFirst(IntakeAction action, const ActionContext &context);

// The per-root half of the enable rule (selection size and lane aside).
bool rootQualifies(IntakeAction action, const IntakeRecord &record, const ActionContext &context);

// The alternates for "Assign to X": `ranked` minus the target, in order,
// each once, at most `limit`. None when `ranked` is absent or empty (no
// sidecar fallback, doc 04 v1.2).
inline constexpr size_t kMaxAssignAlternates = 4;
std::vector<std::string> assignAlternates(const IntakeRecord &record, size_t limit = kMaxAssignAlternates);

// "Assign to other collection…" goes first: the review rule fires on one of
// `roots` that the action runs on.
bool assignOtherFirst(const std::vector<const IntakeRecord *> &roots, const ActionContext &context);

// A root as the table captured it: enough to run, label and report.
struct ActionRoot {
    std::string id;
    std::string rootPath;
    std::string albumartist;
    std::string album;
    IntakeStatus status = IntakeStatus::Unknown;
    std::string targetCollection;  // proposal.target_collection; empty without one
};

ActionRoot actionRootFor(const IntakeRecord &record);

struct ActionEntry {
    IntakeAction action = IntakeAction::Refresh;
    std::string title;
    bool enabled = false;
    std::vector<ActionRoot> roots;  // the qualifying roots, selection order
    std::string collection;         // Assign to X; Assign to other collection…
                                    // gets the picker's choice in a copy
};

struct ActionTable {
    std::vector<ActionEntry> entries;
    size_t selectedRoots = 0;  // m
};

// The selection's roots: nullptr entries (rows that map to no root) are
// skipped, repeats (by id) dropped, selection order kept.
std::vector<const IntakeRecord *> selectionRoots(const std::vector<const IntakeRecord *> &rows);

// The table for `roots` (see the top of this file). `exposed` lists the
// actions to show (order does not matter; the table order is fixed).
ActionTable buildActionTable(const std::vector<const IntakeRecord *> &roots, const ActionContext &context,
                             const std::vector<IntakeAction> &exposed = menuActions());

// The first entry for `action`, or nullptr.
const ActionEntry *findEntry(const ActionTable &table, IntakeAction action);

// The CLI request an entry runs (ids in table order, the reason for Reject,
// the collection for Assign to X and for a picked Assign to other
// collection…). False, with `why` set, when nothing may run: a disabled
// entry, an empty root set, an assign without a collection, or an action
// that is not a CLI call.
bool requestForEntry(const ActionEntry &entry, const std::string &reason, CliRequest &out, std::string *why = nullptr);

// "Artist – Album" (U+2013), or whichever of the two is known, or the
// root's folder name.
std::string albumLabel(const ActionRoot &root);

// The albums a confirmation lists: one label per line, at most `maxListed`,
// then "and N more".
std::string affectedAlbumsText(const std::vector<ActionRoot> &roots, size_t maxListed = 10);

// action_id: a menu serial (24 bits, never 0 after masking) and the entry
// index (8 bits), so an id from an older menu is recognised and ignored.
inline constexpr size_t kMaxActionEntries = 255;
uint32_t encodeActionId(uint32_t menuSerial, size_t index);
bool decodeActionId(uint32_t actionId, uint32_t &menuSerial, size_t &index);
// The next serial after `serial`, skipping values that mask to 0.
uint32_t nextMenuSerial(uint32_t serial);

} // namespace intake
