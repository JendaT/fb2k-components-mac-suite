//
//  SubgroupDetectorTests.mm
//  foo_simplaylist_mac
//
//  Unit tests for SubgroupDetector (disc-header emission state machine).
//  Compiled standalone (Foundation only); gating phase of Scripts/build.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Core/SubgroupDetector.h"
#import "TestHarness.h"

#include <string>

// Assert the emitted (index, header) pairs so far.
static void checkEmitted(NSArray<NSNumber *> *starts, NSArray<NSString *> *headers,
                         NSArray<NSNumber *> *wantStarts, NSArray<NSString *> *wantHeaders,
                         const char *what) {
    g_checks++;
    if (![starts isEqualToArray:wantStarts] || ![headers isEqualToArray:wantHeaders]) {
        g_failures++;
        printf("FAIL [%s] %s: got %s/%s, expected %s/%s\n", g_context.c_str(), what,
               starts.description.UTF8String, headers.description.UTF8String,
               wantStarts.description.UTF8String, wantHeaders.description.UTF8String);
    }
}

int main(void) {
    @autoreleasepool {

    // --- showFirst=ON: first subgroup emitted only at the group's first track ---
    {
        g_context = "showFirst-on";
        SubgroupDetector d(true);
        NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
        NSMutableArray<NSString *> *headers = [NSMutableArray array];

        d.enterNewGroup();
        CHECK(d.shouldAddSubgroup("Disc 1", true, starts, headers, 0), "first at group start emits");
        CHECK(!d.shouldAddSubgroup("Disc 1", false, starts, headers, 1), "same value skipped");
        CHECK(d.shouldAddSubgroup("Disc 2", false, starts, headers, 2), "disc change emits");
        checkEmitted(starts, headers, @[@0, @2], @[@"Disc 1", @"Disc 2"], "two headers total");

        // New group: state resets, first subgroup NOT on first track -> suppressed
        d.enterNewGroup();
        CHECK(!d.shouldAddSubgroup("Disc 1", false, starts, headers, 5),
              "first subgroup mid-group suppressed");
        CHECK(d.shouldAddSubgroup("Disc 2", false, starts, headers, 6),
              "but a change after it still emits");
    }

    // --- showFirst=OFF: first subgroup never emitted, changes still are ---
    {
        g_context = "showFirst-off";
        SubgroupDetector d(false);
        NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
        NSMutableArray<NSString *> *headers = [NSMutableArray array];

        d.enterNewGroup();
        CHECK(!d.shouldAddSubgroup("Disc 1", true, starts, headers, 0),
              "first at group start suppressed with showFirst=OFF");
        CHECK(d.shouldAddSubgroup("Disc 2", false, starts, headers, 3), "disc change emits");
        checkEmitted(starts, headers, @[@3], @[@"Disc 2"], "only the change emitted");
    }

    // --- Empty values: skipped AND do not update tracking state ---
    {
        g_context = "empty-values";
        SubgroupDetector d(true);
        NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
        NSMutableArray<NSString *> *headers = [NSMutableArray array];

        d.enterNewGroup();
        CHECK(!d.shouldAddSubgroup("", true, starts, headers, 0), "empty skipped");
        CHECK(std::string(d.getCurrentSubgroup()).empty(), "empty does not update state");
        // First non-empty appears on track 1 (not group start) -> suppressed,
        // matching the original semantics for albums whose disc tag starts late.
        CHECK(!d.shouldAddSubgroup("Disc 1", false, starts, headers, 1),
              "first non-empty mid-group suppressed");
        CHECK(!d.shouldAddSubgroup("", false, starts, headers, 2), "empty between discs skipped");
        CHECK(std::string(d.getCurrentSubgroup()) == "Disc 1", "state survives empty value");
        CHECK(!d.shouldAddSubgroup("Disc 1", false, starts, headers, 3),
              "same disc after gap not re-emitted");
    }

    // --- Continuation: initFromState carries the sync-portion state ---
    {
        g_context = "continuation";
        SubgroupDetector d(true);
        NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
        NSMutableArray<NSString *> *headers = [NSMutableArray array];

        d.initFromState("Disc 2");
        CHECK(!d.shouldAddSubgroup("Disc 2", false, starts, headers, 100),
              "same value as carried state not re-emitted");
        CHECK(d.shouldAddSubgroup("Disc 3", false, starts, headers, 101),
              "change from carried state emits");
        checkEmitted(starts, headers, @[@101], @[@"Disc 3"], "continuation emission");

        d.initFromState(nullptr);
        CHECK(std::string(d.getCurrentSubgroup()).empty(), "nullptr state treated as empty");
    }

    // --- Invalid UTF-8: emitted header is "", never nil (documented crash fix) ---
    {
        g_context = "invalid-utf8";
        SubgroupDetector d(true);
        NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
        NSMutableArray<NSString *> *headers = [NSMutableArray array];

        d.enterNewGroup();
        CHECK(d.shouldAddSubgroup("\xC3\x28", true, starts, headers, 0),
              "invalid UTF-8 still emits at group start");
        checkEmitted(starts, headers, @[@0], @[@""], "guarded conversion yields empty string");
        CHECK(std::string(d.getCurrentSubgroup()) == "\xC3\x28",
              "raw bytes still tracked for change detection");
    }

    TEST_MAIN_END();

    }
}
