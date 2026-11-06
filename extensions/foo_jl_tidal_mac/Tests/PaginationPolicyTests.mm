//
//  PaginationPolicyTests.mm
//  foo_jl_tidal_mac
//
//  Unit tests for the pagination decision logic: short-page completion,
//  full-page continuation, and the ceiling that turns oversized
//  collections into hard failures instead of silent truncation.
//

#import <Foundation/Foundation.h>
#import "../src/Core/PaginationPolicy.h"
#include "TestHarness.h"

typedef JLTidalPaginationPolicy Policy;

static void testShortPageCompletes(void) {
    CHECK_EQ([Policy actionAfterPageCount:37 accumulated:237 limit:50 ceiling:10000],
             JLTidalPageActionDone, "short page completes the collection");
    CHECK_EQ([Policy actionAfterPageCount:0 accumulated:200 limit:200 ceiling:10000],
             JLTidalPageActionDone, "empty page completes the collection");
    CHECK_EQ([Policy actionAfterPageCount:49 accumulated:49 limit:50 ceiling:10000],
             JLTidalPageActionDone, "first page short -> single-page collection");
}

static void testFullPageContinues(void) {
    CHECK_EQ([Policy actionAfterPageCount:50 accumulated:50 limit:50 ceiling:10000],
             JLTidalPageActionContinue, "full first page continues");
    CHECK_EQ([Policy actionAfterPageCount:200 accumulated:9800 limit:200 ceiling:10000],
             JLTidalPageActionContinue, "full page just under ceiling continues");
    // Server returning more than asked still counts as a full page
    CHECK_EQ([Policy actionAfterPageCount:60 accumulated:60 limit:50 ceiling:10000],
             JLTidalPageActionContinue, "over-full page continues");
}

static void testCeilingFailsHard(void) {
    CHECK_EQ([Policy actionAfterPageCount:200 accumulated:10000 limit:200 ceiling:10000],
             JLTidalPageActionFailCeiling, "full page at ceiling fails (never truncate)");
    CHECK_EQ([Policy actionAfterPageCount:200 accumulated:10200 limit:200 ceiling:10000],
             JLTidalPageActionFailCeiling, "full page past ceiling fails");
    // Short page at the ceiling is still a complete collection
    CHECK_EQ([Policy actionAfterPageCount:100 accumulated:10000 limit:200 ceiling:10000],
             JLTidalPageActionDone, "short page at ceiling is complete, not failed");
}

static void testDegenerateLimit(void) {
    CHECK_EQ([Policy actionAfterPageCount:10 accumulated:10 limit:0 ceiling:10000],
             JLTidalPageActionDone, "limit 0 never pages");
    CHECK_EQ([Policy actionAfterPageCount:10 accumulated:10 limit:-1 ceiling:10000],
             JLTidalPageActionDone, "negative limit never pages");
}

int main(void) {
    @autoreleasepool {
        testShortPageCompletes();
        testFullPageContinues();
        testCeilingFailsHard();
        testDegenerateLimit();
    }
    return testHarnessFinish("PaginationPolicyTests");
}
