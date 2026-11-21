//
//  IntakeRejectReasonTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeRejectReason: the Reject… sheet's preset list and
//  the reason a choice and the free text give.
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeRejectReason.h"
#include "TestHarness.h"

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

int main(void) {
    @autoreleasepool {
        testChoices();
        testReason();
    }
    TEST_MAIN_END();
}
