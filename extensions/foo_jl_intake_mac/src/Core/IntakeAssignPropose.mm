//
//  IntakeAssignPropose.mm
//  foo_jl_intake
//

#include "IntakeAssignPropose.h"

#include <unordered_set>

namespace intake {

AssignFollowUp proposeAfterAssign(const std::vector<MutationRoot> &assigned, CliOutcome assignOutcome,
                                  const MutationOutcome &outcome, const std::vector<CliError> &errors) {
    AssignFollowUp out;
    if (assignOutcome != CliOutcome::Ok && assignOutcome != CliOutcome::Partial) return out;

    const std::unordered_set<std::string> succeeded(outcome.succeeded.begin(), outcome.succeeded.end());
    std::unordered_set<std::string> failed;
    for (const auto &entry : outcome.rootErrors) failed.insert(entry.first);
    for (const CliError &e : errors) {
        if (e.hasPath && !e.path.empty()) failed.insert(e.path);
    }

    std::unordered_set<std::string> seen;
    for (const MutationRoot &r : assigned) {
        if (!seen.insert(r.id).second) continue;
        if (!succeeded.count(r.id) || failed.count(r.id)) continue;
        if (r.status != IntakeStatus::Resolved) {
            out.skipped.push_back(r.id + " (" + intakeStatusName(r.status) + ")");
            continue;
        }
        out.propose.push_back(r.id);
        out.roots.push_back(r);
    }

    if (!out.skipped.empty()) {
        out.skippedLine = "assign: no propose for " + std::to_string(out.skipped.size()) +
                          (out.skipped.size() == 1 ? " root" : " roots") + " not resolved before the assign: ";
        for (size_t i = 0; i < out.skipped.size(); i++) {
            if (i) out.skippedLine += ", ";
            out.skippedLine += out.skipped[i];
        }
    }
    return out;
}

} // namespace intake
