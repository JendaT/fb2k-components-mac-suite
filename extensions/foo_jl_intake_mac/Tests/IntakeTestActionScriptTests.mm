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

static void testAssignSteps() {
    g_context = "assign-steps";
    std::vector<TestActionStep> a = parseTestActions("assign itk_0000000e collection=Test & Ambient");
    CHECK(a.size() == 1 && a[0].kind == TestStepKind::Dispatch && a[0].action == IntakeAction::AssignTo,
          "assign is a dispatch of Assign to X");
    CHECK(a[0].ids == v({"itk_0000000e"}) && a[0].hasCollection && a[0].collection == "Test & Ambient",
          "assign: one id, the collection with its spaces");
    CHECK(a[0].text == "assign itk_0000000e collection=Test & Ambient" && !a[0].hasReason, "text kept; no reason");
    std::vector<TestActionStep> spaced = parseTestActions("  assign\titk_0000000d   collection=   Test Collection B  ");
    CHECK(spaced[0].kind == TestStepKind::Dispatch && spaced[0].collection == "Test Collection B",
          "collection= trimmed on both sides");
    std::vector<TestActionStep> odd = parseTestActions("assign itk_0000000d collection=[A] reason=x; menu itk_0000000d");
    CHECK(odd.size() == 2 && odd[0].kind == TestStepKind::Dispatch && odd[0].collection == "[A] reason=x" &&
              !odd[0].hasReason,
          "collection= first takes the rest, reason= included; ';' still ends the step");
    CHECK(odd[1].kind == TestStepKind::Menu, "the next step parses");

    std::vector<TestActionStep> o = parseTestActions("assign-other itk_0000000e itk_0000000d collection=Test Collection C");
    CHECK(o.size() == 1 && o[0].kind == TestStepKind::AssignOther && o[0].action == IntakeAction::AssignOther,
          "assign-other is its own kind");
    CHECK(o[0].ids == v({"itk_0000000e", "itk_0000000d"}) && o[0].collection == "Test Collection C",
          "assign-other: several ids and the collection");
    CHECK(parseTestActions("assign-other itk_0000000e itk_0000000e collection=X")[0].ids == v({"itk_0000000e"}),
          "a repeated id is kept once");

    std::vector<TestActionStep> p = parseTestActions("picker itk_0000000e close=8");
    CHECK(p.size() == 1 && p[0].kind == TestStepKind::Picker && p[0].action == IntakeAction::AssignOther,
          "picker is its own kind");
    CHECK(p[0].ids == v({"itk_0000000e"}) && p[0].closeSeconds == 8 && !p[0].hasCollection, "picker: close=8");
    std::vector<TestActionStep> p2 = parseTestActions("picker close=2.5 itk_0000000e itk_0000000d");
    CHECK(p2[0].kind == TestStepKind::Picker && p2[0].closeSeconds == 2.5 &&
              p2[0].ids == v({"itk_0000000e", "itk_0000000d"}),
          "close= may stand anywhere among the ids; decimals allowed");
    CHECK(parseTestActions("picker itk_0000000e close=30")[0].kind == TestStepKind::Picker, "close=30 is the limit");
    CHECK(parseTestActions("propose itk_0000000b collectionx=1")[0].kind == TestStepKind::Invalid,
          "collection= only at the start of a word (collectionx=1 is not an id)");
}

static void testAssignInvalid() {
    g_context = "assign-invalid";
    CHECK(invalid("assign itk_0000000e", "assign needs collection=<name>"), "assign needs a collection");
    CHECK(invalid("assign itk_0000000e collection=", "collection= needs a name"), "empty collection");
    CHECK(invalid("assign itk_0000000e collection=   ", "collection= needs a name"), "blank collection");
    CHECK(invalid("assign collection=Test Collection A", "needs at least one id"), "assign needs an id");
    CHECK(invalid("assign itk_0000000e itk_0000000d collection=Test Collection A", "exactly one id"),
          "quick assign is for one root");
    CHECK(invalid("assign /income/dump/Album collection=X", "not a sidecar id"), "paths are not ids");
    CHECK(invalid("assign itk_0000000e reason=x", "only reject"), "assign takes no reason");
    CHECK(invalid("assign-other itk_0000000e", "assign-other needs collection=<name>"),
          "assign-other needs a collection");
    CHECK(invalid("assign-other collection=X", "needs at least one id"), "assign-other needs an id");
    CHECK(invalid("assign-other --all collection=X", "not a sidecar id"), "no flags");
    CHECK(invalid("picker itk_0000000e", "picker needs close=<seconds>"), "picker needs close=");
    CHECK(invalid("picker itk_0000000e close=0", "more than 0"), "close=0");
    CHECK(invalid("picker itk_0000000e close=31", "at most 30"), "close over 30");
    CHECK(invalid("picker itk_0000000e close=abc", "close needs one number"), "close needs a number");
    CHECK(invalid("picker itk_0000000e close=", "close needs one number"), "close= without a value");
    CHECK(invalid("picker itk_0000000e close=-1", "close needs one number"), "no negative close");
    CHECK(invalid("picker itk_0000000e close=1 close=2", "twice"), "close= once");
    CHECK(invalid("picker close=5", "needs at least one id"), "picker needs an id");
    CHECK(invalid("picker itk_0000000e close=5 collection=X", "only assign and assign-other"),
          "picker takes no collection");
    CHECK(invalid("menu itk_0000000e collection=X", "only assign and assign-other"), "menu takes no collection");
    CHECK(invalid("reject itk_0000000e collection=X", "only assign and assign-other"), "reject takes no collection");
    CHECK(invalid("menu itk_0000000e close=5", "only picker takes close="), "close= only for picker");
    CHECK(invalid("assign-other itk_0000000e close=5 collection=X", "only picker takes close="),
          "assign-other takes no close=");
    CHECK(invalid("wait 2 collection=X", "wait takes no collection"), "wait takes no collection");
    CHECK(invalid("wait close=2", "only picker takes close="), "wait takes no close=");
    CHECK(invalid("assign-others itk_0000000e collection=X", "unknown step"), "the verb is exact");
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
        testAssignSteps();
        testAssignInvalid();
        testInvalid();
    }
    TEST_MAIN_END();
}
