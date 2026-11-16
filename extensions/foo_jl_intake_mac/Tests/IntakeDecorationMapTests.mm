//
//  IntakeDecorationMapTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeDecorationMap: every row of doc 04 v1.2's "Row
//  decorations" table, the tooltip additions, palette overrides and the
//  mirrored icon enum. Synthetic records only.
//
// TEST_DEPS: src/Core/IntakeReviewRule.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeDecorationMap.h"
#include "../src/Core/IntakeStatusModel.h"
#include "TestHarness.h"

#include <string>

using namespace intake;

// SimPlaylist DebugDummyDecorator.mm colours (PLAN.md 3.9 defaults).
static constexpr IntakeRgba kBlue = 0x4A90D938;
static constexpr IntakeRgba kAmber = 0xE5A50A38;
static constexpr IntakeRgba kAmberIcon = 0xE5A50AFF;
static constexpr IntakeRgba kTeal = 0x2AA19838;
static constexpr IntakeRgba kGreen = 0x3FB95038;
static constexpr IntakeRgba kGreenIcon = 0x3FB950FF;
static constexpr IntakeRgba kGrey = 0x80808028;

static IntakeRecord record(IntakeStatus status, bool needsReview = false) {
    IntakeRecord r;
    r.id = "itk_00000001";
    r.rootPath = r.rootKey = "/income/dump/Fixture Artist - Test Album";
    r.status = status;
    r.needsReview = needsReview;
    return r;
}

static IntakeRecord proposed(IntakeStatus status, bool needsReview, AssignedBy by,
                             TargetPathState target = TargetPathState::Set) {
    IntakeRecord r = record(status, needsReview);
    r.hasProposal = true;
    r.proposal.targetCollection = "Test Collection A";
    r.proposal.hasConfidence = true;
    r.proposal.confidence = by == AssignedBy::User ? 1.0 : 0.8;
    r.proposal.assignedBy = by;
    r.proposal.targetPathState = target;
    if (target == TargetPathState::Set) r.proposal.targetPath = "/library/Test Collection A/Fixture Artist - Test Album";
    return r;
}

static IntakeRecord placed(bool verified) {
    IntakeRecord r = proposed(IntakeStatus::Placed, false, AssignedBy::Engine);
    r.hasPlaced = true;
    r.placedVerified = verified;
    r.placedTargetPath = "/library/Test Collection A/Fixture Artist - Test Album";
    return r;
}

static bool is(const IntakeRowVisual &v, IntakeRgba tint, IntakeIcon icon, IntakeRgba iconColor,
               const std::string &tooltip, bool strike) {
    return v.bgTint == tint && v.icon == icon && v.iconColor == iconColor && v.tooltip == tooltip &&
           v.strikethrough == strike;
}

static void testTable() {
    g_context = "table";
    CHECK(is(rowVisualFor(record(IntakeStatus::New)), kBlue, IntakeIcon::CircleOpen, 0, "", false),
          "new: blue, open circle");
    CHECK(is(rowVisualFor(record(IntakeStatus::New, true)), kBlue, IntakeIcon::CircleOpen, 0, "needs review", false),
          "new + needs_review: blue, open circle, tooltip \"needs review\"");
    CHECK(is(rowVisualFor(record(IntakeStatus::Resolved)), kBlue, IntakeIcon::CircleOpen, 0, "", false),
          "resolved: blue, open circle");
    CHECK(is(rowVisualFor(record(IntakeStatus::Resolved, true)), kAmber, IntakeIcon::Warning, kAmberIcon,
             "needs review", false),
          "resolved + needs_review (no proposal): amber, warning, tooltip \"needs review\"");
    CHECK(is(rowVisualFor(proposed(IntakeStatus::Proposed, false, AssignedBy::Engine)), kTeal,
             IntakeIcon::CircleLeftHalf, 0, "", false),
          "proposed: teal, left half circle");
    CHECK(is(rowVisualFor(proposed(IntakeStatus::Proposed, true, AssignedBy::Engine)), kAmber,
             IntakeIcon::CircleLeftHalf, kAmberIcon, "needs review", false),
          "proposed + needs_review: amber, left half circle, tooltip \"needs review\"");
    CHECK(is(rowVisualFor(proposed(IntakeStatus::Proposed, true, AssignedBy::User)), kAmber,
             IntakeIcon::CircleLeftHalf, kAmberIcon, "needs review", false),
          "proposed + needs_review, user-assigned: still amber with the tooltip (v1.2)");
    CHECK(is(rowVisualFor(proposed(IntakeStatus::Resolved, true, AssignedBy::User)), kAmber, IntakeIcon::Warning,
             kAmberIcon, "needs review", false),
          "resolved + needs_review with a user proposal: amber, warning, tooltip");
    CHECK(is(rowVisualFor(proposed(IntakeStatus::Proposed, false, AssignedBy::User)), kTeal,
             IntakeIcon::CircleLeftHalf, 0, "", false),
          "user-assigned without needs_review: teal");
    CHECK(is(rowVisualFor(proposed(IntakeStatus::Approved, false, AssignedBy::Engine)), kTeal,
             IntakeIcon::CircleRightHalf, 0, "", false),
          "approved: teal, right half circle");
    CHECK(is(rowVisualFor(proposed(IntakeStatus::Approved, true, AssignedBy::Engine)), kTeal,
             IntakeIcon::CircleRightHalf, 0, "", false),
          "approved ignores a stray needs_review");
    CHECK(is(rowVisualFor(proposed(IntakeStatus::Placing, false, AssignedBy::Engine)), kTeal, IntakeIcon::ArrowRight,
             0, "placing \xE2\x80\x94 see intake status", false),
          "placing: teal, arrow, tooltip");
    CHECK(is(rowVisualFor(placed(true)), kGreen, IntakeIcon::CircleFilled, kGreenIcon, "", false),
          "placed verified: green, filled circle");
    CHECK(rowVisualFor(placed(false)).isNone(), "placed verified false: nothing");
    CHECK(rowVisualFor(record(IntakeStatus::Placed)).isNone(), "placed without a placed object: nothing");
    CHECK(rowVisualFor(record(IntakeStatus::GcDone)).isNone(), "gc_done: nothing");
    CHECK(rowVisualFor(record(IntakeStatus::Unknown)).isNone(), "unknown status: nothing");
    CHECK(rowVisualFor(record(IntakeStatus::Unknown, true)).isNone(), "unknown status with needs_review: nothing");
    CHECK(is(rowVisualFor(proposed(IntakeStatus::Rejected, false, AssignedBy::Engine)), kGrey, IntakeIcon::Cross, 0,
             "", true),
          "rejected: grey, cross, strikethrough");
}

static void testTooltips() {
    g_context = "slot-pending";
    CHECK(rowVisualFor(proposed(IntakeStatus::Resolved, false, AssignedBy::Engine, TargetPathState::Null)).tooltip ==
              "slot pending",
          "resolved with a null target_path: slot pending");
    CHECK(rowVisualFor(proposed(IntakeStatus::Proposed, false, AssignedBy::Engine, TargetPathState::Null)).tooltip ==
              "slot pending",
          "proposed with a null target_path: slot pending");
    CHECK(rowVisualFor(proposed(IntakeStatus::Approved, false, AssignedBy::User, TargetPathState::Null)).tooltip ==
              "slot pending",
          "approved with a null target_path: slot pending");
    // assign is legal from new and keeps the status (contract v1.2): a new
    // single assigned by the user has a null target.
    CHECK(is(rowVisualFor(proposed(IntakeStatus::New, false, AssignedBy::User, TargetPathState::Null)), kBlue,
             IntakeIcon::CircleOpen, 0, "slot pending", false),
          "new with a null target_path: blue, slot pending");
    CHECK(rowVisualFor(proposed(IntakeStatus::New, true, AssignedBy::User, TargetPathState::Null)).tooltip ==
              "needs review \xC2\xB7 slot pending",
          "new + needs_review with a null target_path: both tooltips");
    CHECK(rowVisualFor(proposed(IntakeStatus::New, false, AssignedBy::User)).tooltip.empty(),
          "new with a target: no slot pending");
    IntakeRowVisual amberPending =
        rowVisualFor(proposed(IntakeStatus::Proposed, true, AssignedBy::Engine, TargetPathState::Null));
    CHECK(amberPending.bgTint == kAmber && amberPending.tooltip == "needs review \xC2\xB7 slot pending",
          "amber and slot pending together: needs review first");
    CHECK(rowVisualFor(proposed(IntakeStatus::Proposed, false, AssignedBy::Unknown, TargetPathState::Unknown))
              .tooltip.empty(),
          "target_path unknown (CLI 0.2.1): no slot pending");
    CHECK(rowVisualFor(proposed(IntakeStatus::Rejected, false, AssignedBy::Engine, TargetPathState::Null))
              .tooltip.empty(),
          "rejected: no slot pending");

    g_context = "last-error";
    IntakeRecord withError = record(IntakeStatus::New, true);
    withError.lastError = "E_BAD_STATUS: cannot propose from status new";
    CHECK(rowVisualFor(withError).tooltip == "needs review \xC2\xB7 E_BAD_STATUS: cannot propose from status new",
          "the last error follows the other tooltip parts");
    IntakeRecord goneError = record(IntakeStatus::GcDone);
    goneError.lastError = "E_VERIFY: mismatch";
    IntakeRowVisual tooltipOnly = rowVisualFor(goneError);
    CHECK(!tooltipOnly.isNone() && tooltipOnly.bgTint == 0 && tooltipOnly.icon == IntakeIcon::None &&
              tooltipOnly.tooltip == "E_VERIFY: mismatch",
          "a last error on a root that renders nothing is tooltip-only");

    g_context = "amber-tooltip";
    // doc 04 v1.2: every amber row carries "needs review", and only amber
    // rows (plus new + needs_review) do.
    const IntakeStatus all[] = {IntakeStatus::New, IntakeStatus::Resolved, IntakeStatus::Proposed,
                                IntakeStatus::Approved, IntakeStatus::Placing, IntakeStatus::Placed,
                                IntakeStatus::GcDone, IntakeStatus::Rejected, IntakeStatus::Unknown};
    int agree = 0, total = 0;
    for (IntakeStatus st : all) {
        for (int flag = 0; flag < 2; flag++) {
            IntakeRecord r = proposed(st, flag == 1, AssignedBy::Engine);
            r.hasPlaced = true;
            r.placedVerified = true;
            const IntakeRowVisual v = rowVisualFor(r);
            const bool amber = v.bgTint == kAmber;
            const bool says = v.tooltip.rfind("needs review", 0) == 0;
            const bool expectSays = amber || (st == IntakeStatus::New && flag == 1);
            total++;
            if (says == expectSays) agree++;
        }
    }
    CHECK_EQ(agree, total, "\"needs review\" exactly on amber rows and on new + needs_review");
    IntakeRecord amberError = record(IntakeStatus::Resolved, true);
    amberError.lastError = "E_BAD_STATUS: cannot propose from status resolved";
    CHECK(rowVisualFor(amberError).tooltip == "needs review \xC2\xB7 E_BAD_STATUS: cannot propose from status resolved",
          "an amber row's last error follows \"needs review\"");
}

static void testPalette() {
    g_context = "palette";
    IntakePalette defaults;
    CHECK(defaults.tintNew == kBlue && defaults.tintReview == kAmber && defaults.tintProposed == kTeal &&
              defaults.tintApproved == kTeal && defaults.tintPlaced == kGreen && defaults.tintRejected == kGrey,
          "defaults are the DebugDummyDecorator colours");
    IntakePalette custom;
    custom.tintNew = 0x11111150;
    custom.tintReview = 0x22222250;
    custom.tintProposed = 0x33333350;
    custom.tintApproved = 0x44444450;
    custom.tintPlaced = 0x55555550;
    custom.tintRejected = 0x66666650;
    CHECK(rowVisualFor(record(IntakeStatus::New), custom).bgTint == 0x11111150, "custom new tint");
    IntakeRowVisual review = rowVisualFor(record(IntakeStatus::Resolved, true), custom);
    CHECK(review.bgTint == 0x22222250 && review.iconColor == 0x222222FF, "the review icon follows the review tint");
    CHECK(rowVisualFor(proposed(IntakeStatus::Proposed, false, AssignedBy::Engine), custom).bgTint == 0x33333350,
          "custom proposed tint");
    CHECK(rowVisualFor(proposed(IntakeStatus::Approved, false, AssignedBy::Engine), custom).bgTint == 0x44444450,
          "custom approved tint");
    CHECK(rowVisualFor(proposed(IntakeStatus::Placing, false, AssignedBy::Engine), custom).bgTint == 0x44444450,
          "placing uses the approved tint");
    IntakeRowVisual green = rowVisualFor(placed(true), custom);
    CHECK(green.bgTint == 0x55555550 && green.iconColor == 0x555555FF, "the placed icon follows the placed tint");
    CHECK(rowVisualFor(proposed(IntakeStatus::Rejected, false, AssignedBy::Engine), custom).bgTint == 0x66666650,
          "custom rejected tint");
    IntakePalette off;
    off.tintReview = 0;
    IntakeRowVisual noTint = rowVisualFor(record(IntakeStatus::Resolved, true), off);
    CHECK(noTint.bgTint == 0 && noTint.icon == IntakeIcon::Warning && noTint.iconColor == 0,
          "a tint turned off keeps the icon in the host colour");
    CHECK(opaqueColor(0x12345600) == 0x123456FF, "opaqueColor sets full alpha");
}

// B10a: from alpha 0x99 (60%) up, a row icon that takes its tint's colour
// uses the label colour (0), or it vanishes into the background of the same
// RGB. Checked through the visuals of each record that colours its icon.
static void testIconOnOpaqueTint() {
    g_context = "icon-opaque-tint";
    CHECK_EQ(rowIconColor(0x12345698), 0x123456FFu, "alpha 0x98: the tint's RGB at full alpha");
    CHECK_EQ(rowIconColor(0x12345699), 0u, "alpha 0x99: the label colour");
    CHECK_EQ(rowIconColor(0x123456FF), 0u, "alpha 0xFF: the label colour");
    CHECK_EQ(rowIconColor(0), 0u, "tint 0: the label colour");

    struct Case {
        IntakeRgba tint;
        IntakeRgba icon;
        const char *what;
    };
    const Case cases[] = {
        {0xFF00FF98, 0xFF00FFFF, "alpha 0x98 keeps the RGB at alpha FF"},
        {0xFF00FF99, 0, "alpha 0x99 gives the label colour"},
        {0xFF00FFFF, 0, "alpha 0xFF gives the label colour"},
        {0, 0, "tint 0 gives the label colour"},
    };
    for (const Case &c : cases) {
        IntakePalette p;
        p.tintPlaced = c.tint;
        p.tintReview = c.tint;
        const IntakeRowVisual green = rowVisualFor(placed(true), p);
        CHECK(green.bgTint == c.tint && green.icon == IntakeIcon::CircleFilled && green.iconColor == c.icon,
              (std::string("placed: ") + c.what).c_str());
        const IntakeRowVisual warning = rowVisualFor(record(IntakeStatus::Resolved, true), p);
        CHECK(warning.bgTint == c.tint && warning.icon == IntakeIcon::Warning && warning.iconColor == c.icon,
              (std::string("resolved + needs_review: ") + c.what).c_str());
        const IntakeRowVisual half = rowVisualFor(proposed(IntakeStatus::Proposed, true, AssignedBy::Engine), p);
        CHECK(half.bgTint == c.tint && half.icon == IntakeIcon::CircleLeftHalf && half.iconColor == c.icon,
              (std::string("proposed + needs_review: ") + c.what).c_str());
    }

    // The defaults are all below 0x99 (0x38, 0x28): their icons are as before.
    const IntakePalette d;
    const IntakeRgba defaults[] = {d.tintNew,    d.tintReview, d.tintProposed,
                                   d.tintApproved, d.tintPlaced, d.tintRejected};
    int below = 0;
    for (IntakeRgba t : defaults) {
        if ((t & 0xFFu) < kRowIconLabelColourAlpha && rowIconColor(t) == opaqueColor(t)) below++;
    }
    CHECK_EQ(below, 6, "every default alpha is below 0x99, so rowIconColor is opaqueColor");
    CHECK(rowVisualFor(placed(true), d).iconColor == kGreenIcon, "default palette: the placed icon stays green");
    CHECK(rowVisualFor(record(IntakeStatus::Resolved, true), d).iconColor == kAmberIcon,
          "default palette: the review icon stays amber");
}

static void testConsistency() {
    g_context = "consistency";
    // statusHasVisual (what IntakeSidecarMembers spends I/O on) must agree
    // with the table.
    const IntakeStatus all[] = {IntakeStatus::New, IntakeStatus::Resolved, IntakeStatus::Proposed,
                                IntakeStatus::Approved, IntakeStatus::Placing, IntakeStatus::Placed,
                                IntakeStatus::GcDone, IntakeStatus::Rejected, IntakeStatus::Unknown};
    int agree = 0, total = 0;
    for (IntakeStatus s : all) {
        for (int flags = 0; flags < 4; flags++) {
            IntakeRecord r = record(s, flags & 1);
            r.hasPlaced = true;
            r.placedVerified = (flags & 2) != 0;
            total++;
            if (statusHasVisual(r) == !rowVisualFor(r).isNone()) agree++;
        }
    }
    CHECK_EQ(agree, total, "statusHasVisual matches the table for every status and flag");

    g_context = "icons";
    // jl_icon_id values (shared/jl_decorator_api.h), append-only ABI.
    CHECK(static_cast<uint32_t>(IntakeIcon::None) == 0 && static_cast<uint32_t>(IntakeIcon::CircleOpen) == 1 &&
              static_cast<uint32_t>(IntakeIcon::CircleLeftHalf) == 2 &&
              static_cast<uint32_t>(IntakeIcon::CircleRightHalf) == 3 &&
              static_cast<uint32_t>(IntakeIcon::CircleFilled) == 4 && static_cast<uint32_t>(IntakeIcon::Warning) == 5 &&
              static_cast<uint32_t>(IntakeIcon::Cross) == 6 && static_cast<uint32_t>(IntakeIcon::Check) == 7 &&
              static_cast<uint32_t>(IntakeIcon::ArrowRight) == 8,
          "IntakeIcon mirrors jl_icon_id value for value");
    CHECK(IntakeRowVisual().isNone(), "a default visual is none");
    CHECK(rowVisualFor(record(IntakeStatus::New)) == rowVisualFor(record(IntakeStatus::New)), "visual equality");
    CHECK(rowVisualFor(record(IntakeStatus::New)) != rowVisualFor(record(IntakeStatus::New, true)),
          "a tooltip difference is a different visual");
}

int main(void) {
    @autoreleasepool {
        testTable();
        testTooltips();
        testPalette();
        testIconOnOpaqueTint();
        testConsistency();
    }
    TEST_MAIN_END();
}
