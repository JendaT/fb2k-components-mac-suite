//
//  IntakeRejectReasonTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeRejectReason: the Reject… sheet's preset list, the
//  reason a choice and the free text give, and the choice a sheet opens on.
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeRejectReason.h"
#include "TestHarness.h"

#include <cstdint>
#include <string>

using namespace intake;

static void testChoices() {
    g_context = "choices";
    const std::vector<std::string> &c = rejectReasonChoices();
    CHECK(c.size() == 4 && c[0] == "Already in library" && c[1] == "Lower quality than library copy" &&
              c[2] == "Not wanted" && c[3] == "Other\xE2\x80\xA6",
          "the presets in order, then Other… with an ellipsis");
    CHECK_EQ(rejectReasonOtherIndex(), 3, "Other… is last");
    CHECK(!rejectChoiceIsOther(0) && !rejectChoiceIsOther(2) && rejectChoiceIsOther(3) && rejectChoiceIsOther(9),
          "only Other… (and past the end) is Other");
}

static void testReason() {
    g_context = "reason";
    CHECK(rejectReasonFor(0, "ignored") == "Already in library", "a preset gives its text; the free text is ignored");
    CHECK(rejectReasonFor(1, "") == "Lower quality than library copy", "the second preset");
    CHECK(rejectReasonFor(2, "  x ") == "Not wanted", "the third preset");
    CHECK(rejectReasonFor(3, "  Bad rip, clicks on track 4 \n") == "Bad rip, clicks on track 4",
          "Other…: the free text, trimmed");
    CHECK(rejectReasonFor(3, "   ").empty(), "Other… with only spaces: no reason");
    CHECK(rejectReasonFor(3, "").empty(), "Other… with nothing typed: no reason, as before the presets");
    CHECK(rejectReasonFor(42, "typed") == "typed", "an index past the end counts as Other…");
}

static void testInitialChoice() {
    g_context = "initial-choice";
    CHECK_EQ(rejectInitialChoice(SIZE_MAX), 0, "no pick yet this session: the first preset");
    CHECK(rejectReasonChoices()[rejectInitialChoice(SIZE_MAX)] == "Already in library",
          "the first sheet starts on Already in library");
    CHECK(!rejectChoiceIsOther(rejectInitialChoice(SIZE_MAX)), "the first sheet starts on a preset, not Other…");
    CHECK_EQ(rejectInitialChoice(0), 0, "the first preset kept");
    CHECK_EQ(rejectInitialChoice(2), 2, "a later preset kept");
    CHECK_EQ(rejectInitialChoice(3), 3, "Other… kept when it was the last pick");
    CHECK_EQ(rejectInitialChoice(4), 0, "past the end: the first preset");
}

int main(void) {
    @autoreleasepool {
        testChoices();
        testReason();
        testInitialChoice();
    }
    TEST_MAIN_END();
}
