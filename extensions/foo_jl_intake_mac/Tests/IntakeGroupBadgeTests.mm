//
//  IntakeGroupBadgeTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeGroupBadge: every rule of doc 04 v1.2's group
//  header badge (confidence, "yours", amber on review or low confidence,
//  the alt hint, slot pending, fields a CLI before 0.3.0 leaves unknown),
//  the confidence format, the palette, and the group rule (one root only;
//  unmapped members ignored; mixed roots hide the badge). Synthetic records.
//
// TEST_DEPS: src/Core/IntakeReviewRule.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeGroupBadge.h"
#include "../src/Core/IntakeStatusModel.h"
#include "TestHarness.h"

#include <cmath>
#include <string>

using namespace intake;

static const std::string kArrow = "\xE2\x86\x92";
static const std::string kDot = " \xC2\xB7 ";
static constexpr IntakeRgba kAmberText = 0xE5A50AFF;

static IntakeRecord rec(IntakeStatus status, const std::string &target, double confidence,
                        AssignedBy by = AssignedBy::Engine, bool needsReview = false) {
    IntakeRecord r;
    r.id = "itk_00000001";
    r.rootPath = r.rootKey = "/income/dump/Fixture Artist - Test Album";
    r.status = status;
    r.needsReview = needsReview;
    r.hasProposal = true;
    r.proposal.targetCollection = target;
    r.proposal.confidence = confidence;
    r.proposal.hasConfidence = true;
    r.proposal.assignedBy = by;
    r.proposal.targetPathState = TargetPathState::Set;
    r.proposal.targetPath = "/library/" + target + "/Fixture Artist - Test Album";
    return r;
}

static void setRanked(IntakeRecord &r, std::initializer_list<const char *> collections) {
    r.proposal.ranked.clear();
    double c = 0.9;
    for (const char *name : collections) {
        RankedCandidate cand;
        cand.collection = name;
        cand.confidence = c;
        cand.hasConfidence = true;
        c -= 0.1;
        r.proposal.ranked.push_back(cand);
    }
    r.proposal.rankedState = r.proposal.ranked.empty() ? RankedState::Empty : RankedState::Present;
}

static std::string badgeText(const std::string &target, const std::string &suffix) {
    return kArrow + " [" + target + "]" + suffix;
}

static void testFormat() {
    g_context = "format";
    CHECK(formatConfidence(0.91) == "0.91", "0.91");
    CHECK(formatConfidence(0.6) == "0.60", "0.6 has two decimals");
    CHECK(formatConfidence(1.0) == "1.00", "1.00");
    CHECK(formatConfidence(0.0) == "0.00", "0.00");
    CHECK(formatConfidence(0.125) == "0.13", "half rounds away from zero");
    CHECK(formatConfidence(0.999) == "1.00", "0.999 rounds up");
    CHECK(formatConfidence(0.05) == "0.05", "a leading zero in the hundredths");
    CHECK(formatConfidence(-0.2) == "0.00", "clamped below");
    CHECK(formatConfidence(1.7) == "1.00", "clamped above");
    CHECK(formatConfidence(NAN) == "?", "not finite");
}

static void testPlain() {
    g_context = "plain";
    IntakeRecord p = rec(IntakeStatus::Proposed, "Test Collection A", 0.91);
    setRanked(p, {"Test Collection A", "Test Collection B"});
    IntakeBadge b = recordBadge(p);
    CHECK(b.shown(), "a proposed root has a badge");
    CHECK(b.text == badgeText("Test Collection A", kDot + "0.91"), "target and confidence");
    CHECK(!b.amber && b.color == 0, "confident: host colour");

    IntakeRecord a = rec(IntakeStatus::Approved, "Test Collection B", 0.88);
    CHECK(recordBadge(a).text == badgeText("Test Collection B", kDot + "0.88"), "approved too");

    IntakeRecord brackets = rec(IntakeStatus::Proposed, "[A & B]", 0.7);
    CHECK(recordBadge(brackets).text == badgeText("[A & B]", kDot + "0.70"), "the name is shown as given, in brackets");

    IntakeRecord noConf = rec(IntakeStatus::Proposed, "Test Collection A", 0.0);
    noConf.proposal.hasConfidence = false;
    IntakeBadge nc = recordBadge(noConf);
    CHECK(nc.text == badgeText("Test Collection A", "") && !nc.amber, "no confidence: target only, not amber");
}

static void testHidden() {
    g_context = "hidden";
    const IntakeStatus others[] = {IntakeStatus::New,    IntakeStatus::Resolved, IntakeStatus::Placing,
                                   IntakeStatus::Placed, IntakeStatus::GcDone,   IntakeStatus::Rejected,
                                   IntakeStatus::Unknown};
    const char *names[] = {"new", "resolved", "placing", "placed", "gc_done", "rejected", "unknown"};
    for (size_t i = 0; i < sizeof(others) / sizeof(others[0]); i++) {
        IntakeRecord r = rec(others[i], "Test Collection A", 0.9);
        CHECK(!recordBadge(r).shown(), (std::string("no badge on ") + names[i]).c_str());
    }
    IntakeRecord noProposal = rec(IntakeStatus::Proposed, "Test Collection A", 0.9);
    noProposal.hasProposal = false;
    CHECK(!recordBadge(noProposal).shown(), "no proposal: no badge");
    IntakeRecord noTarget = rec(IntakeStatus::Approved, "", 0.9);
    CHECK(!recordBadge(noTarget).shown(), "no target collection: no badge");
}

static void testYours() {
    g_context = "yours";
    IntakeRecord u = rec(IntakeStatus::Proposed, "Test & Ambient", 1.0, AssignedBy::User);
    setRanked(u, {"Test Collection C", "Test Collection A"});
    IntakeBadge b = recordBadge(u);
    CHECK(b.text == badgeText("Test & Ambient", kDot + "yours"), "user-assigned: yours, not 1.00");
    CHECK(!b.amber, "yours without needs_review is not amber");

    IntakeRecord ur = u;
    ur.needsReview = true;
    IntakeBadge br = recordBadge(ur);
    CHECK(br.amber && br.color == kAmberText, "needs_review stays amber when user-assigned");
    CHECK(br.text == badgeText("Test & Ambient", kDot + "yours (alt: [Test Collection C])"),
          "amber yours: the engine's best as the hint");

    IntakeRecord userEmpty = rec(IntakeStatus::Approved, "Test Collection C", 1.0, AssignedBy::User);
    setRanked(userEmpty, {});
    CHECK(recordBadge(userEmpty).text == badgeText("Test Collection C", kDot + "yours"), "approved yours");

    IntakeRecord unknown = rec(IntakeStatus::Proposed, "Test Collection C", 1.0, AssignedBy::Unknown);
    CHECK(recordBadge(unknown).text == badgeText("Test Collection C", kDot + "1.00"),
          "assigned_by unknown (CLI 0.2.1): the confidence, no yours");
    IntakeRecord other = rec(IntakeStatus::Proposed, "Test Collection C", 0.75, AssignedBy::Other);
    CHECK(recordBadge(other).text == badgeText("Test Collection C", kDot + "0.75"), "another assigned_by: confidence");
}

static void testAmber() {
    g_context = "amber";
    IntakeRecord review = rec(IntakeStatus::Proposed, "Test Collection B", 0.61, AssignedBy::Engine, true);
    setRanked(review, {"Test Collection B", "Test Collection A", "Test & Ambient"});
    IntakeBadge rb = recordBadge(review);
    CHECK(rb.amber && rb.color == kAmberText, "review rule: amber");
    CHECK(rb.text == badgeText("Test Collection B", kDot + "0.61 (alt: [Test Collection A])"),
          "doc 04 example: first ranked entry that is not the target");

    IntakeRecord low = rec(IntakeStatus::Proposed, "Test Collection A", 0.59);
    setRanked(low, {"Test Collection A", "Test Collection C"});
    IntakeBadge lb = recordBadge(low);
    CHECK(lb.amber, "below 0.6: amber");
    CHECK(lb.text == badgeText("Test Collection A", kDot + "0.59 (alt: [Test Collection C])"), "low confidence hint");

    IntakeRecord edge = rec(IntakeStatus::Proposed, "Test Collection A", 0.6);
    setRanked(edge, {"Test Collection A", "Test Collection C"});
    IntakeBadge eb = recordBadge(edge);
    CHECK(!eb.amber && eb.text == badgeText("Test Collection A", kDot + "0.60"), "exactly 0.6: not amber, no hint");

    IntakeRecord approvedLow = rec(IntakeStatus::Approved, "Test Collection A", 0.5);
    setRanked(approvedLow, {"Test Collection B"});
    CHECK(recordBadge(approvedLow).amber, "low confidence on approved is amber too");

    IntakeRecord strayReview = rec(IntakeStatus::Approved, "Test Collection A", 0.9, AssignedBy::Engine, true);
    CHECK(!recordBadge(strayReview).amber, "needs_review on approved does not fire the rule");

    IntakeRecord notFirst = rec(IntakeStatus::Proposed, "Test Collection B", 0.4);
    setRanked(notFirst, {"Test Collection A", "Test Collection B"});
    CHECK(recordBadge(notFirst).text == badgeText("Test Collection B", kDot + "0.40 (alt: [Test Collection A])"),
          "the target need not be ranked first");

    IntakeRecord absent = rec(IntakeStatus::Proposed, "Test Collection A", 0.3);
    absent.proposal.rankedState = RankedState::Absent;
    CHECK(recordBadge(absent).text == badgeText("Test Collection A", kDot + "0.30"), "amber without ranked: no hint");

    IntakeRecord empty = rec(IntakeStatus::Proposed, "Test Collection A", 0.3);
    setRanked(empty, {});
    CHECK(recordBadge(empty).text == badgeText("Test Collection A", kDot + "0.30"), "ranked []: no hint");

    IntakeRecord onlyTarget = rec(IntakeStatus::Proposed, "Test Collection A", 0.3);
    setRanked(onlyTarget, {"Test Collection A"});
    CHECK(recordBadge(onlyTarget).text == badgeText("Test Collection A", kDot + "0.30"),
          "ranked holds only the target: no hint");

    IntakePalette custom;
    custom.tintReview = 0x11223344;
    CHECK(recordBadge(low, custom).color == 0x112233FF, "amber follows the review tint at full alpha");
    IntakePalette off;
    off.tintReview = 0;
    IntakeBadge offBadge = recordBadge(low, off);
    CHECK(offBadge.amber && offBadge.color == 0, "a review tint turned off leaves the host colour");
}

static void testSlotPending() {
    g_context = "slot-pending";
    IntakeRecord single = rec(IntakeStatus::Proposed, "Test Collection A", 0.95);
    single.proposal.targetPathState = TargetPathState::Null;
    single.proposal.targetPath.clear();
    setRanked(single, {"Test Collection A", "Test Collection B"});
    IntakeBadge b = recordBadge(single);
    CHECK(b.text == badgeText("Test Collection A", kDot + "slot pending"), "null target_path: slot pending");
    CHECK(b.amber && b.color == kAmberText, "slot pending is amber");

    IntakeRecord reviewed = single;
    reviewed.needsReview = true;
    CHECK(recordBadge(reviewed).text == badgeText("Test Collection A", kDot + "slot pending"),
          "slot pending carries no alt hint");

    IntakeRecord user = single;
    user.proposal.assignedBy = AssignedBy::User;
    CHECK(recordBadge(user).text == badgeText("Test Collection A", kDot + "slot pending"),
          "slot pending wins over yours");

    IntakeRecord unknown = rec(IntakeStatus::Proposed, "Test Collection A", 0.95);
    unknown.proposal.targetPathState = TargetPathState::Unknown;
    IntakeBadge ub = recordBadge(unknown);
    CHECK(ub.text == badgeText("Test Collection A", kDot + "0.95") && !ub.amber,
          "target_path unknown (CLI 0.2.1): no slot pending");
}

static void testGroupRule() {
    g_context = "group";
    IntakeRecord a = rec(IntakeStatus::Proposed, "Test Collection A", 0.91);
    a.id = "itk_0000000a";
    a.badge = recordBadge(a);
    IntakeRecord b = rec(IntakeStatus::Approved, "Test Collection B", 0.88);
    b.id = "itk_0000000b";
    b.badge = recordBadge(b);
    IntakeRecord resolved = rec(IntakeStatus::Resolved, "Test Collection A", 0.9);
    resolved.id = "itk_0000000c";
    resolved.badge = recordBadge(resolved);
    IntakeRecord aCopy = a;  // the same root reached through another record object

    CHECK(groupBadge({}) == nullptr, "no members: no badge");
    CHECK(groupBadge({nullptr, nullptr}) == nullptr, "no member maps: no badge");
    CHECK(groupBadge({&a, &a, &a}) == &a.badge, "every member in one root: its badge");
    CHECK(groupBadge({nullptr, &a, nullptr, &a}) == &a.badge, "unmapped members are ignored");
    CHECK(groupBadge({&a, &aCopy}) != nullptr, "one root is decided by id");
    CHECK(groupBadge({&a, &b}) == nullptr, "two roots: hidden");
    CHECK(groupBadge({&a, nullptr, &a, &b}) == nullptr, "a second root anywhere hides it");
    CHECK(groupRoot({&b, &b}) == &b, "groupRoot names the root");
    CHECK(groupRoot({&a, &b}) == nullptr, "groupRoot: none for mixed roots");
    CHECK(groupBadge({&resolved, &resolved}) == nullptr, "one root that shows no badge: none");
}

int main() {
    @autoreleasepool {
        testFormat();
        testPlain();
        testHidden();
        testYours();
        testAmber();
        testSlotPending();
        testGroupRule();
    }
    TEST_MAIN_END();
}
