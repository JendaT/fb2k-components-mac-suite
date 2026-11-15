//
//  IntakeDecorationMap.h
//  foo_jl_intake
//
//  Root state to row visual, per doc 04 v1.2 "Row decorations (status ->
//  visual)". SDK-free: Integration copies an IntakeRowVisual into a
//  jl_row_decoration (B3), with a static_assert that IntakeIcon matches
//  jl_icon_id.
//
//   status                          tint   icon               note
//   new, resolved                   blue   open circle
//   new + needs_review              blue   open circle        tooltip "needs review"
//   resolved + needs review         amber  warning            (IntakeReviewRule)
//   proposed                        teal   left half circle
//   proposed + needs review         amber  left half circle   also when user-assigned
//   approved                        teal   right half circle
//   placing                         teal   right arrow        tooltip "placing - see intake status"
//                                                             (an em dash, U+2014, in the text)
//   placed, verified true           green  filled circle
//   placed verified false, gc_done,
//   unknown                         none   none
//   rejected                        grey   cross              strikethrough
//
//  Amber icons (warning, and the half circle under review) and the placed
//  filled circle take their tint's RGB at full alpha as icon colour, as in
//  SimPlaylist's DebugDummyDecorator; the other icons use the host's label
//  colour (0). placing uses the approved tint (it follows approve).
//
//  Tooltip additions, joined with " \u00B7 " (a middle dot):
//   - a proposal whose `target_path` is present and null adds
//     "slot pending" on new, resolved, proposed and approved roots (doc 04
//     v1.2 wording). From CLI 0.3.0 null means the singles slot or a tier
//     `reject` root (compilations get a `[Compilations]` target, amendment
//     003); doc 04 leaves tier reject's own wording open. Absent (CLI
//     0.2.1) adds nothing: unknown, not pending.
//   - a non-empty IntakeRecord::lastError (a per-command error that
//     Integration keeps until the root's status changes) is appended, and
//     on its own gives a tooltip-only visual.
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
// DebugDummyDecorator (PLAN.md 3.9); the `tint_*` preferences (B5) override
// them, so the caller passes the palette in.
struct IntakePalette {
    IntakeRgba tintNew = 0x4A90D938;      // intake blue: new, resolved
    IntakeRgba tintReview = 0xE5A50A38;   // amber: needs review
    IntakeRgba tintProposed = 0x2AA19838; // teal: proposed
    IntakeRgba tintApproved = 0x2AA19838; // teal: approved, placing
    IntakeRgba tintPlaced = 0x3FB95038;   // green: placed and verified
    IntakeRgba tintRejected = 0x80808028; // grey: rejected
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
extern const char *_Nonnull const kTooltipNeedsReview;  // "needs review"
extern const char *_Nonnull const kTooltipPlacing;      // "placing \u2014 see intake status"
extern const char *_Nonnull const kTooltipSlotPending;  // "slot pending"

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

} // namespace intake
