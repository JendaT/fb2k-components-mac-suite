//
//  WidgetLayoutTests.mm
//  foo_jl_scrobble_mac
//
//  Unit tests for WidgetLayoutMath (album size solver, grid/bubble
//  geometry, aspect-fill crop, scroll clamping, footer text).
//  Compiled standalone (Foundation only); gating phase of
//  Scripts/build.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Core/WidgetLayoutMath.h"

#include <string>

static int g_failures = 0;
static int g_checks = 0;
static std::string g_context;

#define CHECK(cond, what)                                                        \
    do {                                                                         \
        g_checks++;                                                             \
        if (!(cond)) {                                                          \
            g_failures++;                                                       \
            printf("FAIL [%s] %s\n", g_context.c_str(), what);                  \
        }                                                                       \
    } while (0)

#define CHECK_NEAR(got, want, what)                                              \
    do {                                                                         \
        g_checks++;                                                             \
        double _g = (got), _w = (want);                                         \
        if (fabs(_g - _w) > 1e-6) {                                             \
            g_failures++;                                                       \
            printf("FAIL [%s] %s: got %f, expected %f\n", g_context.c_str(),    \
                   what, _g, _w);                                               \
        }                                                                       \
    } while (0)

#define CHECK_EQSTR(got, want, what)                                             \
    do {                                                                         \
        g_checks++;                                                             \
        NSString *_g = (got);                                                   \
        NSString *_w = (want);                                                  \
        if (![_g isEqualToString:_w]) {                                         \
            g_failures++;                                                       \
            printf("FAIL [%s] %s: got '%s', expected '%s'\n", g_context.c_str(),\
                   what, _g.UTF8String, _w.UTF8String);                         \
        }                                                                       \
    } while (0)

using namespace WidgetLayout;

int main(void) {
    @autoreleasepool {

    // --- albumSizeForWidth: clamped to [64, 150], closest to 130 target ---
    {
        g_context = "albumSize";
        for (CGFloat w = 100; w <= 2000; w += 50) {
            CGFloat size = albumSizeForWidth(w);
            CHECK(size >= kMinAlbumSize - 1e-9 && size <= kMaxAlbumSize + 1e-9,
                  "size within [min, max]");
        }
        // 674pt: 5 per row -> (674 - 24) / 5 = 130 exactly
        CHECK_NEAR(albumSizeForWidth(674.0), 130.0, "5-across hits the 130 target");
        // Narrow width: everything clamps to min
        CHECK_NEAR(albumSizeForWidth(100.0), kMinAlbumSize, "narrow clamps to min");
    }

    // --- Grid geometry: rows, height, centering, per-index rects ---
    {
        g_context = "grid";
        // width 500, album 100: (500+6)/(106) = 4 per row
        GridGeometry g = gridGeometryForWidth(500, 100, 10);
        CHECK(g.albumsPerRow == 4, "4 per row");
        CHECK(g.totalRows == 3, "10 albums in 3 rows");
        CHECK_NEAR(g.contentHeight, 3 * 100 + 2 * kAlbumSpacing, "content height");
        // grid width = 4*100 + 3*6 = 418; startX = 8 + (500-418)/2 = 49
        CHECK_NEAR(g.startX, 49.0, "centered start X");

        NSRect r0 = gridRectForIndex(g, 100, 200, 0);
        CHECK_NEAR(r0.origin.x, 49.0, "first tile at startX");
        CHECK_NEAR(r0.origin.y, 200.0, "first tile at topY");
        NSRect r5 = gridRectForIndex(g, 100, 200, 5);
        CHECK_NEAR(r5.origin.x, 49.0 + 1 * 106.0, "index 5 = row 1 col 1 x");
        CHECK_NEAR(r5.origin.y, 200.0 + 106.0, "index 5 = row 1 y");

        // Degenerate width never divides by zero
        GridGeometry tiny = gridGeometryForWidth(10, 100, 3);
        CHECK(tiny.albumsPerRow == 1, "at least one per row");
        CHECK(tiny.totalRows == 3, "one column stacks all");
    }

    // --- Bubble layout: area size and circle rects stay inside the area ---
    {
        g_context = "bubbles";
        CHECK_NEAR(bubbleAreaSize(400, 300), 300.0, "square area = min(w, h)");
        CHECK_NEAR(bubbleAreaSize(400, 50), 400.0, "tiny height falls back to width");

        for (NSInteger i = 0; i < kMaxBubbles; i++) {
            NSRect r = bubbleRectForIndex(i, 0, 0, 1000);
            CHECK(r.origin.x >= 0 && r.origin.y >= 0 &&
                  NSMaxX(r) <= 1000 && NSMaxY(r) <= 1000,
                  "circle inside the layout area");
            CHECK(r.size.width > 0 && fabs(r.size.width - r.size.height) < 1e-9,
                  "circle rect is square");
        }
        // Rank 1 is the biggest bubble
        CHECK(bubbleRectForIndex(0, 0, 0, 1000).size.width >
              bubbleRectForIndex(9, 0, 0, 1000).size.width,
              "bubble sizes decrease with rank");
        // Denormalization respects offsets
        NSRect shifted = bubbleRectForIndex(0, 50, 70, 1000);
        NSRect base = bubbleRectForIndex(0, 0, 0, 1000);
        CHECK_NEAR(shifted.origin.x - base.origin.x, 50.0, "x offset applied");
        CHECK_NEAR(shifted.origin.y - base.origin.y, 70.0, "y offset applied");
    }

    // --- Aspect-fill crop: center crop of the longer dimension ---
    {
        g_context = "aspectFill";
        // Wide image into square: crop sides
        NSRect src = aspectFillSourceRect(NSMakeSize(200, 100), NSMakeSize(100, 100));
        CHECK_NEAR(src.size.width, 100.0, "wide: cropped width");
        CHECK_NEAR(src.size.height, 100.0, "wide: full height");
        CHECK_NEAR(src.origin.x, 50.0, "wide: centered horizontally");

        // Tall image into square: crop top/bottom
        src = aspectFillSourceRect(NSMakeSize(100, 300), NSMakeSize(100, 100));
        CHECK_NEAR(src.size.height, 100.0, "tall: cropped height");
        CHECK_NEAR(src.origin.y, 100.0, "tall: centered vertically");

        // Matching aspect: full image
        src = aspectFillSourceRect(NSMakeSize(300, 300), NSMakeSize(100, 100));
        CHECK_NEAR(src.size.width, 300.0, "same aspect: full width");
        CHECK_NEAR(src.size.height, 300.0, "same aspect: full height");
    }

    // --- Scroll clamping ---
    {
        g_context = "scroll";
        CHECK_NEAR(clampScrollOffset(-10, 500, 200), 0.0, "clamps below to 0");
        CHECK_NEAR(clampScrollOffset(150, 500, 200), 150.0, "in range untouched");
        CHECK_NEAR(clampScrollOffset(9999, 500, 200), 300.0, "clamps to content-visible");
        CHECK_NEAR(clampScrollOffset(50, 100, 200), 0.0, "content fits: always 0");
    }

    // --- Footer status text ---
    {
        g_context = "footer";
        CHECK_EQSTR(WidgetFooterStatusText(YES, 15, NO, NO, 7, 2),
                    @"15 day streak | 7 scrobbles today | 2 queued", "full status");
        CHECK_EQSTR(WidgetFooterStatusText(YES, 15, NO, YES, 0, 0),
                    @"15 day streak (continue today) | 0 scrobbles today", "continuation");
        CHECK_EQSTR(WidgetFooterStatusText(YES, 42, YES, NO, 5, 0),
                    @"42+ day streak... | 5 scrobbles today", "discovery in progress");
        CHECK_EQSTR(WidgetFooterStatusText(NO, 15, NO, NO, 7, 0),
                    @"7 scrobbles today", "streak disabled");
        CHECK_EQSTR(WidgetFooterStatusText(YES, 1, NO, NO, 7, 0),
                    @"7 scrobbles today", "1-day streak hidden");
        CHECK_EQSTR(WidgetFooterStatusText(YES, 2, NO, NO, 250, 0),
                    @"2 day streak | 200+ scrobbles today", "200+ cap");
    }

    // --- Header geometry: charts mode pills centered between chrome ---
    {
        g_context = "header-charts";
        // width 500; text widths: viewMode 40, period 45, type 44
        HeaderGeometry h = headerGeometry(kPadding, 500, true, 40, 45, 44, 0);

        CHECK_NEAR(h.profileImageRect.origin.x, kPadding, "profile at left padding");
        CHECK_NEAR(h.profileImageRect.size.width, kProfileImageSize, "profile size");

        CHECK_NEAR(NSMaxX(h.linkButtonRect), kPadding + 500, "link at right edge");
        CHECK_NEAR(NSMaxX(h.reloadButtonRect), h.linkButtonRect.origin.x - kHeaderButtonGap,
                   "reload left of link");

        CHECK_NEAR(h.viewModePillRect.size.width, pillWidthForTextWidth(40), "view mode width");
        CHECK_NEAR(h.periodPillRect.size.width, pillWidthForTextWidth(45), "period width");
        CHECK_NEAR(h.typePillRect.size.width, pillWidthForTextWidth(44), "type width");
        CHECK(h.trackCountPillRect.size.width == 0, "no track-count pill in charts mode");

        CHECK_NEAR(h.periodPillRect.origin.x, NSMaxX(h.viewModePillRect) + kPillGap,
                   "pills laid out left to right");
        CHECK_NEAR(h.typePillRect.origin.x, NSMaxX(h.periodPillRect) + kPillGap,
                   "type follows period");

        // Pills centered in the nav area between profile and buttons
        CGFloat navStart = kPadding + kProfileImageSize + kHeaderSpacing;
        CGFloat navWidth = 500 - kProfileImageSize - kHeaderSpacing -
                           (kHeaderButtonSize * 2 + kHeaderButtonGap) - kHeaderSpacing;
        CGFloat pillsCenter = (h.viewModePillRect.origin.x + NSMaxX(h.typePillRect)) / 2;
        CHECK_NEAR(pillsCenter, navStart + navWidth / 2, "pill row centered in nav area");

        CHECK_NEAR(h.headerEndY, kPadding + kHeaderRowHeight + kHeaderSpacing, "header end");

        // All pills share the vertical center of the header row
        CHECK_NEAR(NSMidY(h.viewModePillRect), kPadding + kHeaderRowHeight / 2, "pill centered");
    }

    // --- Header geometry: tracks mode ---
    {
        g_context = "header-tracks";
        HeaderGeometry h = headerGeometry(kPadding, 500, false, 40, 0, 0, 52);
        CHECK(h.periodPillRect.size.width == 0, "no period pill in tracks mode");
        CHECK(h.typePillRect.size.width == 0, "no type pill in tracks mode");
        CHECK_NEAR(h.trackCountPillRect.size.width, pillWidthForTextWidth(52), "count pill width");
        CHECK_NEAR(h.trackCountPillRect.origin.x, NSMaxX(h.viewModePillRect) + kPillGap,
                   "count pill follows view mode pill");
    }

    // --- Content geometry: track rows with scrolling ---
    {
        g_context = "content-tracks";
        // bounds 400x300, header ends at 42 -> footer at 300-20-8=272,
        // content area from 42 to 264 (height 222)
        ContentGeometry c = contentGeometry(NSMakeSize(400, 300), 42,
                                            ContentMode::TrackRows, 10, 0);
        CHECK_NEAR(c.footerY, 272.0, "footer position");
        CHECK_NEAR(c.contentAreaRect.origin.y, 42.0, "content starts after header");
        CHECK_NEAR(c.contentAreaRect.size.height, 222.0, "content height");
        CHECK_NEAR(c.contentTotalHeight, 10 * kTrackRowHeight, "total content height");
        CHECK(c.itemRects.size() == 10, "one rect per row");
        CHECK_NEAR(c.itemRects[0].origin.y, 42.0, "first row at content start");
        CHECK_NEAR(c.itemRects[1].origin.y, 42.0 + kTrackRowHeight, "rows stacked");

        // Scroll offset shifts rows and is clamped to content bounds
        ContentGeometry scrolled = contentGeometry(NSMakeSize(400, 300), 42,
                                                   ContentMode::TrackRows, 10, 100);
        CHECK_NEAR(scrolled.scrollOffset, 100.0, "valid offset kept");
        CHECK_NEAR(scrolled.itemRects[0].origin.y, 42.0 - 100.0, "rows shifted by scroll");

        ContentGeometry over = contentGeometry(NSMakeSize(400, 300), 42,
                                               ContentMode::TrackRows, 10, 9999);
        CHECK_NEAR(over.scrollOffset, 10 * kTrackRowHeight - 222.0, "offset clamped to max");
    }

    // --- Content geometry: grid mode computes size, height, and rects together ---
    {
        g_context = "content-grid";
        ContentGeometry c = contentGeometry(NSMakeSize(400, 600), 42,
                                            ContentMode::Grid, 12, 0);
        CHECK(c.albumSize >= kMinAlbumSize && c.albumSize <= kMaxAlbumSize, "album size solved");
        CHECK(c.itemRects.size() == 12, "one rect per album");
        CHECK(c.contentTotalHeight > 0, "grid reports scrollable height");
        // First rect at the content start, consistent with the solved size
        CHECK_NEAR(c.itemRects[0].origin.y, 42.0, "first tile at content start");
        CHECK_NEAR(c.itemRects[0].size.width, c.albumSize, "tile uses solved size");

        ContentGeometry empty = contentGeometry(NSMakeSize(400, 600), 42,
                                                ContentMode::Grid, 0, 50);
        CHECK(empty.itemRects.empty(), "no rects for empty grid");
        CHECK_NEAR(empty.contentTotalHeight, 0.0, "empty grid has no height");
        CHECK_NEAR(empty.scrollOffset, 0.0, "scroll reset when content vanishes");
    }

    // --- Content geometry: bubbles never scroll, capped at 10 ---
    {
        g_context = "content-bubbles";
        ContentGeometry c = contentGeometry(NSMakeSize(400, 500), 42,
                                            ContentMode::Bubbles, 25, 80);
        CHECK(c.itemRects.size() == (size_t)kMaxBubbles, "capped at kMaxBubbles");
        CHECK_NEAR(c.contentTotalHeight, 0.0, "bubbles report no scroll height");
        CHECK_NEAR(c.scrollOffset, 0.0, "scroll forced to zero");
        // Every bubble inside the content area
        for (const NSRect &r : c.itemRects) {
            CHECK(r.origin.y >= c.contentAreaRect.origin.y - 1e-6 &&
                  NSMaxY(r) <= NSMaxY(c.contentAreaRect) + 1e-6,
                  "bubble within content area vertically");
        }
    }

    // --- Footer error text ---
    {
        g_context = "footer-error";
        CHECK_EQSTR(WidgetFooterErrorText(@"Network unreachable"),
                    @"Network unreachable (click refresh)", "short error");

        NSString *longError = [@"" stringByPaddingToLength:80 withString:@"x" startingAtIndex:0];
        NSString *result = WidgetFooterErrorText(longError);
        CHECK(result.length == 60 + (NSInteger)strlen(" (click refresh)"),
              "long error truncated to 60 chars");
        CHECK([result hasSuffix:@"... (click refresh)"], "ellipsis + hint");
    }

    }  // autoreleasepool

    printf("WidgetLayoutTests: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
