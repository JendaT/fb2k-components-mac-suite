//
//  IntakeTestActionScriptTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeTestActionScript, the parser of the temporary
//  foo_jl_intake.test_actions acceptance aid (removed with it before the
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
    std::vector<TestActionStep> s =
        parseTestActions("menu itk_0000000b; propose itk_0000000b itk_0000000c ;wait 2.5;approve itk_0000000d");
    CHECK(s.size() == 4, "four steps");
    CHECK(s[0].kind == TestStepKind::Menu && s[0].ids == v({"itk_0000000b"}), "menu with one id");
    CHECK(s[0].text == "menu itk_0000000b", "the step text, trimmed");
    CHECK(s[1].kind == TestStepKind::Dispatch && s[1].action == IntakeAction::Propose &&
              s[1].ids == v({"itk_0000000b", "itk_0000000c"}),
          "propose with two ids");
    CHECK(s[2].kind == TestStepKind::Wait && s[2].seconds == 2.5, "wait 2.5");
    CHECK(s[3].kind == TestStepKind::Dispatch && s[3].action == IntakeAction::Approve, "approve");

    std::vector<TestActionStep> r = parseTestActions("reject itk_0000000e  reason=  wrong genre, re-tag = later  ");
    CHECK(r.size() == 1 && r[0].action == IntakeAction::Reject && r[0].ids == v({"itk_0000000e"}), "reject");
    CHECK(r[0].hasReason && r[0].reason == "wrong genre, re-tag = later", "reason: the rest of the step, trimmed");
    std::vector<TestActionStep> noReason = parseTestActions("reject itk_0000000e");
    CHECK(!noReason[0].hasReason && noReason[0].reason.empty(), "reject without a reason");

    std::vector<TestActionStep> refresh = parseTestActions("refresh");
    CHECK(refresh.size() == 1 && refresh[0].kind == TestStepKind::Dispatch &&
              refresh[0].action == IntakeAction::Refresh && refresh[0].ids.empty(),
          "refresh needs no id");
    CHECK(parseTestActions("refresh itk_0000000a")[0].kind == TestStepKind::Dispatch, "refresh accepts ids");

    std::vector<TestActionStep> tabs = parseTestActions("approve\titk_0000000d\titk_0000000d");
    CHECK(tabs[0].ids == v({"itk_0000000d"}), "tabs separate words; a repeated id is kept once");
    CHECK(parseTestActions(" ; ;;  ").empty(), "empty steps are skipped");
    CHECK(parseTestActions("").empty(), "an empty script has no steps");
    CHECK(parseTestActions("wait 30")[0].kind == TestStepKind::Wait, "wait 30 is the limit");
}

static void testBadge() {
    g_context = "badge";
    std::vector<TestActionStep> one = parseTestActions("badge itk_0000000d");
    CHECK(one.size() == 1 && one[0].kind == TestStepKind::Badge && one[0].ids == v({"itk_0000000d"}),
          "badge with one id");
    CHECK(one[0].text == "badge itk_0000000d" && !one[0].hasReason, "the step text; no reason");
    std::vector<TestActionStep> two = parseTestActions("  badge\titk_0000000d itk_00000010 itk_0000000d ");
    CHECK(two[0].kind == TestStepKind::Badge && two[0].ids == v({"itk_0000000d", "itk_00000010"}),
          "badge with two ids; a repeated id is kept once");
    CHECK(two[0].text == "badge\titk_0000000d itk_00000010 itk_0000000d", "the step text, trimmed");

    CHECK(invalid("badge", "badge needs at least one id"), "badge needs ids");
    CHECK(invalid("badge   ", "at least one id"), "badge with only spaces after it");
    CHECK(invalid("badge itk_0000000d /income/dump/Album", "not a sidecar id: /income/dump/Album"),
          "a path is not an id");
    CHECK(invalid("badge itk_000000", "not a sidecar id"), "too few hex digits");
    CHECK(invalid("badge ITK_0000000D", "not a sidecar id"), "ids are lowercase");
    CHECK(invalid("badge --all", "not a sidecar id"), "no flags");
    CHECK(invalid("badge itk_0000000d reason=x", "only reject"), "badge takes no reason");
    CHECK(invalid("badges itk_0000000d", "unknown step"), "the verb is exactly badge");

    std::vector<TestActionStep> mixed = parseTestActions("badge; badge itk_0000000b; menu itk_0000000b");
    CHECK(mixed.size() == 3 && mixed[0].kind == TestStepKind::Invalid && mixed[1].kind == TestStepKind::Badge &&
              mixed[2].kind == TestStepKind::Menu,
          "an invalid badge step does not stop the others");
}

static void testInvalid() {
    g_context = "invalid";
    CHECK(invalid("wait 31", "at most 30"), "wait over 30");
    CHECK(invalid("wait 0", "more than 0"), "wait 0");
    CHECK(invalid("wait abc", "number"), "wait needs a number");
    CHECK(invalid("wait -1", "number"), "no negative wait");
    CHECK(invalid("wait", "number"), "wait without a number");
    CHECK(invalid("wait 1 2", "number"), "wait with two numbers");
    CHECK(invalid("menu", "at least one id"), "menu needs ids");
    CHECK(invalid("propose", "at least one id"), "propose needs ids");
    CHECK(invalid("propose /income/dump/Some Album", "not a sidecar id"), "paths are not ids");
    CHECK(invalid("approve ITK_0000000D", "not a sidecar id"), "ids are lowercase");
    CHECK(invalid("approve --all", "not a sidecar id"), "no flags");
    CHECK(invalid("frobnicate itk_0000000b", "unknown step"), "unknown verb");
    CHECK(invalid("execute itk_00000010", "unknown step"), "execute is not part of B6");
    CHECK(invalid("approve itk_0000000d reason=x", "only reject"), "only reject takes a reason");
    CHECK(invalid("wait 2 reason=x", "no reason"), "wait takes no reason");

    std::vector<TestActionStep> mixed = parseTestActions("bogus; menu itk_0000000b");
    CHECK(mixed.size() == 2 && mixed[0].kind == TestStepKind::Invalid && mixed[1].kind == TestStepKind::Menu,
          "an invalid step does not stop the others");
}

int main() {
    @autoreleasepool {
        testSteps();
        testBadge();
        testInvalid();
    }
    TEST_MAIN_END();
}
