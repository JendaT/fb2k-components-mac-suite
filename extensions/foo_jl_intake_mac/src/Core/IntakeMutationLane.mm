//
//  IntakeMutationLane.mm
//  foo_jl_intake
//

#include "IntakeMutationLane.h"

namespace intake {

const char *laneHolderName(LaneHolder holder) {
    switch (holder) {
        case LaneHolder::None: return "none";
        case LaneHolder::Mutating: return "mutating";
        case LaneHolder::DryRun: return "dry run";
        case LaneHolder::Execute: return "execute";
    }
    return "unknown";
}

LaneHolder laneHolderFor(const CliRequest &request) {
    if (!isMutatingCommand(request.command)) return LaneHolder::None;
    if (request.dryRun) return LaneHolder::DryRun;
    if (request.command == CliCommand::Execute || request.command == CliCommand::Resume) return LaneHolder::Execute;
    return LaneHolder::Mutating;
}

uint64_t MutationLane::acquire(LaneHolder kind) {
    if (kind == LaneHolder::None || busy()) return 0;
    holder_ = kind;
    current_ = next_++;
    return current_;
}

bool MutationLane::reportBudget(uint64_t token) {
    if (token == 0 || token != current_ || holder_ != LaneHolder::DryRun) return false;
    released_.insert(token);
    holder_ = LaneHolder::None;
    current_ = 0;
    return true;
}

bool MutationLane::finish(uint64_t token) {
    if (token == 0) return false;
    if (released_.erase(token)) return false;  // released at its report: the late result is discarded
    if (token != current_) return false;
    holder_ = LaneHolder::None;
    current_ = 0;
    return true;
}

} // namespace intake
