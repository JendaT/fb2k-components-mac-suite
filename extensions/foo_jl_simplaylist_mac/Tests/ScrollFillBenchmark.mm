//
//  ScrollFillBenchmark.mm
//  foo_simplaylist_mac
//
//  Repeatable benchmark for the virtual-scroll fill path (P4 Part A
//  acceptance gate: rendering benchmarks unchanged with zero decorator
//  providers registered).
//
//  Simulates the per-frame query sequence drawSparseModelInRect performs
//  against PlaylistLayoutModel while scrolling a 5,000-track grouped playlist
//  end to end: visible-range lookup (rowAtPoint) followed by the per-row
//  queries drawSparseRow issues (rect, header/subgroup/padding classification,
//  playlist-index mapping). Drawing itself (AppKit fills/text) is excluded --
//  it cannot run headless -- so this measures the model-side cost per frame,
//  which is the code path the decorator integration hooks into.
//
//  Compiled standalone (Foundation only, no SDK, no Xcode target) with -O2.
//  Run via Scripts/run_benchmark.sh. Reports min/median over several passes;
//  compare the BENCH lines before/after a change on the same machine.
//

#import <Foundation/Foundation.h>
#import "../src/Core/DecorationStore.h"
#import "../src/Core/PlaylistLayoutModel.h"

#include <algorithm>
#include <mach/mach_time.h>
#include <vector>

// ---------------------------------------------------------------------------
// Timing
// ---------------------------------------------------------------------------

static double machToUs(uint64_t delta) {
    static mach_timebase_info_data_t info;
    if (info.denom == 0) mach_timebase_info(&info);
    return (double)delta * info.numer / info.denom / 1000.0;
}

// ---------------------------------------------------------------------------
// Fixture: 5,000 tracks, 250 groups of 20, subgroup every 4th group,
// 0-2 padding rows per group (album-art min-height), header style 0.
// ---------------------------------------------------------------------------

static PlaylistLayoutModel *makeFixture(void) {
    const NSInteger itemCount = 5000;
    const NSInteger groupSize = 20;

    NSMutableArray<NSNumber *> *groupStarts = [NSMutableArray array];
    NSMutableArray<NSNumber *> *groupPadding = [NSMutableArray array];
    NSMutableArray<NSNumber *> *subgroupStarts = [NSMutableArray array];
    NSMutableArray<NSString *> *subgroupHeaders = [NSMutableArray array];
    NSMutableArray<NSNumber *> *subgroupCountPerGroup = [NSMutableArray array];

    for (NSInteger start = 0, g = 0; start < itemCount; start += groupSize, g++) {
        [groupStarts addObject:@(start)];
        [groupPadding addObject:@(g % 3)];  // 0, 1, 2, 0, ...
        if (g % 4 == 0) {
            [subgroupStarts addObject:@(start + groupSize / 2)];
            [subgroupHeaders addObject:[NSString stringWithFormat:@"Disc %ld", (long)g]];
            [subgroupCountPerGroup addObject:@1];
        } else {
            [subgroupCountPerGroup addObject:@0];
        }
    }

    PlaylistLayoutModel *m = [[PlaylistLayoutModel alloc] init];
    m.itemCount = itemCount;
    m.groupStarts = groupStarts;
    m.groupPaddingRows = groupPadding;
    m.subgroupStarts = subgroupStarts;
    m.subgroupHeaders = subgroupHeaders;
    m.subgroupCountPerGroup = subgroupCountPerGroup;
    m.headerDisplayStyle = 0;
    m.rowHeight = 22;
    m.headerHeight = 28;
    [m rebuildPaddingCache];
    [m rebuildSubgroupRowCache];
    return m;
}

// ---------------------------------------------------------------------------
// Simulated frame: the query sequence of drawSparseModelInRect + drawSparseRow
// for one dirty rect. Returns a checksum so the work cannot be optimized away.
//
// simulateFrame is the zero-provider baseline case captured in DEVLOG before
// the decorator integration -- its body must stay byte-identical so BENCH
// lines remain comparable. simulateFrameDecorated adds the per-row
// DecorationStore lookup the view performs when a provider exists
// (steady-state: all indices bound, 100% cache hit). Known limitation: the
// real view reaches the store through a delegate call (one objc_msgSend per
// visible row per frame) which is not modeled here, so decorated_overhead_pct
// measures the store lookup only and slightly understates the provider-
// present cost. The zero-provider gate is unaffected.
// ---------------------------------------------------------------------------

static NSInteger simulateFrame(PlaylistLayoutModel *m, CGFloat scrollY, CGFloat viewportH,
                               NSInteger *rowsVisited) {
    NSInteger firstRow = [m rowAtPoint:NSMakePoint(0, scrollY)];
    NSInteger lastRow = [m rowAtPoint:NSMakePoint(0, scrollY + viewportH)];
    NSInteger totalRows = [m rowCount];
    if (firstRow < 0) firstRow = 0;
    if (lastRow < 0 || lastRow >= totalRows) lastRow = totalRows - 1;

    NSInteger checksum = 0;
    for (NSInteger row = firstRow; row <= lastRow; row++) {
        // rectForRow equivalent
        CGFloat y = [m yOffsetForRow:row];
        CGFloat h = [m heightForRow:row];
        checksum += (NSInteger)y + (NSInteger)h;

        // drawSparseRow classification sequence
        BOOL isHeader = [m isRowGroupHeader:row];
        BOOL isSubgroup = [m isRowSubgroupHeader:row];
        BOOL isPadding = [m isRowPaddingRow:row];
        if (isHeader) {
            checksum += [m groupIndexForRow:row];
        } else if (!isSubgroup && !isPadding) {
            checksum += [m playlistIndexForRow:row];
        }
        (*rowsVisited)++;
    }
    return checksum;
}

static NSInteger simulateFrameDecorated(PlaylistLayoutModel *m, DecorationStore *store,
                                        CGFloat scrollY, CGFloat viewportH,
                                        NSInteger *rowsVisited) {
    NSInteger firstRow = [m rowAtPoint:NSMakePoint(0, scrollY)];
    NSInteger lastRow = [m rowAtPoint:NSMakePoint(0, scrollY + viewportH)];
    NSInteger totalRows = [m rowCount];
    if (firstRow < 0) firstRow = 0;
    if (lastRow < 0 || lastRow >= totalRows) lastRow = totalRows - 1;

    NSInteger checksum = 0;
    for (NSInteger row = firstRow; row <= lastRow; row++) {
        CGFloat y = [m yOffsetForRow:row];
        CGFloat h = [m heightForRow:row];
        checksum += (NSInteger)y + (NSInteger)h;

        BOOL isHeader = [m isRowGroupHeader:row];
        BOOL isSubgroup = [m isRowSubgroupHeader:row];
        BOOL isPadding = [m isRowPaddingRow:row];
        if (isHeader) {
            checksum += [m groupIndexForRow:row];
        } else if (!isSubgroup && !isPadding) {
            NSInteger playlistIndex = [m playlistIndexForRow:row];
            checksum += playlistIndex;
            // The decorated-path addition: cache-only decoration lookup
            RowDecoration *dec = [store decorationForIndex:playlistIndex];
            if (dec) checksum += dec.tintRGBA & 0xF;
        }
        (*rowsVisited)++;
    }
    return checksum;
}

// One full scroll pass over the playlist, ~3 rows (66 px) per frame,
// matching a fast smooth scroll.
static NSInteger scrollPass(PlaylistLayoutModel *m, CGFloat viewportH,
                            NSInteger *frames, NSInteger *rowsVisited) {
    CGFloat totalH = [m totalContentHeightCached];
    NSInteger checksum = 0;
    for (CGFloat y = 0; y + viewportH < totalH; y += 66.0) {
        checksum += simulateFrame(m, y, viewportH, rowsVisited);
        (*frames)++;
    }
    return checksum;
}

static NSInteger scrollPassDecorated(PlaylistLayoutModel *m, DecorationStore *store,
                                     CGFloat viewportH, NSInteger *frames,
                                     NSInteger *rowsVisited) {
    CGFloat totalH = [m totalContentHeightCached];
    NSInteger checksum = 0;
    for (CGFloat y = 0; y + viewportH < totalH; y += 66.0) {
        checksum += simulateFrameDecorated(m, store, y, viewportH, rowsVisited);
        (*frames)++;
    }
    return checksum;
}

// Steady-state store for the decorated case: every index bound, every 25th
// track decorated (200 of 5,000 -- the doc 04 acceptance scenario).
static DecorationStore *makeDecoratedStore(NSInteger itemCount) {
    DecorationStore *store = [[DecorationStore alloc] init];
    for (NSInteger i = 0; i < itemCount; i++) {
        uintptr_t key = (uintptr_t)(0x1000 + i * 16);  // Synthetic handle keys
        [store bindIndex:i toHandleKey:key];
        RowDecoration *dec = [[RowDecoration alloc] init];
        if (i % 25 == 0) {
            dec.tintRGBA = 0x4A90D938;
            dec.iconId = 1;
        }
        [store setDecoration:dec forHandleKey:key];
    }
    return store;
}

int main(void) {
    @autoreleasepool {
        PlaylistLayoutModel *m = makeFixture();
        const CGFloat viewportH = 800;
        const int passes = 7;

        printf("ScrollFillBenchmark: %ld items, %lu groups, %ld display rows, "
               "content height %.0f px\n",
               (long)m.itemCount, (unsigned long)m.groupStarts.count,
               (long)[m rowCount], [m totalContentHeightCached]);

        // Warmup (not measured)
        NSInteger frames = 0, rows = 0;
        NSInteger checksum = scrollPass(m, viewportH, &frames, &rows);

        std::vector<double> passUs;
        NSInteger framesPerPass = 0, rowsPerPass = 0;
        for (int p = 0; p < passes; p++) {
            frames = 0;
            rows = 0;
            uint64_t t0 = mach_absolute_time();
            NSInteger c = scrollPass(m, viewportH, &frames, &rows);
            uint64_t t1 = mach_absolute_time();
            if (c != checksum) {
                printf("BENCH FAILED: checksum mismatch across passes\n");
                return 1;
            }
            passUs.push_back(machToUs(t1 - t0));
            framesPerPass = frames;
            rowsPerPass = rows;
            printf("  pass %d: %.0f us (%ld frames, %ld rows)\n",
                   p + 1, passUs.back(), (long)frames, (long)rows);
        }

        std::sort(passUs.begin(), passUs.end());
        double minUs = passUs.front();
        double medianUs = passUs[passUs.size() / 2];

        // Decorated fill: same pass with the per-row DecorationStore lookup
        // (steady-state cache, 200 of 5,000 rows decorated).
        DecorationStore *store = makeDecoratedStore(m.itemCount);
        frames = 0;
        rows = 0;
        NSInteger decoratedChecksum = scrollPassDecorated(m, store, viewportH, &frames, &rows);  // Warmup
        std::vector<double> decoratedUs;
        for (int p = 0; p < passes; p++) {
            frames = 0;
            rows = 0;
            uint64_t t0 = mach_absolute_time();
            NSInteger c = scrollPassDecorated(m, store, viewportH, &frames, &rows);
            uint64_t t1 = mach_absolute_time();
            if (c != decoratedChecksum) {
                printf("BENCH FAILED: decorated checksum mismatch across passes\n");
                return 1;
            }
            decoratedUs.push_back(machToUs(t1 - t0));
        }
        std::sort(decoratedUs.begin(), decoratedUs.end());
        double decoratedMinUs = decoratedUs.front();
        double decoratedMedianUs = decoratedUs[decoratedUs.size() / 2];

        // Reload-path benchmark: cache rebuilds after a playlist change.
        const int reloads = 200;
        uint64_t r0 = mach_absolute_time();
        for (int i = 0; i < reloads; i++) {
            [m rebuildPaddingCache];
            [m rebuildSubgroupRowCache];
        }
        uint64_t r1 = mach_absolute_time();
        double reloadUs = machToUs(r1 - r0) / reloads;

        printf("BENCH fill_pass_min_us=%.0f\n", minUs);
        printf("BENCH fill_pass_median_us=%.0f\n", medianUs);
        printf("BENCH fill_frame_min_us=%.2f\n", minUs / framesPerPass);
        printf("BENCH fill_row_min_us=%.3f\n", minUs / rowsPerPass);
        printf("BENCH reload_us=%.1f\n", reloadUs);
        printf("BENCH fill_pass_decorated_min_us=%.0f\n", decoratedMinUs);
        printf("BENCH fill_pass_decorated_median_us=%.0f\n", decoratedMedianUs);
        printf("BENCH decorated_overhead_pct=%.2f\n", (decoratedMinUs - minUs) / minUs * 100.0);
        printf("BENCHMARK COMPLETE (checksum %ld)\n", (long)checksum);
        return 0;
    }
}
