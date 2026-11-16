//
//  IntakeTestActionScriptTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeTestActionScript, the parser of the temporary
//  foo_jl_intake.test_actions acceptance aid (removed with it before the
//  merge to main).
//
// TEST_DEPS: src/Core/IntakeCommandArgs.mm src/Core/IntakeSemver.mm src/Core/IntakeSettingsParse.mm src/Core/IntakeTint.mm
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
    CHECK(invalid("menu itk_0000000e close=5", "only picker, execute-sheet and delete-sheet take close="),
          "close= only for picker, execute-sheet and delete-sheet");
    CHECK(invalid("assign-other itk_0000000e close=5 collection=X",
                  "only picker, execute-sheet and delete-sheet take close="),
          "assign-other takes no close=");
    CHECK(invalid("wait 2 collection=X", "wait takes no collection"), "wait takes no collection");
    CHECK(invalid("wait close=2", "only picker, execute-sheet and delete-sheet take close="), "wait takes no close=");
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
    CHECK(invalid("place itk_00000010", "unknown step"), "an unknown verb near execute");
    CHECK(invalid("approve itk_0000000d reason=x", "only reject"), "only reject takes a reason");
    CHECK(invalid("wait 2 reason=x", "no reason"), "wait takes no reason");

    std::vector<TestActionStep> mixed = parseTestActions("bogus; menu itk_0000000b");
    CHECK(mixed.size() == 2 && mixed[0].kind == TestStepKind::Invalid && mixed[1].kind == TestStepKind::Menu,
          "an invalid step does not stop the others");
}

static void testExecuteSteps() {
    g_context = "execute-steps";
    std::vector<TestActionStep> s = parseTestActions(
        "execute itk_00000010; execute-sheet itk_00000010 itk_0000000d close=8; resume itk_00000011; runs;"
        "execute-sheet itk_00000010 close=0.5");
    CHECK(s.size() == 5, "five steps");
    CHECK(s[0].kind == TestStepKind::Execute && s[0].action == IntakeAction::Execute &&
              s[0].ids == v({"itk_00000010"}) && s[0].closeSeconds == 0,
          "execute <id>: the headless flow");
    CHECK(s[1].kind == TestStepKind::ExecuteSheet && s[1].action == IntakeAction::Execute &&
              s[1].ids == v({"itk_00000010", "itk_0000000d"}) && s[1].closeSeconds == 8,
          "execute-sheet <ids> close=8");
    CHECK(s[2].kind == TestStepKind::Resume && s[2].action == IntakeAction::Resume && s[2].ids == v({"itk_00000011"}),
          "resume <id>");
    CHECK(s[3].kind == TestStepKind::Runs && s[3].ids.empty() && s[3].text == "runs", "runs");
    CHECK(s[4].kind == TestStepKind::ExecuteSheet && s[4].closeSeconds == 0.5, "decimals for close");
    CHECK(parseTestActions("execute itk_00000010 itk_00000010")[0].ids == v({"itk_00000010"}), "an id once");

    CHECK(invalid("execute", "at least one id"), "execute needs ids");
    CHECK(invalid("resume", "at least one id"), "resume needs ids");
    CHECK(invalid("execute-sheet close=5", "at least one id"), "execute-sheet needs ids");
    CHECK(invalid("execute-sheet itk_00000010", "needs close="), "execute-sheet needs close=");
    CHECK(invalid("execute-sheet itk_00000010 close=31", "at most 30"), "close over 30");
    CHECK(invalid("execute-sheet itk_00000010 close=0", "more than 0"), "close 0");
    CHECK(invalid("execute-sheet itk_00000010 close=x", "number"), "close needs a number");
    CHECK(invalid("execute itk_00000010 close=3", "only picker, execute-sheet and delete-sheet"),
          "execute takes no close=");
    CHECK(invalid("resume itk_00000011 close=3", "only picker, execute-sheet and delete-sheet"),
          "resume takes no close=");
    CHECK(invalid("runs itk_00000010", "no ids"), "runs takes no ids");
    CHECK(invalid("runs reason=x", "no reason"), "runs takes no reason");
    CHECK(invalid("runs collection=X", "no collection"), "runs takes no collection");
    CHECK(invalid("execute itk_00000010 reason=x", "only reject"), "execute takes no reason");
    CHECK(invalid("resume itk_00000011 collection=X", "only assign"), "resume takes no collection");
    CHECK(invalid("execute /income/dump/Approved", "not a sidecar id"), "execute takes ids only");
    CHECK(parseTestActions("picker itk_0000000e close=8")[0].kind == TestStepKind::Picker, "picker keeps close=");
}

static void testLibrarySteps() {
    g_context = "library-steps";
    std::vector<TestActionStep> s = parseTestActions(
        "rows itk_00000012; swap itk_00000012 itk_00000011 itk_00000012; delete itk_00000012; "
        "delete-swap itk_00000012; delete-sheet itk_00000012 itk_00000011 close=8; delete-sheet itk_00000012 close=0.5");
    CHECK(s.size() == 6, "six steps");
    CHECK(s[0].kind == TestStepKind::Rows && s[0].ids == v({"itk_00000012"}) && s[0].text == "rows itk_00000012",
          "rows <id>");
    CHECK(s[1].kind == TestStepKind::Swap && s[1].action == IntakeAction::Swap &&
              s[1].ids == v({"itk_00000012", "itk_00000011"}),
          "swap <ids>: an id once");
    CHECK(s[2].kind == TestStepKind::Delete && s[2].action == IntakeAction::DeleteLocal && s[2].ids == v({"itk_00000012"}) &&
              s[2].closeSeconds == 0,
          "delete <id>: answered Delete");
    CHECK(s[3].kind == TestStepKind::DeleteSwap && s[3].action == IntakeAction::DeleteLocal,
          "delete-swap <id>: answered Swap, then delete");
    CHECK(s[4].kind == TestStepKind::DeleteSheet && s[4].action == IntakeAction::DeleteLocal &&
              s[4].ids == v({"itk_00000012", "itk_00000011"}) && s[4].closeSeconds == 8,
          "delete-sheet <ids> close=8");
    CHECK(s[5].kind == TestStepKind::DeleteSheet && s[5].closeSeconds == 0.5, "decimals for close");

    CHECK(invalid("rows", "exactly one id"), "rows needs an id");
    CHECK(invalid("rows itk_00000012 itk_00000011", "exactly one id"), "rows takes one id");
    CHECK(invalid("rows /income/dump/Placed", "not a sidecar id"), "rows takes an id, not a path");
    CHECK(invalid("swap", "at least one id"), "swap needs ids");
    CHECK(invalid("delete", "at least one id"), "delete needs ids");
    CHECK(invalid("delete-swap", "at least one id"), "delete-swap needs ids");
    CHECK(invalid("delete-sheet itk_00000012", "needs close="), "delete-sheet needs close=");
    CHECK(invalid("delete-sheet itk_00000012 close=31", "at most 30"), "close over 30");
    CHECK(invalid("delete-sheet itk_00000012 close=0", "more than 0"), "close 0");
    CHECK(invalid("delete itk_00000012 close=3", "only picker, execute-sheet and delete-sheet"), "delete takes no close=");
    CHECK(invalid("swap itk_00000012 close=3", "only picker, execute-sheet and delete-sheet"), "swap takes no close=");
    CHECK(invalid("delete itk_00000012 reason=x", "only reject"), "delete takes no reason");
    CHECK(invalid("swap itk_00000012 collection=X", "only assign"), "swap takes no collection");
    CHECK(invalid("rows itk_00000012 reason=x", "only reject"), "rows takes no reason");
    CHECK(invalid("delete --all", "not a sidecar id"), "no flags: never an all-roots form");
    CHECK(invalid("gc itk_00000012", "unknown step"), "gc is not a step (delete is)");
    CHECK(invalid("delete-local itk_00000012", "unknown step"), "the verb is exact");
}

static void testShowSteps() {
    g_context = "show-steps";
    std::vector<TestActionStep> s = parseTestActions("show itk_00000012; show\titk_00000011 itk_00000011");
    CHECK(s.size() == 2, "two steps");
    CHECK(s[0].kind == TestStepKind::Show && s[0].ids == v({"itk_00000012"}) && s[0].text == "show itk_00000012",
          "show <id>");
    CHECK(s[1].kind == TestStepKind::Show && s[1].ids == v({"itk_00000011"}), "show: a repeated id is one id");

    CHECK(invalid("show", "show takes exactly one id"), "show needs an id");
    CHECK(invalid("show itk_00000012 itk_00000011", "show takes exactly one id"), "show takes one id");
    CHECK(invalid("show /income/dump/Placed", "not a sidecar id"), "show takes an id, not a path");
    CHECK(invalid("show itk_00000012 reason=x", "only reject"), "show takes no reason");
    CHECK(invalid("show itk_00000012 collection=X", "only assign"), "show takes no collection");
    CHECK(invalid("show itk_00000012 close=3", "only picker, execute-sheet and delete-sheet"), "show takes no close=");
    CHECK(invalid("shows itk_00000012", "unknown step"), "the verb is exact");
}

static void testTintSteps() {
    g_context = "tint-steps";
    std::vector<TestActionStep> s = parseTestActions(
        "tint placed 0xFF00FFFF; tint new 0x4a90d938; tint review 0X1; tint proposed off; tint approved default;"
        "tint rejected 0xffffffff");
    CHECK(s.size() == 6, "six steps");
    CHECK(s[0].kind == TestStepKind::Tint && s[0].tintSlot == TintSlot::Placed &&
              s[0].tintValue == TestTintValue::Colour && s[0].tintRgba == 0xFF00FFFFu,
          "tint placed 0xFF00FFFF");
    CHECK(s[0].text == "tint placed 0xFF00FFFF" && s[0].ids.empty(), "the step text; no ids");
    CHECK(s[1].tintSlot == TintSlot::New && s[1].tintValue == TestTintValue::Colour && s[1].tintRgba == 0x4A90D938u,
          "lower-case hex digits");
    CHECK(s[2].tintSlot == TintSlot::Review && s[2].tintValue == TestTintValue::Colour && s[2].tintRgba == 1u,
          "one digit, 0X prefix");
    CHECK(s[3].kind == TestStepKind::Tint && s[3].tintSlot == TintSlot::Proposed && s[3].tintValue == TestTintValue::Off,
          "off");
    CHECK(s[4].kind == TestStepKind::Tint && s[4].tintSlot == TintSlot::Approved &&
              s[4].tintValue == TestTintValue::Default,
          "default");
    CHECK(s[5].tintSlot == TintSlot::Rejected && s[5].tintRgba == 0xFFFFFFFFu, "0xffffffff is the largest colour");
    CHECK(parseTestActions("  tint\tplaced   0x0000FF00  ")[0].tintRgba == 0x0000FF00u, "tabs and spaces; leading zeros");

    bool everySlot = true;
    for (TintSlot slot : kTintSlots) {
        std::vector<TestActionStep> one = parseTestActions(std::string("tint ") + (tintKey(slot) + 5) + " off");
        everySlot = everySlot && one.size() == 1 && one[0].kind == TestStepKind::Tint && one[0].tintSlot == slot;
    }
    CHECK(everySlot, "every slot by its tintKey name without tint_");
}

static void testTintInvalid() {
    g_context = "tint-invalid";
    CHECK(invalid("tint", "tint needs a slot and a value"), "tint needs words");
    CHECK(invalid("tint placed", "tint needs a slot and a value"), "tint needs a value");
    CHECK(invalid("tint placed off now", "only a slot and a value"), "an extra word");
    CHECK(invalid("tint blue 0xFF00FFFF", "unknown tint slot \"blue\""), "unknown slot");
    CHECK(invalid("tint tint_placed 0xFF00FFFF", "unknown tint slot"), "the slot is without tint_");
    CHECK(invalid("tint Placed 0xFF00FFFF", "unknown tint slot"), "slots are lowercase");
    CHECK(invalid("tint placed 0x0", "is 0: use off"), "0x0 points at off");
    CHECK(invalid("tint placed 0x00000000", "is 0: use off"), "0x00000000 points at off");
    CHECK(invalid("tint placed 0x123456789", "more than 8 hex digits"), "nine digits");
    CHECK(invalid("tint placed 0x000000001", "more than 8 hex digits"), "nine digits, even with leading zeros");
    CHECK(invalid("tint placed 0x", "needs 1 to 8 hex digits"), "0x without digits");
    CHECK(invalid("tint placed 0xFF00FFGG", "is not hex"), "a digit that is not hex");
    CHECK(invalid("tint placed 0x-1", "is not hex"), "no sign");
    CHECK(invalid("tint placed FF00FFFF", "must be 0xRRGGBBAA, off or default"), "hex needs 0x");
    CHECK(invalid("tint placed red", "must be 0xRRGGBBAA, off or default"), "a word that is not hex");
    CHECK(invalid("tint placed 4278255615", "must be 0xRRGGBBAA, off or default"), "no decimal");
    CHECK(invalid("tint placed OFF", "must be 0xRRGGBBAA, off or default"), "off is lowercase");
    CHECK(invalid("tint placed off reason=x", "tint takes no reason"), "tint takes no reason");
    CHECK(invalid("tint placed off collection=X", "tint takes no collection"), "tint takes no collection");
    CHECK(invalid("tint placed off close=3", "only picker, execute-sheet and delete-sheet"), "tint takes no close=");
    CHECK(invalid("tints placed off", "unknown step"), "the verb is exact");

    std::vector<TestActionStep> mixed = parseTestActions("tint placed 0x0; tint placed off");
    CHECK(mixed.size() == 2 && mixed[0].kind == TestStepKind::Invalid && mixed[1].kind == TestStepKind::Tint,
          "an invalid tint step does not stop the others");
}

static void testSweepSteps() {
    g_context = "sweep-steps";
    std::vector<TestActionStep> s =
        parseTestActions("sweep 3; sweep 3 delay=60; sweep 1; sweep 1000 delay=20; sweep\tdelay=1000  25 ; sweep 007");
    CHECK(s.size() == 6, "six steps");
    CHECK(s[0].kind == TestStepKind::Sweep && s[0].sweepRows == 3 && s[0].sweepDelayMs == kTestSweepDefaultDelayMs,
          "sweep 3: the default delay");
    CHECK(kTestSweepDefaultDelayMs == 100, "the default delay is 100 ms");
    CHECK(s[0].text == "sweep 3" && s[0].ids.empty(), "the step text; no ids");
    CHECK(s[1].kind == TestStepKind::Sweep && s[1].sweepRows == 3 && s[1].sweepDelayMs == 60, "sweep 3 delay=60");
    CHECK(s[1].text == "sweep 3 delay=60", "the step text with the delay");
    CHECK(s[2].kind == TestStepKind::Sweep && s[2].sweepRows == 1, "rows 1 is the lower limit");
    CHECK(s[3].kind == TestStepKind::Sweep && s[3].sweepRows == 1000 && s[3].sweepDelayMs == 20,
          "rows 1000 and delay 20 are limits");
    CHECK(s[4].kind == TestStepKind::Sweep && s[4].sweepRows == 25 && s[4].sweepDelayMs == 1000,
          "delay= may come first; delay 1000 is the upper limit; tabs");
    CHECK(s[5].kind == TestStepKind::Sweep && s[5].sweepRows == 7, "leading zeros");
}

static void testSweepInvalid() {
    g_context = "sweep-invalid";
    CHECK(invalid("sweep", "sweep needs a number of rows"), "missing rows");
    CHECK(invalid("sweep delay=50", "sweep needs a number of rows"), "only a delay");
    CHECK(invalid("sweep 0", "from 1 to 1000, not \"0\""), "rows 0");
    CHECK(invalid("sweep 1001", "from 1 to 1000, not \"1001\""), "rows 1001");
    CHECK(invalid("sweep 99999999999999999999", "from 1 to 1000"), "a huge number does not wrap");
    CHECK(invalid("sweep abc", "whole number from 1 to 1000, not \"abc\""), "rows not a number");
    CHECK(invalid("sweep 2.5", "whole number"), "no decimal rows");
    CHECK(invalid("sweep -3", "whole number"), "no negative rows");
    CHECK(invalid("sweep 3 delay=19", "delay must be a whole number of ms from 20 to 1000, not \"19\""),
          "delay below 20");
    CHECK(invalid("sweep 3 delay=1001", "from 20 to 1000, not \"1001\""), "delay above 1000");
    CHECK(invalid("sweep 3 delay=", "delay= needs a whole number of ms"), "delay= without a value");
    CHECK(invalid("sweep 3 delay=fast", "delay must be a whole number"), "delay not a number");
    CHECK(invalid("sweep 3 delay=60.5", "delay must be a whole number"), "no decimal delay");
    CHECK(invalid("sweep 3 delay=60ms", "delay must be a whole number"), "no unit");
    CHECK(invalid("sweep 3 delay=60 delay=80", "delay= given twice"), "delay= once");
    CHECK(invalid("sweep 3 4", "sweep takes only a number of rows and delay=<ms>"), "an extra word");
    CHECK(invalid("sweep 3 Delay=60", "sweep takes only a number of rows"), "Delay= is not delay=");
    CHECK(invalid("sweep 3 itk_00000012", "sweep takes no ids"), "an id after the rows");
    CHECK(invalid("sweep itk_00000012", "sweep takes no ids"), "an id instead of the rows");
    CHECK(invalid("sweep 3 reason=x", "sweep takes no reason"), "sweep takes no reason");
    CHECK(invalid("sweep 3 collection=X", "sweep takes no collection"), "sweep takes no collection");
    CHECK(invalid("sweep 3 close=5", "only picker, execute-sheet and delete-sheet"), "sweep takes no close=");
    CHECK(invalid("show itk_00000012 delay=50", "only sweep takes delay="), "delay= only for sweep");
    CHECK(invalid("wait 2 delay=50", "only sweep takes delay="), "wait takes no delay=");
    CHECK(invalid("sweeps 3", "unknown step"), "the verb is exact");

    std::vector<TestActionStep> mixed = parseTestActions("sweep 0; sweep 50");
    CHECK(mixed.size() == 2 && mixed[0].kind == TestStepKind::Invalid && mixed[1].kind == TestStepKind::Sweep,
          "an invalid sweep step does not stop the others");
}

static void testSweepPositions() {
    g_context = "sweep-positions";
    CHECK(sweepPositions(1, 3) == std::vector<size_t>({0}), "one row: only 0 (no repeated position)");
    CHECK(sweepPositions(2, 1) == std::vector<size_t>({0, 1, 0}), "two rows, step 1");
    CHECK(sweepPositions(10, 3) == std::vector<size_t>({0, 3, 6, 9, 0}), "the last row reached by a step is kept once");
    CHECK(sweepPositions(11, 3) == std::vector<size_t>({0, 3, 6, 9, 10, 0}), "the last row added after the steps");
    CHECK(sweepPositions(10, 20) == std::vector<size_t>({0, 9, 0}), "a step bigger than the count");
    CHECK(sweepPositions(10, 10) == std::vector<size_t>({0, 9, 0}), "a step equal to the count");
    CHECK(sweepPositions(0, 3).empty(), "no rows: no positions");
    CHECK(sweepPositions(10, 0).empty(), "step 0: no positions");

    const std::vector<size_t> p = sweepPositions(5000, 3);
    // 0, 3, ..., 4998 (1667 positions), then 4999, then 0.
    CHECK_EQ(p.size(), 1669, "5000 rows, step 3: the move count");
    CHECK(p.front() == 0 && p[1] == 3 && p[1666] == 4998, "steps of 3 from 0");
    CHECK(p[p.size() - 2] == 4999, "the last row is visited");
    CHECK(p.back() == 0, "the final move goes back to 0");
    bool increasing = true;
    for (size_t i = 1; i + 1 < p.size(); i++) increasing = increasing && p[i] > p[i - 1];
    CHECK(increasing, "strictly increasing until the final 0");
    size_t lastCount = 0;
    for (size_t pos : p) lastCount += pos == 4999 ? 1 : 0;
    CHECK(lastCount == 1, "the last row once");
    const std::vector<size_t> big = sweepPositions(5000, 1000);
    CHECK(big == std::vector<size_t>({0, 1000, 2000, 3000, 4000, 4999, 0}), "5000 rows, step 1000");
}

int main() {
    @autoreleasepool {
        testSteps();
        testExecuteSteps();
        testLibrarySteps();
        testShowSteps();
        testTintSteps();
        testTintInvalid();
        testSweepSteps();
        testSweepInvalid();
        testSweepPositions();
        testBadge();
        testAssignSteps();
        testAssignInvalid();
        testInvalid();
    }
    TEST_MAIN_END();
}
