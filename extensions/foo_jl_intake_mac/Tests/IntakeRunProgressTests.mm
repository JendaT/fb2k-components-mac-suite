//
//  IntakeRunProgressTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeRunProgress (the status bar's n/m of an execute or
//  resume run, B14) over hand-written views: a clean walk (placing, then
//  placed, root after root), a revert to approved, a root stuck placing while
//  the run goes on, views that coalesce several writes, resume (no placing,
//  no current), roots a view does not list, an adopted run seeded half done,
//  repeats in the id list.
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeRunProgress.h"
#include "TestHarness.h"

#include <map>
#include <string>

using namespace intake;

using View = std::map<std::string, IntakeStatus>;

static RunStatusLookup lookupIn(const View &view) {
    return [&view](const std::string &id, IntakeStatus &status) {
        auto it = view.find(id);
        if (it == view.end()) return false;
        status = it->second;
        return true;
    };
}

static const IntakeStatus A = IntakeStatus::Approved;
static const IntakeStatus P = IntakeStatus::Placing;
static const IntakeStatus D = IntakeStatus::Placed;

static void testCleanWalk() {
    g_context = "clean-walk";
    View v = {{"a", A}, {"b", A}, {"c", A}};
    RunProgress run;
    run.start({"a", "b", "c"}, false, lookupIn(v));
    CHECK(run.total() == 3 && run.done() == 0 && run.current().empty(), "seeded: 0/3, nothing placing");
    CHECK(!run.update(lookupIn(v)), "the same view: no change");
    v["a"] = P;
    CHECK(run.update(lookupIn(v)), "a goes placing");
    CHECK(run.done() == 0 && run.current() == "a", "0/3, a placing");
    v["a"] = D;
    v["b"] = P;
    CHECK(run.update(lookupIn(v)), "a placed, b placing");
    CHECK(run.done() == 1 && run.current() == "b", "1/3, b placing");
    CHECK(!run.update(lookupIn(v)), "an unrelated publish: no change");
    v["b"] = D;
    CHECK(run.update(lookupIn(v)), "b placed, c not yet");
    CHECK(run.done() == 2 && run.current().empty(), "2/3, nothing placing (b is no longer)");
    v["c"] = P;
    CHECK(run.update(lookupIn(v)) && run.current() == "c", "c placing");
    v["c"] = D;
    CHECK(run.update(lookupIn(v)) && run.done() == 3 && run.current().empty(), "3/3");
}

static void testRevert() {
    g_context = "revert";
    View v = {{"a", A}, {"b", A}};
    RunProgress run;
    run.start({"a", "b"}, false, lookupIn(v));
    v["a"] = P;
    run.update(lookupIn(v));
    v["a"] = A;  // the copy failed before the commit point: execute_failed
    CHECK(run.update(lookupIn(v)), "a reverted: a change");
    CHECK(run.done() == 0 && run.current().empty(), "0/2, nothing placing");
    v["b"] = P;
    CHECK(run.update(lookupIn(v)) && run.current() == "b", "the run goes on with b");
    v["b"] = D;
    CHECK(run.update(lookupIn(v)) && run.done() == 1, "1/2: the reverted root never counts");
}

static void testStuckPlacing() {
    g_context = "stuck";
    View v = {{"a", A}, {"b", A}, {"c", A}};
    RunProgress run;
    run.start({"a", "b", "c"}, false, lookupIn(v));
    v["a"] = P;
    run.update(lookupIn(v));
    CHECK(run.current() == "a", "a placing");
    // a stays placing (bookkeeping failed after the commit point), b starts.
    v["b"] = P;
    CHECK(run.update(lookupIn(v)) && run.current() == "b", "b placing: the newer root is current");
    v["b"] = D;
    CHECK(run.update(lookupIn(v)), "b placed");
    CHECK(run.done() == 1 && run.current().empty(), "1/3; stuck a is never current again");
    v["c"] = P;
    CHECK(run.update(lookupIn(v)) && run.current() == "c", "c placing");
    // Both stuck a and new c seen placing in one view after a restart of
    // the tracker: the later one in the run's order is current.
    RunProgress again;
    View w = {{"a", A}, {"b", D}, {"c", A}};
    again.start({"a", "b", "c"}, false, lookupIn(w));
    w["a"] = P;
    w["c"] = P;
    CHECK(again.update(lookupIn(w)) && again.current() == "c", "two newly placing: the later one");
}

static void testCoalesced() {
    g_context = "coalesced";
    View v = {{"a", A}, {"b", A}, {"c", A}};
    RunProgress run;
    run.start({"a", "b", "c"}, false, lookupIn(v));
    // The watcher's debounce folds a's placing and placed and b's placing
    // into one reload.
    v["a"] = D;
    v["b"] = P;
    CHECK(run.update(lookupIn(v)), "one view for three writes");
    CHECK(run.done() == 1 && run.current() == "b", "1/3, b placing");
    // And a whole root in one view: c from approved straight to placed.
    v["b"] = D;
    v["c"] = D;
    CHECK(run.update(lookupIn(v)) && run.done() == 3 && run.current().empty(), "3/3, never saw c placing");
}

static void testResume() {
    g_context = "resume";
    View v = {{"p", P}, {"q", P}, {"r", P}};
    RunProgress run;
    run.start({"p", "q", "r"}, true, lookupIn(v));
    CHECK(run.total() == 3 && run.done() == 0 && run.current().empty(), "resume: placing roots are not current");
    v["p"] = D;
    CHECK(run.update(lookupIn(v)) && run.done() == 1 && run.current().empty(), "p completed: 1/3, no current");
    v["q"] = A;  // reverted_to_approved
    CHECK(!run.update(lookupIn(v)), "q reverted: done and current unchanged");
    v["r"] = D;
    CHECK(run.update(lookupIn(v)) && run.done() == 2, "r completed: 2/3");
}

static void testMissingRecords() {
    g_context = "missing";
    View v = {{"a", A}, {"b", A}};
    RunProgress run;
    run.start({"a", "b"}, false, lookupIn(v));
    v["a"] = D;
    run.update(lookupIn(v));
    View partial = {{"b", P}};  // a view that does not list a
    CHECK(run.update(lookupIn(partial)), "b placing");
    CHECK(run.done() == 1 && run.current() == "b", "a keeps its last status (placed)");
    View empty;
    CHECK(!run.update(lookupIn(empty)), "an empty view changes nothing");
    CHECK(run.done() == 1 && run.current() == "b", "still 1/2, b placing");

    // Nothing known at the start (no view yet): a later placing is current.
    RunProgress blind;
    blind.start({"a", "b"}, false, lookupIn(empty));
    CHECK(blind.done() == 0 && blind.current().empty(), "no view: 0/2");
    View later = {{"a", P}, {"b", A}};
    CHECK(blind.update(lookupIn(later)) && blind.current() == "a", "first seen placing: current");

    RunProgress noLookup;
    noLookup.start({"a"}, false, RunStatusLookup());
    CHECK(noLookup.total() == 1 && !noLookup.update(RunStatusLookup()), "an empty lookup is harmless");
}

static void testAdoptedSeed() {
    g_context = "adopted";
    View v = {{"a", D}, {"b", D}, {"c", P}, {"d", A}};
    RunProgress run;
    run.start({"a", "b", "c", "d"}, false, lookupIn(v));
    CHECK(run.done() == 2 && run.current() == "c" && run.total() == 4, "half done: 2/4, c placing");
    v["c"] = D;
    v["d"] = P;
    CHECK(run.update(lookupIn(v)) && run.done() == 3 && run.current() == "d", "it goes on: 3/4, d placing");
}

static void testRepeats() {
    g_context = "repeats";
    View v = {{"a", A}, {"b", A}};
    RunProgress run;
    run.start({"a", "b", "a"}, false, lookupIn(v));
    CHECK(run.total() == 2, "a repeat counts once");
    v["a"] = D;
    v["b"] = D;
    CHECK(run.update(lookupIn(v)) && run.done() == 2, "2/2, not 3/2");
}

int main(void) {
    @autoreleasepool {
        testCleanWalk();
        testRevert();
        testStuckPlacing();
        testCoalesced();
        testResume();
        testMissingRecords();
        testAdoptedSeed();
        testRepeats();
    }
    TEST_MAIN_END();
}
