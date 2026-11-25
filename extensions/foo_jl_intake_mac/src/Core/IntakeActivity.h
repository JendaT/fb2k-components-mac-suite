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
//     mutation lane token (an assign and the propose after it share one;
//     B12's background scan and the propose after it too);
//   - activityRunKey(stem): an execute or resume run, by its run stem;
//   - activitySwapKey(serial): one swap of playlist rows;
//   - activityCensusKey(serial): the Delete flow's sidecar reads;
//   - activityChainKey(serial): B12's chunked propose (IntakeProposeChain),
//     one entry for the whole chain, whose chunks each hold their own lane
//     token.
//  progress() sets done/total and the album being worked on (the chained
//  propose: the roots handled, and the first album of the chunk running);
//  rename() changes the kind and the count (the propose after an assign or
//  a scan; the chained propose when roots join it);
//  end() makes the entry a result, succeeded or failed with a short reason
//  (a result may name another kind for its text: the assign or scan that
//  failed before the propose after it); deadline() sets the time and the
//  result at which the entry ends unless something ended it before (the
//  execute dry run, which the runner never kills: its answer may never
//  come); clear() (quit) drops everything. All of them work on the RUNNING
//  entry of a key:
//  a key with no running entry (never begun, already ended, cleared) is
//  ignored and they return false, so a double end, or an end after quit, is
//  harmless. begin() on a key that still has a running entry drops that
//  entry first (it never ended: a hook bug, not a state to show twice).
//
//  Time. Every query takes `now` in milliseconds (Unix epoch in production,
//  any clock in tests). A result is shown while ended <= now < ended + 10 s
//  (kActivityResultMs), then it is gone; a result whose end lies after `now`
//  (the wall clock went back) is gone too, so nothing lingers. A running
//  entry with a deadline stays running until prune() at or after the
//  deadline ends it with its deadline result (ended = the deadline, so it
//  shows for the 10 s after the deadline, or not at all when prune() comes
//  later than that); an end() after the deadline finds it ended (its own
//  prune() runs first) and is ignored like any double end. nextExpiry() is
//  the earliest time at which a shown result goes or a deadline falls, for
//  the provider's timer (a deadline already past: a time at or before
//  `now`, prune at once); prune() ends the entries past their deadline and
//  drops the results gone.
//
//  The line (line(now)):
//   - something running: the most recently begun running entry, plus
//     " (+N more)" when N others run;
//   - nothing running: the newest result still inside its 10 s;
//   - else none (idle shows no line at all).
//  Running texts (UTF-8, "…" U+2026; one album: its label instead of the
//  count; the label is "Artist – Album" from IntakeActionTable albumLabel):
//     Propose             "Proposing 3 albums…"            "Proposing Album…"
//                         (B12's chained propose: "Proposing 49 albums…", then
//                         "Proposing 10/49: Artist – Album" once a chunk ended)
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
//     Scan                "Scanning income local…" (B12: the label is the income's
//                         name, never a count)
//     ScanThenPropose     "Proposing 2 albums…" (the propose after a scan; the label
//                         stays the income's name, so always the count)
//  The n/m form shows once progress() reported something (done > 0 or an
//  album being worked on) on an entry of more than one; until then, and for
//  one album, the plain form. Execute and Resume carry done/total from the
//  start (0/40: the host may draw an empty bar).
//  Results: "Proposed 3 albums", "Assigned 3 albums", "Assigned and proposed
//  2 albums", "Approved …", "Rejected …", "Checked placement of …", "Placed
//  …", "Resumed placement of …", "Deleted local copies of …", "Counted
//  playlist rows for …", "Swapped 12 playlist rows", "Scanned local" or
//  "Scanned local: 3 new albums" (the count is end()'s: the roots the scan
//  newly wrote, 0 when none or unknown), "Scanned local, proposed 2 albums"
//  (state succeeded, icon check);
//  failed: "<Propose|Assign|Approve|Reject> failed: <reason>", "Placement
//  check failed: …", "Execute failed: …", "Resume failed: …", "Delete
//  failed: …", "Row count failed: …", "Swap failed: …", "Scan failed: …"
//  (state failed, icon cross); the propose after a scan fails as "Propose
//  failed: …". Results carry no done/total. A scan's list item, and that of
//  the propose after it, has no album detail (its label is an income, not
//  an album).
//  Labels are cut to kActivityLabelMaxBytes and reasons to
//  kActivityReasonMaxBytes with "…", never inside a character and never
//  inside a composed character sequence (CoreFoundation's
//  CFStringGetRangeOfComposedCharactersAtIndex): a letter keeps every
//  combining mark that follows it (U+0300–U+036F, the kana voicing marks
//  U+3099/U+309A, U+1DC0–U+1DFF, U+20D0–U+20FF, U+FE20–U+FE2F, ...), and
//  decomposed Hangul keeps its jamo together, as in the NFD folder names
//  of an SMB share. Text that is not valid UTF-8 is cut on a UTF-8 boundary
//  only. Newlines, tabs and other control characters become spaces.
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
//  activityAfterAssign ends the one entry of an assign and the propose after
//  it: an assign that failed for some roots or all ends it failed as the
//  assign ("Assign failed: 1 of 3 albums", kind Assign), whatever the
//  propose did (its failure, if any, follows in the detail); otherwise the
//  propose's own result ("Assigned and proposed 2 albums", "Propose failed:
//  …"). So a partial failure never shows the check icon.
//
//  activityAfterScan does the same for B12's auto-scan and the propose after
//  it (PLAN-B12 scope addition 1): a scan that ended with errors (exit 1)
//  ends the entry failed as the scan ("Scan failed: E_ARCHIVE: …", kind
//  Scan), the propose's failure in the detail; otherwise the propose's own
//  result ("Scanned local, proposed 2 albums", "Propose failed: …"), with
//  the kind the propose's result names, if any (a propose that could not
//  start before the rename: kind Propose).
//
//  activityReadsResult ends the Delete flow's census (its sidecar reads):
//  succeeded when every root's file list was read; else failed with the
//  first error when none was, "<k> of <n> albums" when some were, the
//  detail "no file list for <k> of <n> albums: <first error>". A share that
//  fails at once and one that hangs (the 10 s timeout, "no answer within
//  10 s") both end failed.
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
    Scan,  // B12's background scan of one income folder (the label: its name)
    ScanThenPropose,  // the propose after a scan (rename() from Scan; the label stays the income)
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
    // The kind whose words the result uses, when not the entry's own (the
    // assign that failed before its propose: activityAfterAssign).
    std::optional<ActivityKind> kind;
};

// The keys (see the top of this file).
std::string activityLaneKey(uint64_t token);
std::string activityRunKey(const std::string &stem);
std::string activitySwapKey(uint64_t serial);
std::string activityCensusKey(uint64_t serial);
std::string activityChainKey(uint64_t serial);

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

// The end of an assign and the propose after it (see the top of this
// file): `assign` the assign's result, `propose` the propose's (or its
// refusal's).
ActivityResult activityAfterAssign(const ActivityResult &assign, const ActivityResult &propose);

// The end of B12's auto-scan and the propose after it (see the top of this
// file): `scan` the scan's result, `propose` the propose's (or its
// refusal's).
ActivityResult activityAfterScan(const ActivityResult &scan, const ActivityResult &propose);

// The end of reading `named` roots' file lists; `unread` holds the error of
// each root that has none, in order (see the top of this file).
ActivityResult activityReadsResult(size_t named, const std::vector<std::string> &unread);

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
    // when found (an entry past its deadline is not: prune() runs first).
    bool end(const std::string &key, const ActivityResult &result, int64_t now,
             std::optional<size_t> count = std::nullopt);

    // The running entry ends with `result` at `at` unless it ends before
    // (applied by prune()); a later call replaces the deadline. True when
    // found.
    bool deadline(const std::string &key, int64_t at, const ActivityResult &result);

    // Drops every entry (quit). True when there was one.
    bool clear();

    // Ends the running entries whose deadline is at or before `now`, then
    // drops the results no longer shown at `now`. True when either changed
    // something.
    bool prune(int64_t now);

    std::optional<ActivityLine> line(int64_t now) const;
    std::vector<ActivityItem> items(int64_t now) const;
    // The earliest time at which a shown result goes or a running entry's
    // deadline falls (at or before `now` when a deadline is already past).
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
        std::optional<int64_t> deadlineMs;  // running: ends then with atDeadline
        ActivityResult atDeadline;
    };

    Entry *findRunning(const std::string &key);
    const Entry *findRunning(const std::string &key) const;
    void finish(Entry &e, const ActivityResult &result, int64_t at, std::optional<size_t> count);
    static bool shown(const Entry &e, int64_t now);
    static std::string lineText(const Entry &e);
    static ActivityItem itemFor(const Entry &e);

    std::vector<Entry> entries_;
    uint64_t nextId_ = 1;
    uint64_t nextEndSeq_ = 1;
};

} // namespace intake
