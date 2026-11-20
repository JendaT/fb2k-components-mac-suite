//
//  IntakeTestActionScript.h
//  foo_jl_intake
//
//  Parser for the hidden acceptance aid foo_jl_intake.test_actions
//  (Integration/IntakeTestActions.mm runs it). Temporary: revived for the
//  B11 in-app run with only the steps that run needs, and removed with the
//  other acceptance aids before the merge to main.
//
//  Steps are separated by ";". Inside a step, words are separated by
//  spaces or tabs:
//    rows <id>                           the active playlist's rows of that
//                                        one root (income or library)
//    swap <id...>                        selects the rows of those roots in
//                                        the active playlist (income paths)
//                                        and runs Swap to library paths on
//                                        them
//    show <id>                           in the active playlist, the
//                                        selection cleared and that one
//                                        root's rows brought on screen
//                                        (focus on its last row, then its
//                                        first)
//    delete-sheet <id...> close=<seconds>
//                                        the real Delete local copy…
//                                        confirmation, ended as Cancel after
//                                        <seconds> (0 < seconds <= 30,
//                                        required); nothing is deleted
//    wait <seconds>                      0 < seconds <= 30, decimals allowed
//  "close=<seconds>" is one word, for delete-sheet only, anywhere among the
//  ids. Empty steps are skipped. Ids must be sidecar ids (isSidecarId); a
//  repeated id is kept once; whether they are in the snapshot is the
//  runner's check. A step that does not parse is kept with its error, so
//  the runner logs it and goes on.
//
//  Thread-safety: pure functions.
//

#pragma once

#include <string>
#include <vector>

namespace intake {

enum class TestStepKind {
    Invalid,
    Rows,         // rows: the active playlist's rows of one root
    Swap,         // swap: select the roots' income rows, then Swap
    Show,         // show: one root's rows on screen, no selection
    DeleteSheet,  // delete-sheet: the real confirmation, closed as Cancel
                  // after closeSeconds
    Wait,
};

struct TestActionStep {
    TestStepKind kind = TestStepKind::Invalid;
    std::vector<std::string> ids;
    double seconds = 0;       // Wait
    double closeSeconds = 0;  // DeleteSheet
    std::string text;         // the step as written, trimmed (for the log)
    std::string error;        // Invalid: why
};

inline constexpr double kTestActionMaxWait = 30.0;

std::vector<TestActionStep> parseTestActions(const std::string &script);

} // namespace intake
