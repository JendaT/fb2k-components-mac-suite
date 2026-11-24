//
//  IntakeFieldsTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeFields (B13 item 4): the field names, and the three
//  values per record: every doc 03 status id, an unknown status kept as the
//  CLI's text, the readable target only when target_path is set, the
//  collection with or without a target, and the values IntakeSnapshot::build
//  stores on its records. Synthetic names only.
//
// TEST_DEPS: src/Core/IntakeStatusModel.mm src/Core/IntakeTargetPath.mm
// TEST_DEPS: src/Core/IntakePath.mm src/Core/IntakeLog.mm src/Core/IntakeEnvelope.mm
// TEST_DEPS: src/Core/IntakeSnapshot.mm src/Core/IntakeSidecarMembers.mm
// TEST_DEPS: src/Core/IntakeDecorationMap.mm src/Core/IntakeReviewRule.mm src/Core/IntakeGroupBadge.mm
// TEST_DEPS: src/Core/IntakeSettingsParse.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeFields.h"
#include "../src/Core/IntakePath.h"
#include "../src/Core/IntakeSnapshot.h"
#include "../src/Core/IntakeStatusModel.h"
#include "../src/Core/IntakeTargetPath.h"
#include "TestHarness.h"

#include <string>

using namespace intake;

static IntakeRecord record(IntakeStatus status, const std::string &statusText = std::string()) {
    IntakeRecord r;
    r.id = "itk_00000001";
    r.rootPath = "/income/dump/Fixture Artist - Album";
    normalizePath(r.rootPath, r.rootKey);
    r.status = status;
    r.statusText = statusText.empty() ? std::string(intakeStatusName(status)) : statusText;
    return r;
}

static IntakeRecord proposed(const std::string &collection, TargetPathState state, const std::string &target) {
    IntakeRecord r = record(IntakeStatus::Proposed);
    r.hasProposal = true;
    r.proposal.targetCollection = collection;
    r.proposal.targetPathState = state;
    r.proposal.targetPath = target;
    return r;
}

static void testNames() {
    g_context = "names";
    CHECK_EQ(kIntakeFieldCount, 3, "three fields");
    CHECK(intakeFieldName(0) == "intake_status", "index 0");
    CHECK(intakeFieldName(1) == "intake_target", "index 1");
    CHECK(intakeFieldName(2) == "intake_collection", "index 2");
    CHECK(intakeFieldName(3).empty(), "past the end: empty");
    CHECK(intakeFieldName(0xFFFFFFFFu).empty(), "far past the end: empty");
    CHECK_EQ(static_cast<uint32_t>(IntakeField::Status), 0, "Status is index 0");
    CHECK_EQ(static_cast<uint32_t>(IntakeField::Target), 1, "Target is index 1");
    CHECK_EQ(static_cast<uint32_t>(IntakeField::Collection), 2, "Collection is index 2");
}

static void testStatusIds() {
    g_context = "status ids";
    struct Case {
        IntakeStatus status;
        const char *id;
    };
    const Case cases[] = {
        {IntakeStatus::New, "new"},           {IntakeStatus::Resolved, "resolved"},
        {IntakeStatus::Proposed, "proposed"}, {IntakeStatus::Approved, "approved"},
        {IntakeStatus::Placing, "placing"},   {IntakeStatus::Placed, "placed"},
        {IntakeStatus::Rejected, "rejected"}, {IntakeStatus::GcDone, "gc_done"},
    };
    for (const Case &c : cases) {
        const IntakeFieldValues v = fieldValuesFor(record(c.status));
        CHECK(v.status == c.id, c.id);
        CHECK(v.target.empty() && v.collection.empty(), "no proposal: no target, no collection");
    }
    // The id comes from the status, not from the CLI's spelling.
    IntakeRecord r = record(IntakeStatus::Placed, "placed");
    CHECK(fieldValuesFor(r).status == "placed", "known status: its doc 03 id");
}

static void testUnknownStatus() {
    g_context = "unknown status";
    CHECK(fieldValuesFor(record(IntakeStatus::Unknown, "held")).status == "held", "the CLI's own text");
    IntakeRecord noText = record(IntakeStatus::Unknown, "x");
    noText.statusText.clear();
    CHECK(fieldValuesFor(noText).status.empty(), "no text kept: empty (no field)");
}

static void testTarget() {
    g_context = "target";
    const std::string target = "/library/tier-hq/Test Collection A/Fixture Artist/Fixture Artist - 2026 - Album";
    IntakeFieldValues v = fieldValuesFor(proposed("Test Collection A", TargetPathState::Set, target));
    CHECK(v.status == "proposed", "status");
    CHECK(v.target == "tier-hq/Test Collection A/Fixture Artist/Fixture Artist - 2026 - Album",
          "the readable target, from the tier folder on");
    CHECK(v.target == displayTargetPath(target, "Test Collection A"), "exactly displayTargetPath");
    CHECK(v.collection == "Test Collection A", "the collection");

    v = fieldValuesFor(proposed("Test Collection A", TargetPathState::Null, std::string()));
    CHECK(v.target.empty(), "a null target: no target");
    CHECK(v.collection == "Test Collection A", "the collection all the same");

    v = fieldValuesFor(proposed("Test Collection A", TargetPathState::Unknown, std::string()));
    CHECK(v.target.empty(), "CLI 0.2.1 (no target_path): no target");
    CHECK(v.collection == "Test Collection A", "the collection all the same");

    v = fieldValuesFor(proposed(std::string(), TargetPathState::Set, "/library/tier-hq/x/y/z"));
    CHECK(v.target == "tier-hq/x/y/z", "no collection: the last four components");
    CHECK(v.collection.empty(), "no collection: empty");

    // Set with an empty string never happens (the parser makes it Null), but
    // the value stays empty rather than "".
    v = fieldValuesFor(proposed("C", TargetPathState::Set, std::string()));
    CHECK(v.target.empty(), "Set but empty: no target");

    // target_path only counts inside a proposal.
    IntakeRecord noProposal = proposed("C", TargetPathState::Set, target);
    noProposal.hasProposal = false;
    v = fieldValuesFor(noProposal);
    CHECK(v.target.empty() && v.collection.empty(), "no proposal: neither");

    // Placed keeps its target and collection.
    IntakeRecord placed = proposed("Test Collection A", TargetPathState::Set, target);
    placed.status = IntakeStatus::Placed;
    v = fieldValuesFor(placed);
    CHECK(v.status == "placed" && !v.target.empty() && v.collection == "Test Collection A",
          "placed: status, target and collection");
}

static void testNfc() {
    g_context = "nfc";
    // An NFD collection folder: displayTargetPath returns NFC.
    const std::string nfd = "Cafe\xCC\x81";
    const std::string nfc = "Caf\xC3\xA9";
    IntakeFieldValues v = fieldValuesFor(proposed(nfd, TargetPathState::Set, "/lib/tier/" + nfd + "/A/R"));
    CHECK(v.target == "tier/" + nfc + "/A/R", "the target in NFC");
    CHECK(v.collection == nfd, "the collection as the CLI spelled it");
}

static void testValueAccess() {
    g_context = "value()";
    IntakeFieldValues v;
    v.status = "s";
    v.target = "t";
    v.collection = "c";
    CHECK(v.value(0) == "s" && v.value(1) == "t" && v.value(2) == "c", "by index");
    CHECK(v.value(3).empty() && v.value(99).empty(), "past the end: empty");
    IntakeFieldValues w = v;
    CHECK(v == w, "equal");
    w.target = "u";
    CHECK(!(v == w), "a different target");
}

static void testSnapshotStoresValues() {
    g_context = "snapshot";
    IntakeRecord a = proposed("Test Collection A", TargetPathState::Set, "/lib/tier-hq/Test Collection A/Art/Rel");
    IntakeRecord b = record(IntakeStatus::New);
    b.id = "itk_00000002";
    b.rootPath = "/income/dump/Other";
    normalizePath(b.rootPath, b.rootKey);
    auto s = IntakeSnapshot::build({a, b}, {});
    const IntakeRecord *ra = s->recordForId(a.id);
    const IntakeRecord *rb = s->recordForId(b.id);
    CHECK(ra != nullptr && rb != nullptr, "both records");
    if (ra && rb) {
        CHECK(ra->fields == fieldValuesFor(*ra), "a: computed by build");
        CHECK(ra->fields.target == "tier-hq/Test Collection A/Art/Rel", "a: target");
        CHECK(rb->fields.status == "new" && rb->fields.target.empty() && rb->fields.collection.empty(),
              "b: status only");
    }
}

int main(void) {
    @autoreleasepool {
        testNames();
        testStatusIds();
        testUnknownStatus();
        testTarget();
        testNfc();
        testValueAccess();
        testSnapshotStoresValues();
    }
    TEST_MAIN_END();
}
