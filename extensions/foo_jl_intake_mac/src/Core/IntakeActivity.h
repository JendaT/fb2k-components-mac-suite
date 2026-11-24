//
//  IntakeActivity.h
//  foo_jl_intake
//
//  The activity model behind the status bar of ongoing operations (PLAN-B14
//  section 2; shared/jl_status_api.h): what intake is doing now, and what it
//  finished in the last 10 seconds, as one short line and a list. Pure, no
//  SDK, main thread only. Integration (IntakeActivityHub) feeds it from the
//  hooks in IntakeActions and IntakeSwap; the status provider only reads it
//  (line, items, nextExpiry).
//
//  Entries. begin() adds a running entry under a key and returns its id
//  (stable while the entry exists). The key says who ends it:
//   - activityLaneKey(token): a mutating call or the execute dry run, by its
//     mutation lane token (an assign and the propose after it share one);
//   - activityRunKey(stem): an execute or resume run, by its run stem;
//   - activitySwapKey(serial): one swap of playlist rows;
//   - activityCensusKey(serial): the Delete flow's sidecar reads.
//  progress() sets done/total and the album being worked on; rename()
//  changes the kind and the count (the propose after an assign); end() makes
//  the entry a result, succeeded or failed with a short reason; clear()
//  (quit) drops everything. All of them work on the RUNNING entry of a key:
//  a key with no running entry (never begun, already ended, cleared) is
//  ignored and they return false, so a double end, or an end after quit, is
//  harmless. begin() on a key that still has a running entry drops that
//  entry first (it never ended: a hook bug, not a state to show twice).
//
//  Time. Every query takes `now` in milliseconds (Unix epoch in production,
//  any clock in tests). A result is shown while ended <= now < ended + 10 s
//  (kActivityResultMs), then it is gone; a result whose end lies after `now`
//  (the wall clock went back) is gone too, so nothing lingers. nextExpiry()
//  is the earliest time after `now` at which a result goes, for the
//  provider's timer; prune() drops the ones gone.
//
//  The line (line(now)):
//   - something running: the most recently begun running entry, plus
//     " (+N more)" when N others run;
//   - nothing running: the newest result still inside its 10 s;
//   - else none (idle shows no line at all).
//  Running texts (UTF-8, "…" U+2026; one album: its label instead of the
//  count; the label is "Artist – Album" from IntakeActionTable albumLabel):
//     Propose             "Proposing 3 albums…"            "Proposing Album…"
//     Assign              "Assigning 3 albums…"
//     AssignThenPropose   "Proposing 2 albums…" (the propose after an assign)
//     Approve, Reject     "Approving 3 albums…", "Rejecting 3 albums…"
//     ExecuteDryRun       "Checking placement of 3 albums…"
//     Execute             "Placing 40 albums…", then "Placing 12/40: Artist – Album"
//                         (12 placed, that album placing now) or "Placing 12/40"
//     Resume              "Resuming placement of 5 albums…", then "Resuming placement 2/5"
//     Gc                  "Deleting local copies of 3 albums…"
//     DeleteCensus        "Counting playlist rows for 3 albums…"
//     Swap                "Swapping 12 playlist rows…" (a count of rows, never a label)
//  The n/m form shows once progress() reported something (done > 0 or an
//  album being worked on) on an entry of more than one; until then, and for
//  one album, the plain form. Execute and Resume carry done/total from the
//  start (0/40: the host may draw an empty bar).
//  Results: "Proposed 3 albums", "Assigned 3 albums", "Assigned and proposed
//  2 albums", "Approved …", "Rejected …", "Checked placement of …", "Placed
//  …", "Resumed placement of …", "Deleted local copies of …", "Counted
//  playlist rows for …", "Swapped 12 playlist rows" (state succeeded, icon
//  check); failed: "<Propose|Assign|Approve|Reject> failed: <reason>",
//  "Placement check failed: …", "Execute failed: …", "Resume failed: …",
//  "Delete failed: …", "Row count failed: …", "Swap failed: …" (state
//  failed, icon cross). Results carry no done/total.
//  Labels are cut to kActivityLabelMaxBytes and reasons to
//  kActivityReasonMaxBytes on a UTF-8 boundary (never inside a character,
//  and never between a letter and a combining accent U+0300–U+036F that
//  follows it), with "…"; newlines, tabs and other control characters
//  become spaces.
//
//  The list (items(now)): running entries first, most recently begun first,
//  then the results still shown, newest first. Title and detail:
//   - running: the line text (an n/m entry: "Placing 12/40", detail the
//     album placing now); detail "<first album> and N more" for more than
//     one album, empty for one (its label is in the title);
//   - succeeded: the result text, the same album detail;
//   - failed: "<X> failed: <reason>", detail the end()'s detail (the console
//     line), else the album detail.
//  started/ended are the `now` of begin() and end().
//
//  activityResultFor turns a finished call's MutationOutcome
//  (IntakeMutationResult, IntakeExecuteTracker summarizeRun) into a result:
//  succeeded when no root failed and the outcome is not an error; else a
//  reason: the first root's error text without its "<command>: " prefix
//  when no root succeeded, "<k> of <n> albums" when some did; the console
//  line is the detail.
//
//  Thread-safety: none (main thread only).
//

#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "IntakeCommandArgs.h"
#include "IntakeMutationResult.h"

namespace intake {

enum class ActivityKind {
    Propose,
    Assign,
    AssignThenPropose,  // the propose after an assign (rename() from Assign)
    Approve,
    Reject,
    ExecuteDryRun,
    Execute,
    Resume,
    Gc,
    DeleteCensus,
    Swap,
};

enum class ActivityState {
    Running,
    Succeeded,
    Failed,
};

enum class ActivityIcon {
    None,
    Check,
    Cross,
};

// How long a result stays.
inline constexpr int64_t kActivityResultMs = 10000;
// The longest album label and failure reason in a text, in UTF-8 bytes.
inline constexpr size_t kActivityLabelMaxBytes = 60;
inline constexpr size_t kActivityReasonMaxBytes = 120;

struct ActivityLine {
    std::string text;
    uint32_t done = 0;  // 0/0: no progress
    uint32_t total = 0;
    ActivityIcon icon = ActivityIcon::None;
    ActivityState state = ActivityState::Running;
};

struct ActivityItem {
    uint64_t id = 0;
    std::string title;
    std::string detail;
    ActivityState state = ActivityState::Running;
    uint32_t done = 0;  // 0/0: no progress
    uint32_t total = 0;
    int64_t startedMs = 0;
    int64_t endedMs = 0;  // 0 while running
};

// How a finished operation ended.
struct ActivityResult {
    bool succeeded = true;
    std::string reason;  // failed: short, for the line
    std::string detail;  // failed: longer, for the list (optional)
};

// The keys (see the top of this file).
std::string activityLaneKey(uint64_t token);
std::string activityRunKey(const std::string &stem);
std::string activitySwapKey(uint64_t serial);
std::string activityCensusKey(uint64_t serial);

// The kind of a mutating CLI command (a dry run of execute: ExecuteDryRun).
// False for the read-only commands (version, status, collections, income).
bool activityKindFor(CliCommand command, bool dryRun, ActivityKind &out);

// `text` on one line (control characters become spaces), cut to at most
// `maxBytes` bytes with "…" when it is longer (see the top of this file).
std::string activityShorten(const std::string &text, size_t maxBytes);

// A finished call's result (see the top of this file). `named`: the roots
// the call named; `commandName`: the prefix of its texts ("propose",
// "execute dry run").
ActivityResult activityResultFor(const MutationOutcome &outcome, size_t named, const std::string &commandName);

class ActivityModel {
public:
    // A running entry under `key`; `count` albums (Swap: rows), the first
    // one's label (may be empty). Returns its id.
    uint64_t begin(const std::string &key, ActivityKind kind, size_t count, const std::string &firstLabel, int64_t now);

    // The running entry's progress: `done` of `total`, `currentLabel` the
    // album worked on now (may be empty). True when it changed.
    bool progress(const std::string &key, uint32_t done, uint32_t total, const std::string &currentLabel);

    // The running entry's kind, count and first label; its progress is
    // reset (an Execute or Resume kind starts at 0/count). True when found.
    bool rename(const std::string &key, ActivityKind kind, size_t count, const std::string &firstLabel);

    // The running entry becomes a result at `now`; `count` (optional)
    // replaces its count for the result text (Swap: the rows swapped). True
    // when found.
    bool end(const std::string &key, const ActivityResult &result, int64_t now,
             std::optional<size_t> count = std::nullopt);

    // Drops every entry (quit). True when there was one.
    bool clear();

    // Drops the results no longer shown at `now`. True when one went.
    bool prune(int64_t now);

    std::optional<ActivityLine> line(int64_t now) const;
    std::vector<ActivityItem> items(int64_t now) const;
    // The earliest time after `now` at which a shown result goes.
    std::optional<int64_t> nextExpiry(int64_t now) const;

    bool isRunning(const std::string &key) const;
    size_t runningCount() const;
    size_t size() const { return entries_.size(); }

private:
    struct Entry {
        uint64_t id = 0;
        std::string key;
        ActivityKind kind = ActivityKind::Propose;
        size_t count = 0;
        std::string label;    // the first album, shortened
        uint32_t done = 0;
        uint32_t total = 0;
        std::string current;  // the album worked on now, shortened
        ActivityState state = ActivityState::Running;
        std::string reason;   // failed, shortened
        std::string detail;   // failed, one line
        int64_t startedMs = 0;
        int64_t endedMs = 0;
        uint64_t endSeq = 0;  // order of the ends
    };

    Entry *findRunning(const std::string &key);
    const Entry *findRunning(const std::string &key) const;
    static bool shown(const Entry &e, int64_t now);
    static std::string lineText(const Entry &e);
    static ActivityItem itemFor(const Entry &e);

    std::vector<Entry> entries_;
    uint64_t nextId_ = 1;
    uint64_t nextEndSeq_ = 1;
};

} // namespace intake
