//
//  GroupBuilderTests.mm
//  foo_simplaylist_mac
//
//  Unit tests for GroupBuilder (the shared group/subgroup detection loop).
//  Fake formatters over string arrays stand in for title-format evaluation.
//  Compiled standalone (Foundation only); gating phase of Scripts/build.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Core/GroupBuilder.h"
#import "TestHarness.h"

#include <string>
#include <vector>

// Test track data: parallel header/subgroup arrays. artKey is "art<i>".
struct FakeTracks {
    std::vector<std::string> headers;
    std::vector<std::string> groupKeys;  // may be empty when unused
    std::vector<std::string> subgroups;  // may be empty when unused
    mutable std::string artBuf;

    simplaylist::GroupBuildCallbacks callbacks(std::function<bool()> cancelled = nullptr) const {
        simplaylist::GroupBuildCallbacks cb;
        cb.formatHeader = [this](size_t i) { return headers[i].c_str(); };
        if (!groupKeys.empty()) {
            cb.formatGroupKey = [this](size_t i) { return groupKeys[i].c_str(); };
        }
        if (!subgroups.empty()) {
            cb.formatSubgroup = [this](size_t i) { return subgroups[i].c_str(); };
        }
        cb.artKey = [this](size_t i) {
            artBuf = "art" + std::to_string(i);
            return artBuf.c_str();
        };
        cb.isCancelled = cancelled;
        return cb;
    }
};

struct BuildResult {
    NSMutableArray<NSNumber *> *groupStarts = [NSMutableArray array];
    NSMutableArray<NSString *> *groupHeaders = [NSMutableArray array];
    NSMutableArray<NSString *> *groupArtKeys = [NSMutableArray array];
    NSMutableArray<NSNumber *> *subgroupStarts = [NSMutableArray array];
    NSMutableArray<NSString *> *subgroupHeaders = [NSMutableArray array];
};

int main(void) {
    @autoreleasepool {

    // --- Basic grouping + art keys ---
    {
        g_context = "basic";
        FakeTracks t;
        t.headers = {"A", "A", "B", "B", "B", "C"};
        BuildResult r;
        std::string cur;
        SubgroupDetector det(true);
        bool ok = simplaylist::buildGroups(0, t.headers.size(), false, true, cur, det,
                                           t.callbacks(), r.groupStarts, r.groupHeaders,
                                           r.groupArtKeys, r.subgroupStarts, r.subgroupHeaders);
        CHECK(ok, "not cancelled");
        checkArray(r.groupStarts, @[@0, @2, @5], "group starts at header changes");
        checkArray(r.groupHeaders, @[@"A", @"B", @"C"], "group header text");
        checkArray(r.groupArtKeys, @[@"art0", @"art2", @"art5"], "art key of first track per group");
        CHECK(cur == "C", "currentHeader carries the last group");
    }

    // --- forceFirstNewGroup: empty headers still form one group from scratch ---
    {
        g_context = "force-first";
        FakeTracks t;
        t.headers = {"", "", ""};
        BuildResult r;
        std::string cur;
        SubgroupDetector det(true);
        simplaylist::buildGroups(0, 3, false, true, cur, det, t.callbacks(),
                                 r.groupStarts, r.groupHeaders, r.groupArtKeys,
                                 r.subgroupStarts, r.subgroupHeaders);
        checkArray(r.groupStarts, @[@0], "single group forced at index 0");
    }
    {
        g_context = "continuation-no-force";
        FakeTracks t;
        t.headers = {"", "", ""};
        BuildResult r;
        std::string cur;  // carried state equals the headers -> no boundary at the seam
        SubgroupDetector det(true);
        simplaylist::buildGroups(1, 3, false, false, cur, det, t.callbacks(),
                                 r.groupStarts, r.groupHeaders, r.groupArtKeys,
                                 r.subgroupStarts, r.subgroupHeaders);
        checkArray(r.groupStarts, @[], "no forced group in continuation");
    }

    // --- Chunked build == full build (the sync + continuation seam) ---
    {
        g_context = "chunked-equals-full";
        FakeTracks t;
        t.headers = {"A", "A", "B", "B", "C", "C", "C", "D"};
        t.subgroups = {"1", "1", "1", "2", "", "1", "2", "1"};

        BuildResult full;
        {
            std::string cur;
            SubgroupDetector det(true);
            simplaylist::buildGroups(0, t.headers.size(), true, true, cur, det, t.callbacks(),
                                     full.groupStarts, full.groupHeaders, full.groupArtKeys,
                                     full.subgroupStarts, full.subgroupHeaders);
        }
        for (size_t split = 1; split < t.headers.size(); split++) {
            BuildResult chunked;
            std::string cur;
            SubgroupDetector det(true);
            simplaylist::buildGroups(0, split, true, true, cur, det, t.callbacks(),
                                     chunked.groupStarts, chunked.groupHeaders, chunked.groupArtKeys,
                                     chunked.subgroupStarts, chunked.subgroupHeaders);
            // Continuation with carried currentHeader + detector state, no force
            simplaylist::buildGroups(split, t.headers.size(), true, false, cur, det, t.callbacks(),
                                     chunked.groupStarts, chunked.groupHeaders, chunked.groupArtKeys,
                                     chunked.subgroupStarts, chunked.subgroupHeaders);
            char what[64];
            snprintf(what, sizeof(what), "split at %zu: groups match", split);
            checkArray(chunked.groupStarts, full.groupStarts, what);
            checkArray(chunked.groupHeaders, full.groupHeaders, what);
            checkArray(chunked.groupArtKeys, full.groupArtKeys, what);
            checkArray(chunked.subgroupStarts, full.subgroupStarts, what);
            checkArray(chunked.subgroupHeaders, full.subgroupHeaders, what);
        }
    }

    // --- Grouping key: boundaries on the key, headers stay per-group display text ---
    {
        g_context = "group-key";
        FakeTracks t;
        // Multi-artist album: headers differ per track, key keeps them together
        t.headers = {"Artist1 - Album1", "Artist2 - Album1", "Artist3 - Album2", "Artist3 - Album2"};
        t.groupKeys = {"Album1", "Album1", "Album2", "Album2"};
        BuildResult r;
        std::string cur;
        SubgroupDetector det(true);
        simplaylist::buildGroups(0, t.headers.size(), false, true, cur, det, t.callbacks(),
                                 r.groupStarts, r.groupHeaders, r.groupArtKeys,
                                 r.subgroupStarts, r.subgroupHeaders);
        checkArray(r.groupStarts, @[@0, @2], "groups break on key changes only");
        checkArray(r.groupHeaders, @[@"Artist1 - Album1", @"Artist3 - Album2"],
                   "header text taken from first track of each group");
        CHECK(cur == "Album2", "carried state holds the key, not the header");

        // Continuation seeded with the key: same key at the seam -> no boundary
        BuildResult r2;
        simplaylist::buildGroups(2, t.headers.size(), false, false, cur, det, t.callbacks(),
                                 r2.groupStarts, r2.groupHeaders, r2.groupArtKeys,
                                 r2.subgroupStarts, r2.subgroupHeaders);
        checkArray(r2.groupStarts, @[], "no boundary at seam with matching key");
    }

    // --- Subgroup wiring: isNewGroup reaches the detector ---
    {
        g_context = "subgroup-wiring";
        FakeTracks t;
        t.headers = {"A", "A", "B", "B"};
        t.subgroups = {"Disc 1", "Disc 2", "Disc 1", "Disc 1"};
        BuildResult r;
        std::string cur;
        SubgroupDetector det(true);  // showFirst ON
        simplaylist::buildGroups(0, 4, true, true, cur, det, t.callbacks(),
                                 r.groupStarts, r.groupHeaders, r.groupArtKeys,
                                 r.subgroupStarts, r.subgroupHeaders);
        // Group A: Disc 1 at group start (emitted), Disc 2 change (emitted).
        // Group B: Disc 1 at group start (emitted), same (skipped).
        checkArray(r.subgroupStarts, @[@0, @1, @2], "subgroup emission points");
        checkArray(r.subgroupHeaders, @[@"Disc 1", @"Disc 2", @"Disc 1"], "subgroup texts");
    }

    // --- Cancellation aborts and reports ---
    {
        g_context = "cancellation";
        FakeTracks t;
        t.headers = {"A", "B", "C", "D"};
        BuildResult r;
        std::string cur;
        SubgroupDetector det(true);
        int seen = 0;
        bool ok = simplaylist::buildGroups(
            0, 4, false, true, cur, det,
            t.callbacks([&]() { return ++seen > 2; }),  // cancel before track 2
            r.groupStarts, r.groupHeaders, r.groupArtKeys,
            r.subgroupStarts, r.subgroupHeaders);
        CHECK(!ok, "reports cancellation");
        checkArray(r.groupStarts, @[@0, @1], "partial results up to cancellation");
    }

    // --- Invalid UTF-8 from tags: guarded conversion yields "", never nil ---
    // Regression for the documented crash fix in GroupBuilder.h:
    // stringWithUTF8String: returns nil on invalid UTF-8; addObject:nil throws.
    {
        g_context = "invalid-utf8";
        FakeTracks t;
        t.headers = {"\xC3\x28", "\xC3\x28", "B"};
        t.subgroups = {"\xC3\x28", "", ""};
        BuildResult r;
        std::string cur;
        SubgroupDetector det(true);
        bool ok = simplaylist::buildGroups(0, 3, true, true, cur, det, t.callbacks(),
                                           r.groupStarts, r.groupHeaders, r.groupArtKeys,
                                           r.subgroupStarts, r.subgroupHeaders);
        CHECK(ok, "completes despite invalid UTF-8");
        checkArray(r.groupStarts, @[@0, @2], "grouping compares raw bytes");
        checkArray(r.groupHeaders, @[@"", @"B"], "invalid UTF-8 header becomes empty string");
        checkArray(r.subgroupHeaders, @[@""], "invalid UTF-8 subgroup becomes empty string");
    }

    // --- Empty range is a no-op ---
    {
        g_context = "empty-range";
        FakeTracks t;
        BuildResult r;
        std::string cur;
        SubgroupDetector det(true);
        bool ok = simplaylist::buildGroups(0, 0, false, true, cur, det, t.callbacks(),
                                           r.groupStarts, r.groupHeaders, r.groupArtKeys,
                                           r.subgroupStarts, r.subgroupHeaders);
        CHECK(ok, "empty range succeeds");
        checkArray(r.groupStarts, @[], "no groups");
    }

    TEST_MAIN_END();

    }
}
