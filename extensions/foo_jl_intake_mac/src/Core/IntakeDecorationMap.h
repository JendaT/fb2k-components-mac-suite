//
//  IntakeDecorationMap.h
//  foo_jl_intake
//
//  Root state to row visual, per doc 04 v1.2 "Row decorations (status ->
//  visual)". SDK-free: Integration copies an IntakeRowVisual into a
//  jl_row_decoration (B3), with a static_assert that IntakeIcon matches
//  jl_icon_id.
//
//   status                          tint   icon
//   new, resolved                   blue   open circle
//   resolved + needs review         amber  warning            (IntakeReviewRule)
//   proposed                        teal   left half circle
//   proposed + needs review         amber  left half circle   also when user-assigned
//   approved                        teal   right half circle
//   placing                         teal   right arrow
//   placed, verified true           green  filled circle
//   placed verified false, gc_done,
//   unknown                         none   none
//   rejected                        grey   cross              strikethrough
//
//  Amber icons (warning, and the half circle under review) and the placed
//  filled circle take their tint's RGB at full alpha as icon colour, as in
//  SimPlaylist's DebugDummyDecorator, unless the tint's alpha is 60% (0x99)
//  or more: then they use the host's label colour (rowIconColor). The other
//  icons always use the host's label colour (0). placing uses the approved
//  tint (it follows approve).
//
//  Tooltip (B13): every row whose status renders (statusHasVisual) gets one,
//  lines joined with "\n" (SimPlaylist shows it as a plain NSString), in
//  this order, a line left out when it has nothing to say:
//   1. "Intake: <status>" (intakeStatusLabel), plus " \u00B7 needs review"
//      when needs_review is set on a new, resolved or proposed root (so on
//      every amber row and on new + needs_review, doc 04 v1.2). Reasons are
//      not in `status --json` (doc 03 v1.2): only the flag.
//   2. "placing \u2014 see intake status" on placing (an em dash, U+2014).
//   3. The target, from the proposal:
//      - target_path set: "Target: " + displayTargetPath (IntakeTargetPath:
//        from the tier folder on, "music.hq/[Collection]/Artist/Release");
//      - target_path null, on new, resolved, proposed or approved: on a
//        singles root (IntakeRecord::singlesRoot) "Target: <collection>
//        \u00B7 slot pending" ("Target: slot pending" without a
//        collection); on any other root kTooltipCannotBePlaced, "Target:
//        none, cannot be placed (see intake status)", whoever assigned it.
//        From CLI 0.3.0 null means the singles slot, or a target that can
//        never be built (tier `reject`, no album name, a tier not
//        configured); status --json carries no tier or slot, so the root
//        kind is the only signal (compilations get a target, amendment 003);
//      - target_path absent (CLI 0.2.1): "Target: <collection>";
//      - no proposal on a resolved root: kTooltipNoTarget.
//   4. Who assigned, when there is a proposal: "Assigned by you"
//      (assigned_by user; its confidence is always 1), "Assigned by the
//      engine (confidence 0.91)", "Assigned by <other> (confidence ...)",
//      or, with assigned_by absent (CLI 0.2.1), "Confidence 0.91". The
//      confidence part is left out when the CLI sent none.
//   5. A non-empty IntakeRecord::lastError (a per-command error that
//      Integration keeps until the root's status changes).
//  A root whose status renders nothing gets its lastError alone, as a
//  tooltip-only visual, or nothing, as before B13: no row that was not
//  decorated gains a tooltip.
//
//  Thread-safety: pure functions, no shared state.
//

#pragma once

#include <cstdint>
#include <string>

namespace intake {

struct IntakeRecord;

// Mirrors jl_icon_id (shared/jl_decorator_api.h), value for value. Integration
// static_asserts the match, since that enum is append-only ABI.
enum class IntakeIcon : uint32_t {
    None = 0,
    CircleOpen,       // U+25CB
    CircleLeftHalf,   // U+25D0
    CircleRightHalf,  // U+25D1
    CircleFilled,     // U+25CF
    Warning,          // U+26A0
    Cross,            // U+2715
    Check,            // U+2713
    ArrowRight,       // U+2192
};

// Packed 0xRRGGBBAA, as jl_rgba_t. 0 means none.
using IntakeRgba = uint32_t;

// Row background tints. Defaults are the colours of SimPlaylist's
// DebugDummyDecorator (PLAN.md 3.9); the `tint_*` settings (B10,
// IntakeTint.h) override them, so the caller passes the palette in. A tint
// of 0 draws no background.
struct IntakePalette {
    IntakeRgba tintNew = 0x4A90D938;      // intake blue: new, resolved
    IntakeRgba tintReview = 0xE5A50A38;   // amber: needs review
    IntakeRgba tintProposed = 0x2AA19838; // teal: proposed
    IntakeRgba tintApproved = 0x2AA19838; // teal: approved, placing
    IntakeRgba tintPlaced = 0x3FB95038;   // green: placed and verified
    IntakeRgba tintRejected = 0x80808028; // grey: rejected

    bool operator==(const IntakePalette &other) const = default;
};

struct IntakeRowVisual {
    IntakeRgba bgTint = 0;
    IntakeIcon icon = IntakeIcon::None;
    IntakeRgba iconColor = 0;  // 0: the host's label colour
    std::string tooltip;       // UTF-8; empty: none
    bool strikethrough = false;

    // Default-constructed: no decoration.
    bool isNone() const {
        return bgTint == 0 && icon == IntakeIcon::None && iconColor == 0 && tooltip.empty() &&
               !strikethrough;
    }
    bool operator==(const IntakeRowVisual &other) const {
        return bgTint == other.bgTint && icon == other.icon && iconColor == other.iconColor &&
               tooltip == other.tooltip && strikethrough == other.strikethrough;
    }
    bool operator!=(const IntakeRowVisual &other) const { return !(*this == other); }
};

// Tooltip texts (UTF-8), exposed for tests and for B6's badge wording.
extern const char *_Nonnull const kTooltipNeedsReview;   // "needs review"
extern const char *_Nonnull const kTooltipPlacing;       // "placing \u2014 see intake status"
extern const char *_Nonnull const kTooltipSlotPending;   // "slot pending"
extern const char *_Nonnull const kTooltipStatusPrefix;  // "Intake: "
extern const char *_Nonnull const kTooltipTargetPrefix;  // "Target: "
// "No target yet: Propose (or Assign to a collection first)"
extern const char *_Nonnull const kTooltipNoTarget;
// "Target: none, cannot be placed (see intake status)"
extern const char *_Nonnull const kTooltipCannotBePlaced;

enum class IntakeStatus;

// The status in words for the tooltip: "New", "Resolved", "Proposed",
// "Approved", "Placing", "Placed", "Local copy deleted" (gc_done),
// "Rejected", "Unknown".
const char *_Nonnull intakeStatusLabel(IntakeStatus status);

// The visual for `record` (status, needs_review, proposal, placed, lastError).
IntakeRowVisual rowVisualFor(const IntakeRecord &record, const IntakePalette &palette = IntakePalette());

// True when the status alone gives the row a visual: new, resolved,
// proposed, approved, placing, rejected, and placed with verified true.
// False for placed unverified, gc_done and unknown statuses. IntakeSidecarMembers
// uses it to skip all I/O for roots that render nothing.
bool statusHasVisual(const IntakeRecord &record);

// The icon colour for a tint: its RGB at full alpha. A tint of 0 (none, a
// preference that turns the tint off) gives 0, the host's label colour.
inline constexpr IntakeRgba opaqueColor(IntakeRgba tint) {
    return tint == 0 ? 0 : ((tint & 0xFFFFFF00u) | 0xFFu);
}

// The tint alpha from which a row icon takes the label colour: 0x99, 60%.
inline constexpr uint32_t kRowIconLabelColourAlpha = 0x99;

// The colour of a row icon that takes its tint's colour. From 60% alpha up
// the background is nearly the tint's own RGB, so an icon in that RGB would
// not show (B10a: tint_placed 0xFF00FFFF hid the placed dot); it gives 0,
// the host's label colour, the colour of the row text. Below that,
// opaqueColor. Group badges keep opaqueColor: the group header is not tinted.
inline constexpr IntakeRgba rowIconColor(IntakeRgba tint) {
    return (tint & 0xFFu) >= kRowIconLabelColourAlpha ? 0 : opaqueColor(tint);
}

} // namespace intake
