//
//  IntakeMutationLane.h
//  foo_jl_intake
//
//  The mutation lane as a pure state machine (doc 04 v1.2 "CLI invocation",
//  "Mutation lane"; PLAN.md 3.2 lane rule, risk 7). The CLI has no locking,
//  so the component runs at most one mutating call at a time (Terminal runs
//  are not protected by this):
//
//   - A real mutating call (propose, assign, approve, reject, gc) holds the
//     lane until it exits; the runner terminates it at the 15-minute cap,
//     and that exit releases the lane too.
//   - A dry run (any command's --dry-run, execute's included) holds it until
//     it exits or until its 10 s report, whichever comes first. A dry run
//     writes nothing, so after the report the lane is released, the late
//     result is discarded (finish() says so) and the process runs on,
//     unkilled.
//   - execute and resume (detached) hold it until they exit, and are
//     reported as "execute running" so menus can say why they are disabled.
//   - B12's background scan (`scan <income>`, class Mutating) holds it like
//     a real mutating call, and is reported as "scan running".
//  Mutating menu items are disabled while the lane is busy.
//
//  Each acquire returns a token; budget reports and exits name it, so an
//  old dry run that ends after the lane moved on never releases a newer
//  holder.
//
//  Thread-safety: none; Integration uses it on the main thread only.
//

#pragma once

#include <cstdint>
#include <unordered_set>

#include "IntakeCommandArgs.h"

namespace intake {

enum class LaneHolder {
    None,
    Mutating, // a real propose, assign, approve, reject or gc
    DryRun,   // any --dry-run (released at its 10 s report)
    Execute,  // execute or resume (detached)
    Scan,     // B12's background scan
};

// The holder kind a request takes: DryRun for any dry run, Execute for a
// real execute or resume, Scan for scan, Mutating for the other mutating
// commands, None for read-only commands (they never take the lane).
LaneHolder laneHolderFor(const CliRequest &request);

class MutationLane {
public:
    bool busy() const { return holder_ != LaneHolder::None; }
    LaneHolder holder() const { return holder_; }
    bool executeRunning() const { return holder_ == LaneHolder::Execute; }
    bool scanRunning() const { return holder_ == LaneHolder::Scan; }

    // Takes the lane for a call of `kind`; 0 when it is busy (or kind is
    // None).
    uint64_t acquire(LaneHolder kind);

    // The call's 10 s report. A dry run that still holds the lane lets go
    // of it (true); every other holder keeps it (false).
    bool reportBudget(uint64_t token);

    // The call exited (or never started). True when its result applies;
    // false for a dry run released at its report, or a token this lane
    // does not know. Releases the lane when `token` holds it.
    bool finish(uint64_t token);

    // Dry runs released at their report whose process has not exited yet.
    size_t releasedRunning() const { return released_.size(); }

    // How many times the lane was taken (every acquire that returned a
    // token; a refused one does not count). B12: the chunked propose
    // compares two reads to tell whether some call took the lane in
    // between.
    uint64_t acquisitions() const { return next_ - 1; }

private:
    LaneHolder holder_ = LaneHolder::None;
    uint64_t current_ = 0;
    uint64_t next_ = 1;
    std::unordered_set<uint64_t> released_;
};

} // namespace intake
