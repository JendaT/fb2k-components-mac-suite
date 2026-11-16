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
//    badge <id...>                       log the group badge for those
//                                        roots' rows
//    propose|approve|reject <id...>      dispatch like the menu item
//    refresh [<id...>]                   (ids are accepted and ignored)
//    ... reason=<text>                   reject only: everything after
//                                        "reason=" to the end of the step,
//                                        trimmed, is the reason
//    assign <id> collection=<name>       B7: the quick-assign item "Assign
//                                        to <name>" of that one root
//    assign-other <id...> collection=<name>
//                                        B7: the picker flow without the
//                                        sheet; <name> is the choice
//    ... collection=<name>               assign and assign-other only, and
//                                        required there: everything after
//                                        "collection=" to the end of the
//                                        step, trimmed (names have spaces)
//    picker <id...> close=<seconds>      B7: the real picker sheet, ended
//                                        as Cancel after <seconds>
//                                        (0 < seconds <= 30, required)
//    wait <seconds>                      0 < seconds <= 30, decimals allowed
//  "reason=" and "collection=" count only at the start of a word; the first
//  one in the step takes the rest of it (so a collection name may contain
//  "reason=", and the other way round). "close=<seconds>" is one word.
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
    Badge,
    Dispatch,     // propose, approve, reject, refresh, assign (AssignTo)
    AssignOther,  // assign-other: the picker flow without the sheet
    Picker,       // picker: the real sheet, closed after closeSeconds
    Wait,
};

struct TestActionStep {
    TestStepKind kind = TestStepKind::Invalid;
    IntakeAction action = IntakeAction::Refresh; // Dispatch; AssignOther for
                                                 // assign-other and picker
    std::vector<std::string> ids;
    std::string reason;   // Dispatch reject
    bool hasReason = false;
    std::string collection;  // assign, assign-other
    bool hasCollection = false;
    double seconds = 0;   // Wait
    double closeSeconds = 0;  // Picker
    std::string text;     // the step as written, trimmed (for the log)
    std::string error;    // Invalid: why
};

inline constexpr double kTestActionMaxWait = 30.0;

std::vector<TestActionStep> parseTestActions(const std::string &script);

} // namespace intake
