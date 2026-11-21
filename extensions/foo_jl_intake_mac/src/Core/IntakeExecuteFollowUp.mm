//
//  IntakeExecuteFollowUp.mm
//  foo_jl_intake
//

#include "IntakeExecuteFollowUp.h"

#include "IntakeGcPlan.h"

#include <unordered_set>

namespace intake {

FollowUpCheckboxes followUpCheckboxes(bool swapTicked, bool deleteWanted) {
    FollowUpCheckboxes out;
    out.swapOn = swapTicked;
    out.deleteEnabled = swapTicked;
    out.deleteOn = swapTicked && deleteWanted;
    return out;
}

RunFollowUps chosenFollowUps(bool swapTicked, bool deleteTicked) {
    RunFollowUps out;
    out.recorded = true;
    out.swap = swapTicked;
    out.deleteLocal = swapTicked && deleteTicked;
    return out;
}

bool hasFollowUps(const RunFollowUps &followUps) {
    return followUps.recorded && followUps.swap;
}

FollowUpSwapPlan planFollowUpSwap(const std::vector<std::string> &runIds, const FollowUpRecordLookup &lookup) {
    FollowUpSwapPlan out;
    std::unordered_set<std::string> seen;
    for (const std::string &id : runIds) {
        if (id.empty() || !seen.insert(id).second) continue;
        const IntakeRecord *now = lookup ? lookup(id) : nullptr;
        if (now == nullptr) {
            out.notSwapped.emplace_back(id, "no longer listed by intake status");
        } else if (now->status != IntakeStatus::Placed) {
            out.notSwapped.emplace_back(id, std::string("now ") + intakeStatusName(now->status) + ", not placed");
        } else if (!now->hasPlaced || !now->placedVerified) {
            out.notSwapped.emplace_back(id, "placed.verified is not true");
        } else {
            out.swap.push_back(id);
        }
    }
    return out;
}

namespace {

std::string rowCount(size_t n) {
    return std::to_string(n) + (n == 1 ? " playlist row" : " playlist rows");
}

} // anonymous namespace

FollowUpGcPlan planFollowUpGc(const std::vector<std::string> &swapped, const FollowUpRecordLookup &lookup,
                              const std::unordered_map<std::string, size_t> &incomeEntries, size_t unchecked,
                              const std::string &refusal) {
    FollowUpGcPlan out;
    std::unordered_set<std::string> seen;
    for (const std::string &id : swapped) {
        if (id.empty() || !seen.insert(id).second) continue;
        const IntakeRecord *now = lookup ? lookup(id) : nullptr;
        FollowUpSkip skip;
        skip.id = id;
        skip.baseline = now != nullptr ? now->status : IntakeStatus::Unknown;
        if (!refusal.empty()) {
            skip.why = refusal;
            out.skipped.push_back(std::move(skip));
            continue;
        }
        // The gc guard against the records now: still listed, placed,
        // placed.verified (recheckGcRoots), a non-empty id (gcEligibleRoots).
        ActionRoot root;
        if (now != nullptr) {
            root = actionRootFor(*now);
        } else {
            root.id = id;
        }
        const GcRecheck recheck = recheckGcRoots({root}, [now](const std::string &) { return now; });
        if (!recheck.dropped.empty()) {
            skip.why = recheck.dropped.front().second;
            out.skipped.push_back(std::move(skip));
            continue;
        }
        const std::vector<ActionRoot> eligible = gcEligibleRoots(recheck.keep);
        if (eligible.empty()) {
            skip.why = "not placed with placed.verified";
            out.skipped.push_back(std::move(skip));
            continue;
        }
        if (unchecked > 0) {
            skip.why = rowCount(unchecked) + " on a slow volume could not be checked";
            out.skipped.push_back(std::move(skip));
            continue;
        }
        auto left = incomeEntries.find(id);
        if (left != incomeEntries.end() && left->second > 0) {
            skip.why = rowCount(left->second) + (left->second == 1 ? " still points" : " still point") +
                       " at its income paths after the swap";
            out.skipped.push_back(std::move(skip));
            continue;
        }
        out.gc.push_back(eligible.front());
    }
    return out;
}

std::string followUpSkipLine(const std::string &stem, const FollowUpSkip &skip) {
    return "delete-local: " + skip.id + ": local copy kept after run " + stem + ": " + skip.why;
}

std::string followUpSkipTooltip(const FollowUpSkip &skip) {
    return "delete-local: local copy kept: " + skip.why;
}

std::string earlierRunFollowUpLine(const std::string &stem, const RunFollowUps &followUps) {
    return "run " + stem + ": swap/delete as chosen at its start (" +
           (followUps.deleteLocal ? "swap, then delete" : "swap only") + ")";
}

} // namespace intake
