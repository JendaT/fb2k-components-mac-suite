//
//  PlaylistLayoutModelTests.mm
//  foo_simplaylist_mac
//
//  Unit tests for PlaylistLayoutModel (the pure sparse-group geometry model).
//
//  Strategy: an independent NAIVE REFERENCE builds the row structure explicitly
//  (walk groups -> emit header/subgroup/track/padding rows) and every model
//  query is checked against it. The reference is a different formulation from
//  the model's O(log n) arithmetic, so agreement across randomized fixtures is
//  strong evidence of correctness. Roundtrip invariants are asserted on top.
//
//  Compiled standalone (Foundation only, no SDK, no Xcode target) and run as a
//  gating phase of Scripts/build.sh. See Scripts/run_tests.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Core/PlaylistLayoutModel.h"

#include <vector>
#include <string>

// ---------------------------------------------------------------------------
// Test harness
// ---------------------------------------------------------------------------

static int g_failures = 0;
static int g_checks = 0;
static std::string g_context;

#define CHECK_EQ(actual, expected, what)                                          \
    do {                                                                          \
        g_checks++;                                                              \
        long long a__ = (long long)(actual), e__ = (long long)(expected);        \
        if (a__ != e__) {                                                        \
            g_failures++;                                                        \
            printf("FAIL [%s] %s: got %lld, expected %lld\n",                    \
                   g_context.c_str(), what, a__, e__);                           \
        }                                                                        \
    } while (0)

#define CHECK_FLOAT_EQ(actual, expected, what)                                    \
    do {                                                                          \
        g_checks++;                                                              \
        double a__ = (actual), e__ = (expected);                                 \
        if (fabs(a__ - e__) > 0.001) {                                           \
            g_failures++;                                                        \
            printf("FAIL [%s] %s: got %f, expected %f\n",                        \
                   g_context.c_str(), what, a__, e__);                           \
        }                                                                        \
    } while (0)

// Deterministic PRNG (seeded) so failures are reproducible.
static uint64_t g_rngState = 0;
static void seedRng(uint64_t seed) { g_rngState = seed ? seed : 1; }
static uint64_t nextRand(void) {
    g_rngState ^= g_rngState << 13;
    g_rngState ^= g_rngState >> 7;
    g_rngState ^= g_rngState << 17;
    return g_rngState;
}
static NSInteger randRange(NSInteger lo, NSInteger hi) {  // inclusive
    return lo + (NSInteger)(nextRand() % (uint64_t)(hi - lo + 1));
}

// ---------------------------------------------------------------------------
// Fixture + naive reference
// ---------------------------------------------------------------------------

typedef NS_ENUM(NSInteger, RefRowKind) {
    RefRowHeader,
    RefRowSubgroup,
    RefRowTrack,
    RefRowPadding,
};

struct RefRow {
    RefRowKind kind;
    NSInteger groupIndex;      // owning group (-1 in flat mode)
    NSInteger playlistIndex;   // for Track rows, else -1
    NSInteger subgroupIndex;   // for Subgroup rows, else -1
};

struct Fixture {
    NSInteger itemCount;
    std::vector<NSInteger> groupStarts;     // strictly increasing, first == 0 when non-empty
    std::vector<NSInteger> subgroupStarts;  // strictly increasing playlist indices
    std::vector<NSInteger> paddingRows;     // per group (may be shorter than groups)
    NSInteger style;                        // headerDisplayStyle 0..3
    CGFloat rowHeight;
    CGFloat headerHeight;
};

// Independent formulation: enumerate rows by walking the structure.
static std::vector<RefRow> buildReferenceRows(const Fixture &f) {
    std::vector<RefRow> rows;
    if (f.groupStarts.empty()) {
        for (NSInteger i = 0; i < f.itemCount; i++) {
            rows.push_back({RefRowTrack, -1, i, -1});
        }
        return rows;
    }
    size_t sgCursor = 0;
    for (size_t g = 0; g < f.groupStarts.size(); g++) {
        NSInteger start = f.groupStarts[g];
        NSInteger end = (g + 1 < f.groupStarts.size()) ? f.groupStarts[g + 1] : f.itemCount;
        if (f.style != 3) {
            rows.push_back({RefRowHeader, (NSInteger)g, -1, -1});
        }
        for (NSInteger i = start; i < end; i++) {
            if (sgCursor < f.subgroupStarts.size() && f.subgroupStarts[sgCursor] == i) {
                rows.push_back({RefRowSubgroup, (NSInteger)g, -1, (NSInteger)sgCursor});
                sgCursor++;
            }
            rows.push_back({RefRowTrack, (NSInteger)g, i, -1});
        }
        NSInteger pad = (g < f.paddingRows.size()) ? f.paddingRows[g] : 0;
        for (NSInteger p = 0; p < pad; p++) {
            rows.push_back({RefRowPadding, (NSInteger)g, -1, -1});
        }
    }
    return rows;
}

static NSArray<NSNumber *> *toNumbers(const std::vector<NSInteger> &v) {
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:v.size()];
    for (NSInteger x : v) [a addObject:@(x)];
    return a;
}

// Build a model exactly the way SimPlaylistController feeds the view:
// set inputs, then rebuildPaddingCache, then rebuildSubgroupRowCache.
static PlaylistLayoutModel *buildModel(const Fixture &f) {
    PlaylistLayoutModel *m = [[PlaylistLayoutModel alloc] init];
    m.itemCount = f.itemCount;
    m.headerDisplayStyle = f.style;
    m.rowHeight = f.rowHeight;
    m.headerHeight = f.headerHeight;
    m.groupStarts = toNumbers(f.groupStarts);
    m.subgroupStarts = toNumbers(f.subgroupStarts);

    NSMutableArray<NSString *> *sgHeaders = [NSMutableArray array];
    for (size_t i = 0; i < f.subgroupStarts.size(); i++) {
        [sgHeaders addObject:[NSString stringWithFormat:@"SG%zu", i]];
    }
    m.subgroupHeaders = sgHeaders;

    // subgroupCountPerGroup as the controller computes it: subgroups whose
    // start falls inside each group's playlist range.
    NSMutableArray<NSNumber *> *perGroup = [NSMutableArray array];
    for (size_t g = 0; g < f.groupStarts.size(); g++) {
        NSInteger start = f.groupStarts[g];
        NSInteger end = (g + 1 < f.groupStarts.size()) ? f.groupStarts[g + 1] : f.itemCount;
        NSInteger n = 0;
        for (NSInteger s : f.subgroupStarts) {
            if (s >= start && s < end) n++;
        }
        [perGroup addObject:@(n)];
    }
    m.subgroupCountPerGroup = perGroup;

    m.groupPaddingRows = toNumbers(f.paddingRows);
    [m rebuildPaddingCache];
    [m rebuildSubgroupRowCache];  // documented order: AFTER padding cache
    return m;
}

// ---------------------------------------------------------------------------
// Per-fixture verification
// ---------------------------------------------------------------------------

static void verifyFixture(const Fixture &f, const char *name) {
    g_context = std::string(name) + " style=" + std::to_string(f.style);
    @autoreleasepool {

    PlaylistLayoutModel *m = buildModel(f);
    std::vector<RefRow> ref = buildReferenceRows(f);
    NSInteger refCount = (NSInteger)ref.size();

    CHECK_EQ([m rowCount], refCount, "rowCount");

    // Reference pixel offsets (subgroup rows draw at rowHeight; only group
    // header rows are taller — mirrors heightForRow semantics).
    std::vector<CGFloat> refY(ref.size() + 1, 0);
    for (size_t r = 0; r < ref.size(); r++) {
        CGFloat h = (ref[r].kind == RefRowHeader) ? f.headerHeight : f.rowHeight;
        refY[r + 1] = refY[r] + h;
    }
    CHECK_FLOAT_EQ([m totalContentHeightCached], refY[ref.size()], "totalContentHeightCached");

    // Per-row checks
    for (NSInteger r = 0; r < refCount; r++) {
        const RefRow &row = ref[(size_t)r];

        CHECK_EQ([m isRowGroupHeader:r], (row.kind == RefRowHeader), "isRowGroupHeader");
        CHECK_EQ([m isRowSubgroupHeader:r], (row.kind == RefRowSubgroup), "isRowSubgroupHeader");
        CHECK_EQ([m playlistIndexForRow:r],
                 (row.kind == RefRowTrack) ? row.playlistIndex : -1,
                 "playlistIndexForRow");

        // KNOWN QUIRK (pre-existing, preserved verbatim by the extraction):
        // in style 3 the FIRST padding row of a group is not classified as
        // padding by isRowPaddingRow (off-by-one: `> contentRows` should be
        // `>= contentRows` when there is no header row). It is still unmapped
        // (playlistIndexForRow == -1, checked above), so rendering treats it
        // as blank either way. We pin the CURRENT behavior here; fixing it is
        // a separate behavioral change.
        BOOL expectPadding = (row.kind == RefRowPadding);
        if (f.style == 3 && row.kind == RefRowPadding) {
            BOOL isFirstPaddingOfGroup =
                (r > 0 && ref[(size_t)r - 1].kind != RefRowPadding);
            if (isFirstPaddingOfGroup) expectPadding = NO;  // quirk pinned
        }
        CHECK_EQ([m isRowPaddingRow:r], expectPadding, "isRowPaddingRow");

        if (row.kind == RefRowTrack) {
            CHECK_EQ([m rowForPlaylistIndex:row.playlistIndex], r, "rowForPlaylistIndex");
        }
        if (row.kind == RefRowSubgroup) {
            NSString *hdr = [m subgroupHeaderForRow:r];
            NSString *want = [NSString stringWithFormat:@"SG%ld", (long)row.subgroupIndex];
            g_checks++;
            if (![hdr isEqualToString:want]) {
                g_failures++;
                printf("FAIL [%s] subgroupHeaderForRow(%ld): got %s, expected %s\n",
                       g_context.c_str(), (long)r,
                       hdr.UTF8String ?: "nil", want.UTF8String);
            }
        }

        // Pixel geometry
        CGFloat wantH = (row.kind == RefRowHeader) ? f.headerHeight : f.rowHeight;
        CHECK_FLOAT_EQ([m heightForRow:r], wantH, "heightForRow");
        CHECK_FLOAT_EQ([m yOffsetForRow:r], refY[(size_t)r], "yOffsetForRow");

        // Hit-testing roundtrip: the midpoint of every row maps back to it
        CHECK_EQ([m rowAtPoint:NSMakePoint(0, refY[(size_t)r] + wantH / 2)], r, "rowAtPoint(mid)");
    }

    // Roundtrip over playlist indices
    for (NSInteger p = 0; p < f.itemCount; p++) {
        NSInteger r = [m rowForPlaylistIndex:p];
        g_checks++;
        if (r < 0 || r >= refCount) {
            g_failures++;
            printf("FAIL [%s] rowForPlaylistIndex(%ld) out of range: %ld\n",
                   g_context.c_str(), (long)p, (long)r);
        } else {
            CHECK_EQ([m playlistIndexForRow:r], p, "roundtrip p->r->p");
        }
    }

    // Group-level queries
    for (size_t g = 0; g < f.groupStarts.size(); g++) {
        // rowForGroupHeader: first row of the group in the walk
        NSInteger firstRowOfGroup = -1;
        CGFloat groupPixelHeight = 0;
        for (size_t r = 0; r < ref.size(); r++) {
            if (ref[r].groupIndex == (NSInteger)g) {
                if (firstRowOfGroup < 0) firstRowOfGroup = (NSInteger)r;
                groupPixelHeight += (ref[r].kind == RefRowHeader) ? f.headerHeight : f.rowHeight;
            }
        }
        CHECK_EQ([m rowForGroupHeader:(NSInteger)g], firstRowOfGroup, "rowForGroupHeader");
        CHECK_FLOAT_EQ([m pixelHeightForGroup:(NSInteger)g], groupPixelHeight, "pixelHeightForGroup");

        NSInteger start = f.groupStarts[g];
        NSInteger end = (g + 1 < f.groupStarts.size()) ? f.groupStarts[g + 1] : f.itemCount;
        NSRange range = [m playlistIndexRangeForGroup:(NSInteger)g];
        CHECK_EQ((NSInteger)range.location, start, "playlistIndexRangeForGroup.location");
        CHECK_EQ((NSInteger)range.length, end - start, "playlistIndexRangeForGroup.length");

        // Rows of this group map into this group
        for (size_t r = 0; r < ref.size(); r++) {
            if (ref[r].groupIndex == (NSInteger)g) {
                CHECK_EQ([m groupIndexForRow:(NSInteger)r], (NSInteger)g, "groupIndexForRow");
            }
        }
    }

    // Subgroup binary searches vs linear count
    for (NSInteger p = 0; p <= f.itemCount; p++) {
        NSInteger naive = 0;
        BOOL hasAt = NO;
        for (NSInteger s : f.subgroupStarts) {
            if (s < p) naive++;
            if (s == p) hasAt = YES;
        }
        CHECK_EQ([m subgroupCountBeforePlaylistIndex:p], naive, "subgroupCountBeforePlaylistIndex");
        CHECK_EQ([m hasSubgroupAtPlaylistIndex:p], hasAt, "hasSubgroupAtPlaylistIndex");
    }

    // Out-of-range behavior
    CHECK_EQ([m playlistIndexForRow:-1], -1, "playlistIndexForRow(-1)");
    CHECK_EQ([m playlistIndexForRow:refCount], -1, "playlistIndexForRow(count)");
    CHECK_EQ([m rowForPlaylistIndex:-1], -1, "rowForPlaylistIndex(-1)");
    CHECK_EQ([m rowForPlaylistIndex:f.itemCount], -1, "rowForPlaylistIndex(itemCount)");
    CHECK_EQ([m rowAtPoint:NSMakePoint(0, -5)], -1, "rowAtPoint(negative)");
    CHECK_EQ([m rowAtPoint:NSMakePoint(0, refY[ref.size()] + 1)], -1, "rowAtPoint(beyond)");

    }  // autoreleasepool
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

static Fixture randomFixture(NSInteger style) {
    Fixture f;
    f.style = style;
    f.rowHeight = 22;
    f.headerHeight = (style == 0) ? 28 : 22 + randRange(0, 12);
    NSInteger groups = randRange(1, 8);
    f.itemCount = 0;
    for (NSInteger g = 0; g < groups; g++) {
        f.groupStarts.push_back(f.itemCount);
        f.itemCount += randRange(1, 8);
        // One padding entry per group — the invariant every controller path
        // maintains (arrays built with one addObject per group). A shorter
        // array is unreachable in production, and cumulativePaddingBeforeGroup's
        // clamp intentionally under-counts there (latent quirk, documented in
        // the testability review).
        f.paddingRows.push_back(randRange(0, 3));
    }
    // Subgroups: probabilistic, including at exact group starts (edge case)
    for (NSInteger i = 0; i < f.itemCount; i++) {
        if ((nextRand() % 5) == 0) {
            f.subgroupStarts.push_back(i);
        }
    }
    return f;
}

int main(void) {
    @autoreleasepool {

    // --- Hand-built edge cases ---
    for (NSInteger style = 0; style <= 3; style++) {
        // Empty playlist
        verifyFixture({0, {}, {}, {}, style, 22, 28}, "empty");
        // Flat mode (items, no groups)
        verifyFixture({7, {}, {}, {}, style, 22, 28}, "flat");
        // Single group, single track
        verifyFixture({1, {0}, {}, {}, style, 22, 28}, "1g1t");
        // Single group with padding
        verifyFixture({2, {0}, {}, {3}, style, 22, 28}, "1g2t-pad3");
        // Subgroup at exact group start (the tricky case)
        verifyFixture({4, {0}, {0}, {1}, style, 22, 28}, "sg-at-group-start");
        // Subgroup mid-group + multiple subgroups
        verifyFixture({8, {0, 4}, {2, 4, 6}, {1, 2}, style, 22, 28}, "sg-mid+boundary");
        // Many small groups, no padding, header taller than row
        verifyFixture({6, {0, 1, 2, 3, 4, 5}, {}, {0, 0, 0, 0, 0, 0}, style, 22, 34}, "6x1");
        // Compact header (headerHeight == rowHeight)
        verifyFixture({5, {0, 2}, {1}, {1, 0}, style, 22, 22}, "compact-header");
    }

    // --- Randomized sweep (deterministic seed) ---
    seedRng(0x5EED5EED);
    for (int i = 0; i < 250; i++) {
        Fixture f = randomFixture((NSInteger)(nextRand() % 4));
        char name[32];
        snprintf(name, sizeof(name), "rand#%d", i);
        verifyFixture(f, name);
    }

    printf("%s: %d checks, %d failures\n",
           g_failures == 0 ? "TESTS PASSED" : "TESTS FAILED", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;

    }
}
