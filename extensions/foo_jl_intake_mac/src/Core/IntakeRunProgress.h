//
//  IntakeRunProgress.h
//  foo_jl_intake
//
//  The n/m of an execute or resume run for the status bar (PLAN-B14 "Execute
//  n/m"), from the statuses its roots show in each published view. Pure: the
//  caller hands in a lookup over the view's records (IntakeActivityHub).
//
//  What the CLI writes (tools/intake/src/commands-p3.ts, cmdExecute and
//  resumeRoot), one root after the other in the order named:
//   - execute: the sidecar goes `placing` before anything is copied, then
//     `placed` after the copy is verified and renamed into the library;
//   - a failure before the commit point reverts it to `approved`
//     (execute_failed); one after it leaves it `placing` (stuck: bookkeeping
//     failed, `--resume` finishes it) and the run goes on with the next root;
//   - resume writes no `placing`: each root goes from `placing` straight to
//     `placed`, or back to `approved` (execute_reverted).
//
//  So, at each view:
//   - done = the run's roots now `placed`;
//   - current (execute only) = the root that became `placing` since the last
//     view (the last such in the run's order: an earlier one still placing is
//     stuck); none became placing: the previous current while it is still
//     `placing`, else none (placed, reverted, or not seen yet). Resume never
//     has a current.
//  A root the view does not list keeps the status last seen. start() seeds
//  the statuses from the view at the run's start (an adopted run may be half
//  done: its placed roots count, and its last placing root is current).
//  Without file events from the share the statuses never change and the run
//  shows 0/total until its result.
//
//  Thread-safety: none (main thread, IntakeActivityHub).
//

#pragma once

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

#include "IntakeStatusModel.h"

namespace intake {

// The status of root `id` in the view; false when the view does not list it.
using RunStatusLookup = std::function<bool(const std::string &id, IntakeStatus &status)>;

class RunProgress {
public:
    // The run's roots (repeats dropped), resume or execute, seeded from
    // `lookup`.
    void start(const std::vector<std::string> &ids, bool resume, const RunStatusLookup &lookup);

    // A published view. True when done or current changed.
    bool update(const RunStatusLookup &lookup);

    uint32_t done() const { return done_; }
    uint32_t total() const { return static_cast<uint32_t>(ids_.size()); }
    // The root placing now, or "".
    const std::string &current() const { return current_; }

private:
    std::vector<std::string> ids_;
    std::vector<IntakeStatus> last_;  // aligned with ids_; Unknown until seen
    bool resume_ = false;
    uint32_t done_ = 0;
    std::string current_;
};

} // namespace intake
