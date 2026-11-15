//
//  IntakeDecorationMap.mm
//  foo_jl_intake
//

#include "IntakeDecorationMap.h"

#include "IntakeReviewRule.h"
#include "IntakeStatusModel.h"

namespace intake {

const char *const kTooltipNeedsReview = "needs review";
const char *const kTooltipPlacing = "placing \xE2\x80\x94 see intake status";  // U+2014 em dash
const char *const kTooltipSlotPending = "slot pending";

namespace {

void appendTooltip(std::string &tooltip, const std::string &part) {
    if (part.empty()) return;
    if (!tooltip.empty()) tooltip += " \xC2\xB7 ";  // a middle dot (U+00B7) between spaces
    tooltip += part;
}

bool slotPending(const IntakeRecord &record) {
    return record.hasProposal && record.proposal.targetPathState == TargetPathState::Null;
}

} // anonymous namespace

bool statusHasVisual(const IntakeRecord &record) {
    switch (record.status) {
        case IntakeStatus::New:
        case IntakeStatus::Resolved:
        case IntakeStatus::Proposed:
        case IntakeStatus::Approved:
        case IntakeStatus::Placing:
        case IntakeStatus::Rejected:
            return true;
        case IntakeStatus::Placed:
            return record.placedVerified;
        case IntakeStatus::GcDone:
        case IntakeStatus::Unknown:
            return false;
    }
    return false;
}

IntakeRowVisual rowVisualFor(const IntakeRecord &record, const IntakePalette &palette) {
    IntakeRowVisual v;
    const bool review = recordNeedsReview(record);
    bool canBeSlotPending = false;

    switch (record.status) {
        case IntakeStatus::New:
            v.bgTint = palette.tintNew;
            v.icon = IntakeIcon::CircleOpen;
            // CR-004.8: needs_review on new is a tooltip, never amber.
            if (record.needsReview) appendTooltip(v.tooltip, kTooltipNeedsReview);
            break;
        case IntakeStatus::Resolved:
            if (review) {
                v.bgTint = palette.tintReview;
                v.icon = IntakeIcon::Warning;
                v.iconColor = opaqueColor(palette.tintReview);
            } else {
                v.bgTint = palette.tintNew;
                v.icon = IntakeIcon::CircleOpen;
            }
            canBeSlotPending = true;
            break;
        case IntakeStatus::Proposed:
            v.icon = IntakeIcon::CircleLeftHalf;
            if (review) {
                v.bgTint = palette.tintReview;
                v.iconColor = opaqueColor(palette.tintReview);
            } else {
                v.bgTint = palette.tintProposed;
            }
            canBeSlotPending = true;
            break;
        case IntakeStatus::Approved:
            v.bgTint = palette.tintApproved;
            v.icon = IntakeIcon::CircleRightHalf;
            canBeSlotPending = true;
            break;
        case IntakeStatus::Placing:
            v.bgTint = palette.tintApproved;
            v.icon = IntakeIcon::ArrowRight;
            appendTooltip(v.tooltip, kTooltipPlacing);
            break;
        case IntakeStatus::Placed:
            if (record.placedVerified) {
                v.bgTint = palette.tintPlaced;
                v.icon = IntakeIcon::CircleFilled;
                v.iconColor = opaqueColor(palette.tintPlaced);
            }
            break;
        case IntakeStatus::Rejected:
            v.bgTint = palette.tintRejected;
            v.icon = IntakeIcon::Cross;
            v.strikethrough = true;
            break;
        case IntakeStatus::GcDone:
        case IntakeStatus::Unknown:
            break;
    }

    if (canBeSlotPending && slotPending(record)) appendTooltip(v.tooltip, kTooltipSlotPending);
    appendTooltip(v.tooltip, record.lastError);
    return v;
}

} // namespace intake
