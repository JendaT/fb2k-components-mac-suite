//
//  RowMappingBudgetTests.mm
//  foo_simplaylist_mac
//
//  Complexity regression test for PlaylistLayoutModel's row mapping.
//
//  The functional suites all run on fixtures of itemCount <= 64 and groups <= 8,
//  so an accidental rewrite of playlistIndexForRow: / rowForPlaylistIndex: /
//  rowAtPoint: into a linear scan produces identical output and passes every
//  one of them. Wall-clock is the wrong instrument here: the suites run under
//  ASan at -O1, where timings are noisy enough that any threshold loose enough
//  not to flake is also loose enough to miss a regression.
//
//  So this measures *array probes* instead. Every NSArray input the model
//  indexes into is wrapped in a counting subclass, and each query is given a
//  probe budget on a deliberately large fixture. Because the budgets are
//  logarithmic and the fixture is not, an O(N) regression overshoots by three
//  orders of magnitude — far outside anything that could flake.
//
//  Compiled standalone (Foundation only); gating phase of Scripts/build.sh.
//

// TEST_DEPS: src/Core/PlaylistLayoutModel.mm

#import <Foundation/Foundation.h>
#import "../src/Core/PlaylistLayoutModel.h"
#import "TestHarness.h"

// ---------------------------------------------------------------------------
// Probe counting
// ---------------------------------------------------------------------------

static NSInteger g_probes = 0;

// An immutable NSArray that tallies every indexed read.
//
// copyWithZone: MUST return self. PlaylistLayoutModel declares its array inputs
// `copy`, so a subclass that copied itself into a plain NSArray would be
// discarded on assignment and the counter would sit at zero — the test would
// then "pass" no matter how the model behaved.
@interface ProbeCountingArray : NSArray
+ (instancetype)wrap:(NSArray *)backing;
@end

@implementation ProbeCountingArray {
    NSArray *_backing;
}

+ (instancetype)wrap:(NSArray *)backing {
    ProbeCountingArray *a = [[ProbeCountingArray alloc] initWithBacking:backing];
    return a;
}

- (instancetype)initWithBacking:(NSArray *)backing {
    self = [super init];
    if (self) {
        _backing = backing;
    }
    return self;
}

- (NSUInteger)count {
    return _backing.count;
}

- (id)objectAtIndex:(NSUInteger)index {
    g_probes++;
    return [_backing objectAtIndex:index];
}

// Route the subscript form through the counted primitive, so `array[i]` and
// `[array objectAtIndex:i]` cost exactly one probe each and never two.
- (id)objectAtIndexedSubscript:(NSUInteger)index {
    return [self objectAtIndex:index];
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

@end

// ---------------------------------------------------------------------------
// Fixture
// ---------------------------------------------------------------------------

// Large enough that log2 and N are unmistakably different: log2(20000) ~ 14.3,
// so a budget in the hundreds cannot be reached by anything logarithmic and
// cannot be missed by anything linear.
static const NSInteger kItems = 200000;
static const NSInteger kGroups = 20000;         // 10 tracks per group
static const NSInteger kSubgroupEvery = 3;      // 3 subgroups per group

static NSArray<NSNumber *> *numbers(NSInteger count, NSInteger (^value)(NSInteger)) {
    NSMutableArray<NSNumber *> *a = [NSMutableArray arrayWithCapacity:count];
    for (NSInteger i = 0; i < count; i++) [a addObject:@(value(i))];
    return a;
}

// Build the model with every array input — including cumulativePaddingCache,
// which rebuildPaddingCache produces internally as a plain array and which
// would otherwise go uncounted — wrapped in the counting subclass.
//
// The rebuilds themselves are never measured: they are legitimately O(groups),
// worstProbes zeroes the counter before each sample, and the model is left
// fully built here so no query pays for a rebuild that belongs to setup.
static PlaylistLayoutModel *makeModel(NSInteger headerDisplayStyle) {
    PlaylistLayoutModel *m = [[PlaylistLayoutModel alloc] init];
    m.itemCount = kItems;
    m.rowHeight = 20;
    m.headerHeight = 26;
    m.headerDisplayStyle = headerDisplayStyle;

    const NSInteger tracksPerGroup = kItems / kGroups;
    m.groupStarts = numbers(kGroups, ^(NSInteger i) { return i * tracksPerGroup; });
    m.groupPaddingRows = numbers(kGroups, ^(NSInteger i) { return (NSInteger)(i % 3); });

    // Subgroups start partway into each group, so subgroupStarts never
    // coincides with groupStarts and the searches cannot short-circuit.
    NSMutableArray<NSNumber *> *subStarts = [NSMutableArray array];
    NSMutableArray<NSString *> *subHeaders = [NSMutableArray array];
    NSMutableArray<NSNumber *> *subPerGroup = [NSMutableArray array];
    for (NSInteger g = 0; g < kGroups; g++) {
        NSInteger inThisGroup = 0;
        for (NSInteger k = kSubgroupEvery; k < tracksPerGroup; k += kSubgroupEvery) {
            [subStarts addObject:@(g * tracksPerGroup + k)];
            [subHeaders addObject:[NSString stringWithFormat:@"Disc %ld", (long)(k / kSubgroupEvery + 1)]];
            inThisGroup++;
        }
        [subPerGroup addObject:@(inThisGroup)];
    }
    m.subgroupStarts = subStarts;
    m.subgroupHeaders = subHeaders;
    m.subgroupCountPerGroup = subPerGroup;

    [m rebuildPaddingCache];

    m.groupStarts = [ProbeCountingArray wrap:m.groupStarts];
    m.groupPaddingRows = [ProbeCountingArray wrap:m.groupPaddingRows];
    m.subgroupStarts = [ProbeCountingArray wrap:m.subgroupStarts];
    m.subgroupCountPerGroup = [ProbeCountingArray wrap:m.subgroupCountPerGroup];
    m.cumulativePaddingCache = [ProbeCountingArray wrap:m.cumulativePaddingCache];

    // Last, and after the wrapping: assigning any of the arrays above drops the
    // model's derived caches, and a query that had to rebuild one would be
    // charged for a whole O(groups) pass that belongs to setup, not to the
    // query. Leaving the model fully built is also what a real panel does.
    [m rebuildSubgroupRowCache];

    return m;
}

// Run `block` over a spread of positions and report the worst single-call probe
// count. The worst case is what a budget has to hold, and averaging would let a
// regression hide behind the cheap queries near index 0.
static NSInteger worstProbes(NSInteger samples, void (^block)(NSInteger sample)) {
    NSInteger worst = 0;
    for (NSInteger s = 0; s < samples; s++) {
        g_probes = 0;
        block(s);
        if (g_probes > worst) worst = g_probes;
    }
    return worst;
}

// Set BUDGET_REPORT=1 to print the measured worst case for each query. Useful
// when re-tuning a budget after an intentional change to the mapping.
static void checkBudget(const char *what, NSInteger measured, NSInteger budget) {
    if (getenv("BUDGET_REPORT")) {
        printf("  %-24s %5ld probes (budget %ld)\n", what, (long)measured, (long)budget);
    }
    g_checks++;
    if (measured > budget) {
        g_failures++;
        printf("FAIL %s:%d [%s] %s: %ld probes, budget %ld "
               "(a linear scan of this fixture would cost ~%ld)\n",
               __FILE__, __LINE__, g_context.c_str(), what,
               (long)measured, (long)budget, (long)kGroups);
    }
}

int main(void) {
    @autoreleasepool {

    // Sanity first: if the fixture or the wrapping is wrong, every budget below
    // passes trivially and the suite is worthless.
    {
        g_context = "fixture";
        PlaylistLayoutModel *m = makeModel(0);
        CHECK_EQ(m.groupStarts.count, kGroups, "group count");
        CHECK_EQ(m.itemCount, kItems, "item count");
        CHECK(m.subgroupStarts.count > kGroups, "subgroups outnumber groups");

        // Prove the wrapping actually took, or every budget below passes for
        // the wrong reason. rowForPlaylistIndex: is the probe that has to be
        // used here: most of the others are now O(1) against a precomputed
        // vector and legitimately register zero.
        g_probes = 0;
        for (NSInteger idx = 0; idx < kItems; idx += 9973) {
            (void)[m rowForPlaylistIndex:idx];
        }
        CHECK(g_probes > 0, "counting arrays survived the model's copy properties");

        // The mapping must still be correct — a fast wrong answer is no use.
        for (NSInteger idx = 0; idx < kItems; idx += 4999) {
            NSInteger row = [m rowForPlaylistIndex:idx];
            CHECK_EQ([m playlistIndexForRow:row], idx, "row <-> index round trip");
        }
    }

    // Budgets sit far above the measured worst case and far below both a linear
    // rewrite and the pre-optimisation cost, so they catch a regression in
    // either direction without flaking.
    //
    // Measured now, against what the same query cost when rowForGroupHeader:
    // still binary-searched subgroupStarts on every call:
    //
    //   query                  before   now   budget
    //   playlistIndexForRow:      290     2       50
    //   rowForPlaylistIndex:       48    48      200
    //   groupIndexForRow:         270     0       50
    //   rowForGroupHeader:         18     0        8
    //   yOffsetForRow:            288     0       50
    //   rowAtPoint:             10338     0      200
    //
    // The zeros are real: those paths now read a precomputed vector and touch
    // no NSArray at all. rowAtPoint: fell furthest because it nested four
    // searches — a binary search over rows, each probe calling yOffsetForRow:,
    // which called groupIndexForRow:, whose every probe called
    // rowForGroupHeader: and thus a search over subgroupStarts.
    //
    // rowForPlaylistIndex: is unchanged by design: it runs its own search over
    // groupStarts and calls subgroupCountBeforePlaylistIndex: directly, neither
    // of which goes through rowForGroupHeader:.
    {
        g_context = "budget-style-0";
        PlaylistLayoutModel *m = makeModel(0);
        const NSInteger rows = m.rowCount;

        checkBudget("playlistIndexForRow:",
                    worstProbes(64, ^(NSInteger s) {
                        (void)[m playlistIndexForRow:(rows - 1) * s / 63];
                    }), 50);

        checkBudget("rowForPlaylistIndex:",
                    worstProbes(64, ^(NSInteger s) {
                        (void)[m rowForPlaylistIndex:(kItems - 1) * s / 63];
                    }), 200);

        checkBudget("groupIndexForRow:",
                    worstProbes(64, ^(NSInteger s) {
                        (void)[m groupIndexForRow:(rows - 1) * s / 63];
                    }), 50);

        checkBudget("rowForGroupHeader:",
                    worstProbes(64, ^(NSInteger s) {
                        (void)[m rowForGroupHeader:(kGroups - 1) * s / 63];
                    }), 8);

        checkBudget("rowAtPoint:",
                    worstProbes(64, ^(NSInteger s) {
                        CGFloat maxY = [m totalContentHeightCached];
                        (void)[m rowAtPoint:NSMakePoint(0, maxY * s / 63)];
                    }), 200);

        checkBudget("yOffsetForRow:",
                    worstProbes(64, ^(NSInteger s) {
                        (void)[m yOffsetForRow:(rows - 1) * s / 63];
                    }), 50);
    }

    // Header style 3 takes the other branch of rowForGroupHeader:, which every
    // row query above sits on top of. It gets its own budgets so a regression
    // cannot hide in the branch the default style does not exercise.
    {
        g_context = "budget-style-3";
        PlaylistLayoutModel *m = makeModel(3);
        const NSInteger rows = m.rowCount;

        checkBudget("playlistIndexForRow:",
                    worstProbes(64, ^(NSInteger s) {
                        (void)[m playlistIndexForRow:(rows - 1) * s / 63];
                    }), 50);

        checkBudget("rowForPlaylistIndex:",
                    worstProbes(64, ^(NSInteger s) {
                        (void)[m rowForPlaylistIndex:(kItems - 1) * s / 63];
                    }), 200);

        checkBudget("rowAtPoint:",
                    worstProbes(64, ^(NSInteger s) {
                        CGFloat maxY = [m totalContentHeightCached];
                        (void)[m rowAtPoint:NSMakePoint(0, maxY * s / 63)];
                    }), 200);
    }

    }
    TEST_MAIN_END();
}
