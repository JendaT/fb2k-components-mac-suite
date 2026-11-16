//
//  IntakeRootErrors.h
//  foo_jl_intake
//
//  Per-root command errors (doc 04 v1.2 "Failure behavior": a console line
//  plus a per-root tooltip, never modal, never inert; PLAN.md B6). A
//  mutating command that fails for a root sets that root's error here
//  (IntakeMutationResult decides which root an error belongs to); the
//  loader copies it into IntakeRecord::lastError before each snapshot is
//  built (LoaderSettings::annotateRecords), so it shows in the row tooltip
//  (IntakeDecorationMap) and its arrival or removal invalidates like any
//  visual change (rendersAlike).
//
//  Lifecycle: "until that root's status changes", measured from the
//  status the menu showed when the action was chosen (the baseline,
//  MutationRoot::status): any load that finds another status drops the
//  error, the first load after the call included. So a root the CLI had
//  already changed when the call failed as a whole (an uncaught throw
//  after earlier roots were written, a crash, the 15-minute cap), or one
//  that had moved on before a stale menu ran (E_BAD_STATUS from a second
//  click before the refresh landed), shows no tooltip about a state it is
//  no longer in; the call's console line still reports it. An error set
//  without a baseline (Unknown) takes the status of the first load that
//  shows it. A newer error for the root replaces the old one and starts
//  over; a command that succeeds for the root clears it. A root missing
//  from a successful load is dropped too (the store stays bounded by the
//  roots that exist).
//
//  Loads already running: apply() takes the time the load's `status` call
//  started. An error set at or after that time may be newer than what the
//  call read (a run that ended while an FSEvents reload was in flight), so
//  that load shows it but neither takes its baseline nor drops it; the next
//  load (serviceRefreshAfterCommand queues one) decides. apply(records)
//  alone treats every load as started after every error.
//
//  Thread-safety: every method may be called from any thread (set/clear on
//  the main thread, apply on the loader queue); one mutex, held only while
//  copying strings.
//

#pragma once

#include <chrono>
#include <cstddef>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "IntakeStatusModel.h"

namespace intake {

class RootErrorStore {
public:
    using Clock = std::chrono::steady_clock;

    // A new error for `id` (an empty text clears instead), kept while the
    // root stays in `baseline` (see above; Unknown: the first load's). `at`
    // is when it was set (tests pass their own).
    void set(const std::string &id, std::string text, IntakeStatus baseline = IntakeStatus::Unknown,
             Clock::time_point at = Clock::now());
    void clear(const std::string &id);
    void clearAll();

    // The loader's annotator: every record gets its root's error in
    // lastError (or an empty one), and errors whose root changed status
    // since they were first shown, or is missing, are dropped (see above),
    // unless they were set at or after `statusStarted`.
    void apply(std::vector<IntakeRecord> &records, Clock::time_point statusStarted);
    void apply(std::vector<IntakeRecord> &records) { apply(records, Clock::time_point::max()); }

    // For tests and logs.
    size_t size() const;
    std::string errorFor(const std::string &id) const;

private:
    struct Entry {
        std::string text;
        bool hasBaseline = false;
        IntakeStatus baseline = IntakeStatus::Unknown;
        Clock::time_point setAt;
    };
    mutable std::mutex mutex_;
    std::unordered_map<std::string, Entry> entries_;
};

} // namespace intake
