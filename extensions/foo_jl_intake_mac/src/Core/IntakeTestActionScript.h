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
//    execute <id...>                     B8: Execute placement… with the
//                                        real dry run, no sheet: logs what
//                                        the sheet would list, confirms
//                                        and starts the detached run
//    execute-sheet <id...> close=<seconds>
//                                        B8: the real dry run and the real
//                                        sheet, ended as Cancel after
//                                        <seconds> (0 < seconds <= 30,
//                                        required); nothing is executed
//    resume <id...>                      B8: Resume placement
//    runs                                B8: the tracked runs and the lane
//    swap <id...>                        B9: selects the rows of those roots
//                                        in the active playlist (income
//                                        paths) and runs Swap to library
//                                        paths on them
//    rows <id>                           B9: the active playlist's rows of
//                                        that one root (income or library)
//    delete <id...>                      B9: Delete local copy…, the
//                                        confirmation answered "Delete"
//    delete-swap <id...>                 B9: the same, answered "Swap, then
//                                        delete"
//    delete-sheet <id...> close=<seconds>
//                                        B9: the real confirmation, ended as
//                                        Cancel after <seconds> (0 < seconds
//                                        <= 30, required); nothing deleted
//    show <id>                           B10: in the active playlist, the
//                                        selection cleared and that one
//                                        root's rows brought on screen
//                                        (focus on its last row, then its
//                                        first)
//    tint <slot> <value>                 B10: writes a row colour as the
//                                        preferences page does. <slot>:
//                                        new, review, proposed, approved,
//                                        placed or rejected (the tintKey
//                                        names without "tint_"). <value>:
//                                        0xRRGGBBAA (1 to 8 hex digits,
//                                        any case, not 0), off (writes 0)
//                                        or default (deletes the key)
//    sweep <rows> [delay=<ms>]           B10, temporary: the active
//                                        playlist's focus moved to 0, <rows>,
//                                        2*<rows>, ..., the last row, then
//                                        back to 0, one move every <ms>
//                                        (sweepPositions). <rows>: a whole
//                                        number, 1 to 1000. <ms>: a whole
//                                        number, 20 to 1000, default 100.
//                                        No ids
//    wait <seconds>                      0 < seconds <= 30, decimals allowed
//  "reason=" and "collection=" count only at the start of a word; the first
//  one in the step takes the rest of it (so a collection name may contain
//  "reason=", and the other way round). "close=<seconds>" is one word, for
//  picker, execute-sheet and delete-sheet only; "delay=<ms>" is one word,
//  for sweep only.
//  Empty steps are skipped. Ids must be sidecar ids (isSidecarId); whether
//  they are in the snapshot is the runner's check. A step that does not
//  parse is kept with its error, so the runner logs it and goes on.
//
//  Thread-safety: pure functions.
//

#pragma once

#include <cstddef>
#include <string>
#include <vector>

#include "IntakeActionTable.h"
#include "IntakeTint.h"

namespace intake {

enum class TestStepKind {
    Invalid,
    Menu,
    Badge,
    Dispatch,     // propose, approve, reject, refresh, assign (AssignTo)
    AssignOther,  // assign-other: the picker flow without the sheet
    Picker,       // picker: the real sheet, closed after closeSeconds
    Execute,      // execute: the dry run, no sheet, confirmed (B8)
    ExecuteSheet, // execute-sheet: the dry run and the real sheet, closed
                  // as Cancel after closeSeconds (B8)
    Resume,       // resume (B8)
    Runs,         // runs (B8)
    Swap,         // swap (B9): select the roots' income rows, then Swap
    Rows,         // rows (B9): the active playlist's rows of one root
    Delete,       // delete (B9): the confirmation answered "Delete"
    DeleteSwap,   // delete-swap (B9): answered "Swap, then delete"
    DeleteSheet,  // delete-sheet (B9): the real confirmation, closed as
                  // Cancel after closeSeconds
    Show,         // show (B10): one root's rows on screen, no selection
    Tint,         // tint (B10): write one tint_* key, then notify
    Sweep,        // sweep (B10, temporary): the focus stepped through the
                  // active playlist and back to row 0
    Wait,
};

// What a tint step writes.
enum class TestTintValue {
    Colour,   // tintRgba
    Off,      // 0: no tint
    Default,  // the key deleted
};

struct TestActionStep {
    TestStepKind kind = TestStepKind::Invalid;
    IntakeAction action = IntakeAction::Refresh; // Dispatch; AssignOther for
                                                 // assign-other and picker;
                                                 // Execute for execute and
                                                 // execute-sheet; Resume;
                                                 // Swap; DeleteLocal for
                                                 // delete, delete-swap and
                                                 // delete-sheet
    std::vector<std::string> ids;
    std::string reason;   // Dispatch reject
    bool hasReason = false;
    std::string collection;  // assign, assign-other
    bool hasCollection = false;
    double seconds = 0;   // Wait
    double closeSeconds = 0;  // Picker, ExecuteSheet, DeleteSheet
    TintSlot tintSlot = TintSlot::New;               // Tint
    TestTintValue tintValue = TestTintValue::Colour; // Tint
    IntakeRgba tintRgba = 0;  // Tint with Colour: 1..kTintSettingMax
    int sweepRows = 0;        // Sweep: 1..kTestSweepMaxRows
    int sweepDelayMs = 0;     // Sweep: kTestSweepMinDelayMs..kTestSweepMaxDelayMs
    std::string text;     // the step as written, trimmed (for the log)
    std::string error;    // Invalid: why
};

inline constexpr double kTestActionMaxWait = 30.0;

inline constexpr int kTestSweepMaxRows = 1000;
inline constexpr int kTestSweepMinDelayMs = 20;
inline constexpr int kTestSweepMaxDelayMs = 1000;
inline constexpr int kTestSweepDefaultDelayMs = 100;

std::vector<TestActionStep> parseTestActions(const std::string &script);

// The focus positions of a sweep over `count` rows: 0, step, 2*step, ...
// below count, then count - 1 unless it is already the last one, then 0 as
// the final move. Two consecutive positions are never equal (a focus set to
// the index it already has does nothing), so 1 row gives {0}. Empty for
// count 0 or step 0.
std::vector<size_t> sweepPositions(size_t count, size_t step);

} // namespace intake
