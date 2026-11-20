//
//  IntakeTestActionScriptTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeTestActionScript, the parser of the temporary
//  foo_jl_intake.test_actions acceptance aid (the B11 in-app run's steps:
//  rows, swap, show, delete-sheet and wait; removed with the aid before the
//  merge to main).
//
// TEST_DEPS: src/Core/IntakeCommandArgs.mm src/Core/IntakeSemver.mm src/Core/IntakeSettingsParse.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeTestActionScript.h"
#include "TestHarness.h"

#include <string>
#include <vector>

using namespace intake;

static std::vector<std::string> v(std::initializer_list<std::string> items) {
    return std::vector<std::string>(items);
}

static bool invalid(const std::string &script, const std::string &errorPart) {
    std::vector<TestActionStep> steps = parseTestActions(script);
    return steps.size() == 1 && steps[0].kind == TestStepKind::Invalid &&
           steps[0].error.find(errorPart) != std::string::npos;
}

static void testSteps() {
    g_context = "steps";
    std::vector<TestActionStep> s = parseTestActions(
        "wait 8; rows itk_00000012; swap itk_00000012 itk_00000011 itk_00000012 ;show itk_00000012;"
        "delete-sheet itk_00000012 itk_00000011 close=8; wait 2.5");
    CHECK(s.size() == 6, "six steps");
    CHECK(s[0].kind == TestStepKind::Wait && s[0].seconds == 8 && s[0].ids.empty(), "wait 8");
    CHECK(s[0].text == "wait 8", "the step text, trimmed");
    CHECK(s[1].kind == TestStepKind::Rows && s[1].ids == v({"itk_00000012"}) && s[1].text == "rows itk_00000012",
          "rows <id>");
    CHECK(s[2].kind == TestStepKind::Swap && s[2].ids == v({"itk_00000012", "itk_00000011"}),
          "swap <ids>: a repeated id is kept once");
    CHECK(s[2].text == "swap itk_00000012 itk_00000011 itk_00000012", "the text keeps the step as written");
    CHECK(s[3].kind == TestStepKind::Show && s[3].ids == v({"itk_00000012"}), "show <id>");
    CHECK(s[4].kind == TestStepKind::DeleteSheet && s[4].ids == v({"itk_00000012", "itk_00000011"}) &&
              s[4].closeSeconds == 8,
          "delete-sheet <ids> close=8");
    CHECK(s[5].kind == TestStepKind::Wait && s[5].seconds == 2.5, "decimals for wait");

    std::vector<TestActionStep> tabs = parseTestActions("  show\titk_00000011\titk_00000011  ");
    CHECK(tabs[0].kind == TestStepKind::Show && tabs[0].ids == v({"itk_00000011"}),
          "tabs separate words; show with a repeated id is one id");
    CHECK(tabs[0].text == "show\titk_00000011\titk_00000011", "the step text, trimmed on both sides");
    std::vector<TestActionStep> close = parseTestActions("delete-sheet close=0.5 itk_00000012");
    CHECK(close[0].kind == TestStepKind::DeleteSheet && close[0].closeSeconds == 0.5 &&
              close[0].ids == v({"itk_00000012"}),
          "close= may stand before the ids; decimals allowed");
    CHECK(parseTestActions("delete-sheet itk_00000012 close=30")[0].kind == TestStepKind::DeleteSheet,
          "close=30 is the limit");
    CHECK(parseTestActions("wait 30")[0].kind == TestStepKind::Wait, "wait 30 is the limit");
    CHECK(parseTestActions(" ; ;;  ").empty(), "empty steps are skipped");
    CHECK(parseTestActions("").empty(), "an empty script has no steps");
    std::vector<TestActionStep> lines = parseTestActions("wait 8;\n  rows itk_00000012;\n  show itk_00000012\n");
    CHECK(lines.size() == 3 && lines[1].kind == TestStepKind::Rows && lines[2].kind == TestStepKind::Show,
          "line breaks inside the value are spaces");
}

static void testWaitInvalid() {
    g_context = "wait-invalid";
    CHECK(invalid("wait 31", "at most 30"), "wait over 30");
    CHECK(invalid("wait 0", "more than 0"), "wait 0");
    CHECK(invalid("wait abc", "wait needs one number of seconds"), "wait needs a number");
    CHECK(invalid("wait -1", "number"), "no negative wait");
    CHECK(invalid("wait", "number"), "wait without a number");
    CHECK(invalid("wait 1 2", "number"), "wait with two numbers");
    CHECK(invalid("wait itk_00000012", "number"), "wait takes no id");
    CHECK(invalid("wait close=2", "only delete-sheet takes close="), "wait takes no close=");
}

static void testIdStepsInvalid() {
    g_context = "id-steps-invalid";
    CHECK(invalid("rows", "rows takes exactly one id"), "rows needs an id");
    CHECK(invalid("rows itk_00000012 itk_00000011", "exactly one id"), "rows takes one id");
    CHECK(invalid("rows /income/dump/Placed", "not a sidecar id: /income/dump/Placed"), "rows takes an id, not a path");
    CHECK(invalid("show", "show takes exactly one id"), "show needs an id");
    CHECK(invalid("show itk_00000012 itk_00000011", "show takes exactly one id"), "show takes one id");
    CHECK(invalid("swap", "swap needs at least one id"), "swap needs ids");
    CHECK(invalid("swap itk_000000", "not a sidecar id"), "too few hex digits");
    CHECK(invalid("swap ITK_00000012", "not a sidecar id"), "ids are lowercase");
    CHECK(invalid("swap --all", "not a sidecar id"), "no flags");
    CHECK(invalid("delete-sheet itk_00000012", "delete-sheet needs close=<seconds>"), "delete-sheet needs close=");
    CHECK(invalid("delete-sheet close=5", "delete-sheet needs at least one id"), "delete-sheet needs ids");
    CHECK(invalid("delete-sheet itk_00000012 close=31", "at most 30"), "close over 30");
    CHECK(invalid("delete-sheet itk_00000012 close=0", "more than 0"), "close 0");
    CHECK(invalid("delete-sheet itk_00000012 close=abc", "close needs one number"), "close needs a number");
    CHECK(invalid("delete-sheet itk_00000012 close=", "close needs one number"), "close= without a value");
    CHECK(invalid("delete-sheet itk_00000012 close=-1", "close needs one number"), "no negative close");
    CHECK(invalid("delete-sheet itk_00000012 close=1 close=2", "twice"), "close= once");
    CHECK(invalid("delete-sheet --all close=5", "not a sidecar id"), "no flags: never an all-roots form");
    CHECK(invalid("swap itk_00000012 close=3", "only delete-sheet takes close="), "swap takes no close=");
    CHECK(invalid("rows itk_00000012 close=3", "only delete-sheet takes close="), "rows takes no close=");
    CHECK(invalid("show itk_00000012 close=3", "only delete-sheet takes close="), "show takes no close=");
}

static void testUnknownSteps() {
    g_context = "unknown-steps";
    // The B6-B10 steps this revival leaves out are unknown now.
    for (const char *verb : {"menu", "badge", "propose", "approve", "reject", "refresh", "assign", "assign-other",
                             "picker", "execute", "execute-sheet", "resume", "runs", "delete", "delete-swap",
                             "tint", "sweep"}) {
        CHECK(invalid(std::string(verb) + " itk_00000012", "unknown step \"" + std::string(verb) + "\""),
              (std::string(verb) + " is not a step").c_str());
    }
    CHECK(invalid("swaps itk_00000012", "unknown step"), "the verb is exact");
    CHECK(invalid("Rows itk_00000012", "unknown step"), "verbs are lowercase");
    CHECK(invalid("delete-local itk_00000012 close=5", "only delete-sheet takes close="),
          "close= is checked before the verb");

    std::vector<TestActionStep> mixed = parseTestActions("bogus; rows itk_00000012; swap; show itk_00000012");
    CHECK(mixed.size() == 4 && mixed[0].kind == TestStepKind::Invalid && mixed[1].kind == TestStepKind::Rows &&
              mixed[2].kind == TestStepKind::Invalid && mixed[3].kind == TestStepKind::Show,
          "an invalid step does not stop the others");
    CHECK(mixed[0].text == "bogus" && mixed[2].text == "swap", "an invalid step keeps its text for the log");
}

int main() {
    @autoreleasepool {
        testSteps();
        testWaitInvalid();
        testIdStepsInvalid();
        testUnknownSteps();
    }
    TEST_MAIN_END();
}
