//
//  IntakeDecorationMap.mm
//  foo_jl_intake
//

#include "IntakeDecorationMap.h"

#include "IntakeGroupBadge.h"
#include "IntakeReviewRule.h"
#include "IntakeStatusModel.h"
#include "IntakeTargetPath.h"

namespace intake {

const char *const kTooltipNeedsReview = "needs review";
const char *const kTooltipPlacing = "placing \xE2\x80\x94 see intake status";  // U+2014 em dash
const char *const kTooltipSlotPending = "slot pending";
const char *const kTooltipStatusPrefix = "Intake: ";
const char *const kTooltipTargetPrefix = "Target: ";
const char *const kTooltipNoTarget = "No target yet: Propose (or Assign to a collection first)";
const char *const kTooltipCannotBePlaced = "Target: none, cannot be placed (see intake status)";

namespace {

const char *const kDot = " \xC2\xB7 ";  // a middle dot (U+00B7) between spaces

void appendLine(std::string &tooltip, const std::string &line) {
    if (line.empty()) return;
    if (!tooltip.empty()) tooltip += '\n';
    tooltip += line;
}

// The flag as the table shows it: new, resolved and proposed carry
// needs_review; approve clears it, and a stray flag later is ignored.
bool showsNeedsReview(const IntakeRecord &record) {
    if (!record.needsReview) return false;
    return record.status == IntakeStatus::New || record.status == IntakeStatus::Resolved ||
           record.status == IntakeStatus::Proposed;
}

// Statuses whose null target_path reads "slot pending" (doc 04 v1.2).
bool canBeSlotPending(IntakeStatus status) {
    return status == IntakeStatus::New || status == IntakeStatus::Resolved || status == IntakeStatus::Proposed ||
           status == IntakeStatus::Approved;
}

std::string targetLine(const IntakeRecord &record) {
    if (!record.hasProposal) {
        return record.status == IntakeStatus::Resolved ? std::string(kTooltipNoTarget) : std::string();
    }
    const IntakeProposal &p = record.proposal;
    switch (p.targetPathState) {
        case TargetPathState::Set: {
            const std::string shown = displayTargetPath(p.targetPath, p.targetCollection);
            return shown.empty() ? std::string() : std::string(kTooltipTargetPrefix) + shown;
        }
        case TargetPathState::Null:
            if (!canBeSlotPending(record.status)) return std::string();
            // Only a singles root waits for a slot; any other null target
            // (tier reject, no album name, a tier not configured) is final.
            if (!record.singlesRoot) return std::string(kTooltipCannotBePlaced);
            if (p.targetCollection.empty()) return std::string(kTooltipTargetPrefix) + kTooltipSlotPending;
            return std::string(kTooltipTargetPrefix) + p.targetCollection + kDot + kTooltipSlotPending;
        case TargetPathState::Unknown:
            // CLI 0.2.1 sends no target_path: the collection is all there is.
            if (p.targetCollection.empty()) return std::string();
            return std::string(kTooltipTargetPrefix) + p.targetCollection;
    }
    return std::string();
}

std::string assignedLine(const IntakeRecord &record) {
    if (!record.hasProposal) return std::string();
    const IntakeProposal &p = record.proposal;
    const std::string confidence =
        p.hasConfidence ? " (confidence " + formatConfidence(p.confidence) + ")" : std::string();
    switch (p.assignedBy) {
        case AssignedBy::User:
            return "Assigned by you";
        case AssignedBy::Engine:
            return "Assigned by the engine" + confidence;
        case AssignedBy::Other:
            return "Assigned by " + p.assignedByText + confidence;
        case AssignedBy::Unknown:
            // CLI 0.2.1: who assigned is not said.
            return p.hasConfidence ? "Confidence " + formatConfidence(p.confidence) : std::string();
    }
    return std::string();
}

// The tooltip of a row whose status renders (statusHasVisual), one line
// each: status, placing note, target, who assigned, last error.
std::string tooltipFor(const IntakeRecord &record) {
    std::string tooltip;
    std::string status = std::string(kTooltipStatusPrefix) + intakeStatusLabel(record.status);
    if (showsNeedsReview(record)) status += std::string(kDot) + kTooltipNeedsReview;
    appendLine(tooltip, status);
    if (record.status == IntakeStatus::Placing) appendLine(tooltip, kTooltipPlacing);
    appendLine(tooltip, targetLine(record));
    appendLine(tooltip, assignedLine(record));
    appendLine(tooltip, record.lastError);
    return tooltip;
}

} // anonymous namespace

const char *intakeStatusLabel(IntakeStatus status) {
    switch (status) {
        case IntakeStatus::New: return "New";
        case IntakeStatus::Resolved: return "Resolved";
        case IntakeStatus::Proposed: return "Proposed";
        case IntakeStatus::Approved: return "Approved";
        case IntakeStatus::Placing: return "Placing";
        case IntakeStatus::Placed: return "Placed";
        case IntakeStatus::GcDone: return "Local copy deleted";
        case IntakeStatus::Rejected: return "Rejected";
        case IntakeStatus::Unknown: return "Unknown";
    }
    return "Unknown";
}

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

    switch (record.status) {
        case IntakeStatus::New:
            // CR-004.8: needs_review on new is a tooltip, never amber.
            v.bgTint = palette.tintNew;
            v.icon = IntakeIcon::CircleOpen;
            break;
        case IntakeStatus::Resolved:
            if (review) {
                v.bgTint = palette.tintReview;
                v.icon = IntakeIcon::Warning;
                v.iconColor = rowIconColor(palette.tintReview);
            } else {
                v.bgTint = palette.tintNew;
                v.icon = IntakeIcon::CircleOpen;
            }
            break;
        case IntakeStatus::Proposed:
            v.icon = IntakeIcon::CircleLeftHalf;
            if (review) {
                v.bgTint = palette.tintReview;
                v.iconColor = rowIconColor(palette.tintReview);
            } else {
                v.bgTint = palette.tintProposed;
            }
            break;
        case IntakeStatus::Approved:
            v.bgTint = palette.tintApproved;
            v.icon = IntakeIcon::CircleRightHalf;
            break;
        case IntakeStatus::Placing:
            v.bgTint = palette.tintApproved;
            v.icon = IntakeIcon::ArrowRight;
            break;
        case IntakeStatus::Placed:
            if (record.placedVerified) {
                v.bgTint = palette.tintPlaced;
                v.icon = IntakeIcon::CircleFilled;
                v.iconColor = rowIconColor(palette.tintPlaced);
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

    // A root whose status renders nothing keeps only its last error, as a
    // tooltip-only visual (no other row gains a tooltip).
    v.tooltip = statusHasVisual(record) ? tooltipFor(record) : record.lastError;
    return v;
}

} // namespace intake
