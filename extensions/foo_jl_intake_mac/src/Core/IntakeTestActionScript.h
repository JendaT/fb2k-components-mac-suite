//
//  IntakeTestActionScript.h
//  foo_jl_intake
//
//  Parser for the hidden acceptance aid foo_jl_intake.test_actions
//  (docs/hidden-options.md; Integration/IntakeTestActions.mm runs it).
//  Temporary: removed with the other acceptance aids before the merge to
//  main.
//
//  Steps are separated by ";". Inside a step, words are separated by
//  spaces or tabs:
//    menu <id...>                        log the menu for those roots
//    propose|approve|reject <id...>      dispatch like the menu item
//    refresh [<id...>]                   (ids are accepted and ignored)
//    ... reason=<text>                   reject only: everything after
//                                        "reason=" to the end of the step,
//                                        trimmed, is the reason
//    wait <seconds>                      0 < seconds <= 30, decimals allowed
//  Empty steps are skipped. Ids must be sidecar ids (isSidecarId); whether
//  they are in the snapshot is the runner's check. A step that does not
//  parse is kept with its error, so the runner logs it and goes on.
//
//  Thread-safety: pure function.
//

#pragma once

#include <string>
#include <vector>

#include "IntakeActionTable.h"

namespace intake {

enum class TestStepKind {
    Invalid,
    Menu,
    Dispatch,
    Wait,
};

struct TestActionStep {
    TestStepKind kind = TestStepKind::Invalid;
    IntakeAction action = IntakeAction::Refresh; // Dispatch
    std::vector<std::string> ids;
    std::string reason;   // Dispatch reject
    bool hasReason = false;
    double seconds = 0;   // Wait
    std::string text;     // the step as written, trimmed (for the log)
    std::string error;    // Invalid: why
};

inline constexpr double kTestActionMaxWait = 30.0;

std::vector<TestActionStep> parseTestActions(const std::string &script);

} // namespace intake
