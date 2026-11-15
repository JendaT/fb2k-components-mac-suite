//
//  IntakeGroupBadge.mm
//  foo_jl_intake
//

#include "IntakeGroupBadge.h"

#include "IntakeReviewRule.h"
#include "IntakeStatusModel.h"

#include <cmath>

namespace intake {

namespace {

const char *const kArrow = "\xE2\x86\x92";    // U+2192
const char *const kSep = " \xC2\xB7 ";        // " U+00B7 "

std::string bracketed(const std::string &collection) {
    return "[" + collection + "]";
}

// The first ranked entry that is not the target, or nullptr.
const RankedCandidate *firstAlternate(const IntakeProposal &p) {
    if (p.rankedState != RankedState::Present) return nullptr;
    for (const RankedCandidate &c : p.ranked) {
        if (!c.collection.empty() && c.collection != p.targetCollection) return &c;
    }
    return nullptr;
}

} // anonymous namespace

std::string formatConfidence(double confidence) {
    if (!std::isfinite(confidence)) return "?";
    if (confidence < 0) confidence = 0;
    if (confidence > 1) confidence = 1;
    const long hundredths = std::lround(confidence * 100.0);
    const long whole = hundredths / 100;
    const long frac = hundredths % 100;
    std::string out = std::to_string(whole) + ".";
    if (frac < 10) out += "0";
    out += std::to_string(frac);
    return out;
}

IntakeBadge recordBadge(const IntakeRecord &record, const IntakePalette &palette) {
    IntakeBadge badge;
    if (record.status != IntakeStatus::Proposed && record.status != IntakeStatus::Approved) return badge;
    if (!record.hasProposal) return badge;
    const IntakeProposal &p = record.proposal;
    if (p.targetCollection.empty()) return badge;

    std::string text = std::string(kArrow) + " " + bracketed(p.targetCollection);
    if (p.targetPathState == TargetPathState::Null) {
        text += kSep;
        text += "slot pending";
        badge.amber = true;
    } else {
        if (p.assignedBy == AssignedBy::User) {
            text += kSep;
            text += "yours";
        } else if (p.hasConfidence) {
            text += kSep;
            text += formatConfidence(p.confidence);
        }
        const bool lowConfidence = p.hasConfidence && p.confidence < kBadgeAmberConfidence;
        badge.amber = recordNeedsReview(record) || lowConfidence;
        if (badge.amber) {
            if (const RankedCandidate *alt = firstAlternate(p)) text += " (alt: " + bracketed(alt->collection) + ")";
        }
    }
    badge.text = std::move(text);
    badge.color = badge.amber ? opaqueColor(palette.tintReview) : 0;
    return badge;
}

const IntakeRecord *groupRoot(const std::vector<const IntakeRecord *> &memberRecords) {
    const IntakeRecord *root = nullptr;
    for (const IntakeRecord *r : memberRecords) {
        if (r == nullptr) continue;
        if (root == nullptr) {
            root = r;
        } else if (r != root && r->id != root->id) {
            return nullptr;
        }
    }
    return root;
}

const IntakeBadge *groupBadge(const std::vector<const IntakeRecord *> &memberRecords) {
    const IntakeRecord *root = groupRoot(memberRecords);
    if (root == nullptr || !root->badge.shown()) return nullptr;
    return &root->badge;
}

} // namespace intake
