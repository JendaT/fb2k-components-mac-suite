//
//  PlaylistSelectionModelTests.mm
//  foo_simplaylist_mac
//
//  Unit tests for PlaylistSelectionModel (selection/anchor/focus state math).
//
//  Uses a fixed grouped layout (style 0) whose row structure is spelled out
//  below, so every keyboard-navigation expectation is written against known
//  rows. Compiled standalone with clang (Foundation only) and run as a gating
//  phase of Scripts/build.sh. See Scripts/run_tests.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Core/PlaylistLayoutModel.h"
#import "../src/Core/PlaylistSelectionModel.h"

#include <string>
#include <vector>

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

// Selection must equal exactly this set of playlist indices.
static void checkSelection(PlaylistSelectionModel *sel, NSIndexSet *expected, const char *what) {
    g_checks++;
    if (![sel.selectedIndices isEqualToIndexSet:expected]) {
        g_failures++;
        printf("FAIL [%s] %s: selection mismatch (got %s, expected %s)\n",
               g_context.c_str(), what,
               sel.selectedIndices.description.UTF8String,
               expected.description.UTF8String);
    }
}

static NSIndexSet *rangeSet(NSInteger start, NSInteger end) {  // inclusive
    return [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(start, end - start + 1)];
}

static NSIndexSet *singleSet(NSInteger i) {
    return [NSIndexSet indexSetWithIndex:i];
}

// ---------------------------------------------------------------------------
// Fixture: style 0, 12 tracks, 3 groups, subgroups at 4 and 7, padding {0,1,2}
//
// Row structure (verified by PlaylistLayoutModelTests' reference walk):
//   0: header G0        5: header G1       15: header G2
//   1: track 0          6: subgroup @4     16: track 10
//   2: track 1          7: track 4         17: track 11
//   3: track 2          8: track 5         18: padding
//   4: track 3          9: track 6         19: padding
//                      10: subgroup @7
//                      11: track 7
//                      12: track 8
//                      13: track 9
//                      14: padding
// ---------------------------------------------------------------------------

static PlaylistLayoutModel *makeGroupedLayout(void) {
    PlaylistLayoutModel *layout = [[PlaylistLayoutModel alloc] init];
    layout.itemCount = 12;
    layout.headerDisplayStyle = 0;
    layout.rowHeight = 22;
    layout.headerHeight = 28;
    layout.groupStarts = @[@0, @4, @10];
    layout.subgroupStarts = @[@4, @7];
    layout.subgroupHeaders = @[@"Disc 1", @"Disc 2"];
    layout.subgroupCountPerGroup = @[@0, @2, @0];
    layout.groupPaddingRows = @[@0, @1, @2];
    [layout rebuildPaddingCache];
    [layout rebuildSubgroupRowCache];
    return layout;
}

static PlaylistLayoutModel *makeFlatLayout(NSInteger itemCount) {
    PlaylistLayoutModel *layout = [[PlaylistLayoutModel alloc] init];
    layout.itemCount = itemCount;
    return layout;
}

static PlaylistSelectionModel *makeSelection(PlaylistLayoutModel *layout) {
    return [[PlaylistSelectionModel alloc] initWithLayout:layout];
}

int main(void) {
    @autoreleasepool {

    PlaylistLayoutModel *layout = makeGroupedLayout();

    // --- Basic select / extend / toggle ---
    {
        g_context = "select+extend";
        PlaylistSelectionModel *sel = makeSelection(layout);

        [sel selectPlaylistIndex:5 extendFromAnchor:NO];
        checkSelection(sel, singleSet(5), "single select");
        CHECK_EQ(sel.anchorIndex, 5, "anchor after single");
        CHECK_EQ(sel.focusIndex, 5, "focus after single");

        [sel selectPlaylistIndex:9 extendFromAnchor:YES];
        checkSelection(sel, rangeSet(5, 9), "extend down");
        CHECK_EQ(sel.anchorIndex, 5, "anchor preserved on extend");
        CHECK_EQ(sel.focusIndex, 9, "focus follows extend");

        [sel selectPlaylistIndex:2 extendFromAnchor:YES];
        checkSelection(sel, rangeSet(2, 5), "extend up crosses anchor");
        CHECK_EQ(sel.focusIndex, 2, "focus follows upward extend");
    }
    {
        g_context = "extend-without-anchor";
        PlaylistSelectionModel *sel = makeSelection(layout);
        [sel selectPlaylistIndex:3 extendFromAnchor:YES];  // no anchor yet
        checkSelection(sel, singleSet(3), "falls back to single select");
        CHECK_EQ(sel.anchorIndex, 3, "anchor set by fallback");
    }
    {
        g_context = "toggle";
        PlaylistSelectionModel *sel = makeSelection(layout);
        [sel selectPlaylistIndex:5 extendFromAnchor:NO];
        [sel togglePlaylistIndex:3];
        NSMutableIndexSet *threeAndFive = [NSMutableIndexSet indexSetWithIndex:3];
        [threeAndFive addIndex:5];
        checkSelection(sel, threeAndFive, "toggle adds");
        CHECK_EQ(sel.focusIndex, 5, "toggle leaves focus");
        CHECK_EQ(sel.anchorIndex, 5, "toggle leaves anchor");
        [sel togglePlaylistIndex:3];
        checkSelection(sel, singleSet(5), "toggle removes");
    }

    // --- selectAll / deselectAll ---
    {
        g_context = "selectAll";
        PlaylistSelectionModel *sel = makeSelection(layout);
        [sel selectPlaylistIndex:2 extendFromAnchor:NO];
        [sel selectAll];
        checkSelection(sel, rangeSet(0, 11), "selectAll covers all tracks");
        CHECK_EQ(sel.anchorIndex, 2, "selectAll leaves anchor");
        CHECK_EQ(sel.focusIndex, 2, "selectAll leaves focus");

        [sel deselectAll];
        checkSelection(sel, [NSIndexSet indexSet], "deselectAll clears");
        CHECK_EQ(sel.anchorIndex, 2, "deselectAll leaves anchor");
        CHECK_EQ(sel.focusIndex, 2, "deselectAll leaves focus");
    }
    {
        g_context = "selectAll-empty";
        PlaylistSelectionModel *sel = makeSelection(makeFlatLayout(0));
        [sel selectAll];
        checkSelection(sel, [NSIndexSet indexSet], "selectAll no-op when empty");
    }

    // --- Stable set identity (the view/controller alias this instance) ---
    {
        g_context = "set-identity";
        PlaylistSelectionModel *sel = makeSelection(layout);
        NSMutableIndexSet *set = sel.selectedIndices;
        [sel selectPlaylistIndex:1 extendFromAnchor:NO];
        [sel deselectAll];
        [sel selectAll];
        g_checks++;
        if (set != sel.selectedIndices) {
            g_failures++;
            printf("FAIL [set-identity] selectedIndices instance was replaced\n");
        }
    }

    // --- Group clicks (G1 = tracks 4..9) ---
    {
        g_context = "group-click";
        NSRange g1 = NSMakeRange(4, 6);
        PlaylistSelectionModel *sel = makeSelection(layout);

        [sel clickGroupRange:g1 commandKey:NO shiftKey:NO];
        checkSelection(sel, rangeSet(4, 9), "regular click selects group");
        CHECK_EQ(sel.anchorIndex, 4, "anchor at group start");
        CHECK_EQ(sel.focusIndex, 4, "focus at group start");

        [sel clickGroupRange:g1 commandKey:YES shiftKey:NO];
        checkSelection(sel, [NSIndexSet indexSet], "cmd on fully selected group deselects");
        CHECK_EQ(sel.focusIndex, 4, "focus still at group start");

        [sel togglePlaylistIndex:6];  // partial selection inside group
        [sel clickGroupRange:g1 commandKey:YES shiftKey:NO];
        checkSelection(sel, rangeSet(4, 9), "cmd on partial group selects whole");

        [sel selectPlaylistIndex:0 extendFromAnchor:NO];  // anchor 0
        [sel clickGroupRange:g1 commandKey:NO shiftKey:YES];
        checkSelection(sel, rangeSet(0, 9), "shift extends from anchor to group end");
        CHECK_EQ(sel.anchorIndex, 0, "shift keeps anchor");
        CHECK_EQ(sel.focusIndex, 4, "shift moves focus to group start");

        [sel selectPlaylistIndex:11 extendFromAnchor:NO];  // anchor 11 (past group)
        [sel clickGroupRange:g1 commandKey:NO shiftKey:YES];
        checkSelection(sel, rangeSet(4, 11), "shift extends from group start to anchor");
    }
    {
        g_context = "group-shift-no-anchor";
        PlaylistSelectionModel *sel = makeSelection(layout);
        [sel clickGroupRange:NSMakeRange(4, 6) commandKey:NO shiftKey:YES];
        checkSelection(sel, rangeSet(4, 9), "shift without anchor behaves like regular");
        CHECK_EQ(sel.anchorIndex, 4, "anchor set by fallback branch");
    }

    // --- Keyboard focus navigation (rows documented in the fixture header) ---
    {
        g_context = "moveFocus-skip-headers";
        PlaylistSelectionModel *sel = makeSelection(layout);

        [sel selectPlaylistIndex:3 extendFromAnchor:NO];  // track 3 = row 4
        NSInteger row = [sel moveFocusBy:1 extendSelection:NO];
        CHECK_EQ(sel.focusIndex, 4, "down from track 3 skips header+subgroup to track 4");
        CHECK_EQ(row, 7, "scroll row is track 4's row");
        checkSelection(sel, singleSet(4), "selection follows focus");

        row = [sel moveFocusBy:-1 extendSelection:NO];
        CHECK_EQ(sel.focusIndex, 3, "up from track 4 skips subgroup+header to track 3");
        CHECK_EQ(row, 4, "scroll row is track 3's row");
    }
    {
        g_context = "moveFocus-clamp-top";
        PlaylistSelectionModel *sel = makeSelection(layout);
        [sel selectPlaylistIndex:0 extendFromAnchor:NO];  // track 0 = row 1
        NSInteger row = [sel moveFocusBy:-1 extendSelection:NO];
        CHECK_EQ(sel.focusIndex, 0, "up from first track stays on it");
        CHECK_EQ(row, 1, "scroll row is first track's row");
    }
    {
        g_context = "moveFocus-clamp-bottom";
        PlaylistSelectionModel *sel = makeSelection(layout);
        [sel selectPlaylistIndex:11 extendFromAnchor:NO];  // track 11 = row 17
        NSInteger row = [sel moveFocusBy:1 extendSelection:NO];
        CHECK_EQ(sel.focusIndex, 11, "down from last track stays on it (skips trailing padding)");
        CHECK_EQ(row, 17, "scroll row is last track's row");
    }
    {
        g_context = "moveFocus-extend";
        PlaylistSelectionModel *sel = makeSelection(layout);
        [sel selectPlaylistIndex:4 extendFromAnchor:NO];
        [sel moveFocusBy:1 extendSelection:YES];
        checkSelection(sel, rangeSet(4, 5), "shift+down extends by one track");
        CHECK_EQ(sel.anchorIndex, 4, "anchor preserved");
        CHECK_EQ(sel.focusIndex, 5, "focus advanced");
    }
    {
        g_context = "moveFocus-no-focus";
        PlaylistSelectionModel *sel = makeSelection(layout);
        NSInteger row = [sel moveFocusBy:1 extendSelection:NO];
        // No focus: navigation starts from row 0 (header), lands on row 1 = track 0
        CHECK_EQ(sel.focusIndex, 0, "first down with no focus lands on track 0");
        CHECK_EQ(row, 1, "scroll row is track 0's row");
    }
    {
        g_context = "moveFocus-empty";
        PlaylistSelectionModel *sel = makeSelection(makeFlatLayout(0));
        NSInteger row = [sel moveFocusBy:1 extendSelection:NO];
        CHECK_EQ(row, -1, "empty list is a no-op");
        CHECK_EQ(sel.focusIndex, -1, "focus untouched");
    }
    {
        g_context = "moveFocus-flat";
        PlaylistSelectionModel *sel = makeSelection(makeFlatLayout(5));
        [sel selectPlaylistIndex:2 extendFromAnchor:NO];
        NSInteger row = [sel moveFocusBy:2 extendSelection:NO];
        CHECK_EQ(sel.focusIndex, 4, "flat mode moves by rows directly");
        CHECK_EQ(row, 4, "row == playlist index in flat mode");
        row = [sel moveFocusBy:10 extendSelection:NO];
        CHECK_EQ(sel.focusIndex, 4, "over-shoot clamps to last track");
        CHECK_EQ(row, 4, "clamped row");
    }

    printf("%s: %d checks, %d failures\n",
           g_failures == 0 ? "TESTS PASSED" : "TESTS FAILED", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;

    }
}
