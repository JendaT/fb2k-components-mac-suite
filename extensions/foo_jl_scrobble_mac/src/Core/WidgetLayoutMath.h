//
//  WidgetLayoutMath.h
//  foo_jl_scrobble_mac
//
//  Pure geometry and text assembly for the scrobble widget, extracted
//  from ScrobbleWidgetView's draw methods so the layout math is
//  unit-testable. Foundation-only (NSGeometry, NSString) -- no AppKit,
//  no drawing. The view feeds sizes in and draws from the results.
//

#pragma once

#import <Foundation/Foundation.h>

#include <cmath>
#include <vector>

namespace WidgetLayout {

// Shared layout constants (single definition; the view uses these)
static const CGFloat kMinAlbumSize = 64.0;
static const CGFloat kMaxAlbumSize = 150.0;
static const CGFloat kTargetAlbumSize = 130.0;
static const CGFloat kAlbumSpacing = 6.0;
static const CGFloat kPadding = 8.0;
static const NSInteger kMaxBubbles = 10;
static const CGFloat kFooterHeight = 20.0;
static const CGFloat kTrackRowHeight = 44.0;

// Header row constants
static const CGFloat kProfileImageSize = 28.0;
static const CGFloat kHeaderSpacing = 6.0;
static const CGFloat kHeaderRowHeight = 28.0;
static const CGFloat kHeaderButtonSize = 22.0;
static const CGFloat kHeaderButtonGap = 2.0;
static const CGFloat kPillChevronWidth = 8.0;
static const CGFloat kPillPadH = 8.0;
static const CGFloat kPillGap = 4.0;
static const CGFloat kPillHeight = 20.0;

/// Optimal album tile size: try 3-8 tiles per row, clamp each candidate
/// to [min, max], pick the candidate closest to the 130px target.
inline CGFloat albumSizeForWidth(CGFloat availableWidth) {
    CGFloat bestSize = kMinAlbumSize;

    for (NSInteger albumsPerRow = 3; albumsPerRow <= 8; albumsPerRow++) {
        CGFloat totalSpacing = kAlbumSpacing * (albumsPerRow - 1);
        CGFloat size = (availableWidth - totalSpacing) / albumsPerRow;

        size = MAX(kMinAlbumSize, MIN(kMaxAlbumSize, size));

        if (fabs(size - kTargetAlbumSize) < fabs(bestSize - kTargetAlbumSize)) {
            bestSize = size;
        }
    }

    return bestSize;
}

/// Grid geometry for `count` tiles of `albumSize` in `width` points
struct GridGeometry {
    NSInteger albumsPerRow;
    NSInteger totalRows;
    CGFloat contentHeight;  // full grid height (for scroll bounds)
    CGFloat startX;         // left edge of the centered grid (incl. padding)
};

inline GridGeometry gridGeometryForWidth(CGFloat width, CGFloat albumSize, NSInteger count) {
    GridGeometry g;
    g.albumsPerRow = (NSInteger)((width + kAlbumSpacing) / (albumSize + kAlbumSpacing));
    if (g.albumsPerRow < 1) g.albumsPerRow = 1;

    g.totalRows = (count + g.albumsPerRow - 1) / g.albumsPerRow;
    g.contentHeight = g.totalRows * albumSize + (g.totalRows - 1) * kAlbumSpacing;

    CGFloat totalGridWidth = g.albumsPerRow * albumSize + (g.albumsPerRow - 1) * kAlbumSpacing;
    g.startX = kPadding + (width - totalGridWidth) / 2;
    return g;
}

/// Rect of tile `index` in the grid, rows growing downward from `topY`
inline NSRect gridRectForIndex(const GridGeometry &g, CGFloat albumSize,
                               CGFloat topY, NSInteger index) {
    NSInteger row = index / g.albumsPerRow;
    NSInteger col = index % g.albumsPerRow;
    return NSMakeRect(g.startX + col * (albumSize + kAlbumSpacing),
                      topY + row * (albumSize + kAlbumSpacing),
                      albumSize, albumSize);
}

/// Side of the square bubble-layout area within the given space
inline CGFloat bubbleAreaSize(CGFloat width, CGFloat availableHeight) {
    CGFloat areaSize = MIN(width, availableHeight);
    if (areaSize < 100) areaSize = width;  // Fallback
    return areaSize;
}

/// Circle rect for bubble `index` (0..kMaxBubbles-1), denormalized from
/// the hand-tuned packing table into a square area at (offsetX, offsetY)
inline NSRect bubbleRectForIndex(NSInteger index, CGFloat offsetX, CGFloat offsetY,
                                 CGFloat areaSize) {
    // Normalized circle positions (centerX, centerY, radius) in 0..1 space
    struct CircleLayout { float centerX; float centerY; float radius; };
    static const CircleLayout circles[kMaxBubbles] = {
        {0.7576f, 0.2424f, 0.2147f},  // circle 1
        {0.5791f, 0.7355f, 0.1801f},  // circle 2
        {0.2750f, 0.6504f, 0.1316f},  // circle 3
        {0.1524f, 0.4207f, 0.1247f},  // circle 4
        {0.2803f, 0.2312f, 0.0997f},  // circle 5
        {0.4602f, 0.1589f, 0.0900f},  // circle 6
        {0.4695f, 0.3374f, 0.0845f},  // circle 7
        {0.5686f, 0.4725f, 0.0790f},  // circle 8
        {0.4117f, 0.4902f, 0.0748f},  // circle 9
        {0.3324f, 0.3817f, 0.0554f},  // circle 10
    };

    const CircleLayout &layout = circles[index];
    CGFloat cx = offsetX + layout.centerX * areaSize;
    CGFloat cy = offsetY + layout.centerY * areaSize;
    CGFloat r = layout.radius * areaSize;
    return NSMakeRect(cx - r, cy - r, r * 2, r * 2);
}

/// Source rect cropping `imageSize` to fill `targetSize`'s aspect ratio
/// (center crop: wider images lose sides, taller images lose top/bottom)
inline NSRect aspectFillSourceRect(NSSize imageSize, NSSize targetSize) {
    CGFloat imageAspect = imageSize.width / imageSize.height;
    CGFloat viewAspect = targetSize.width / targetSize.height;

    if (imageAspect > viewAspect) {
        // Image is wider - crop sides
        CGFloat newWidth = imageSize.height * viewAspect;
        CGFloat x = (imageSize.width - newWidth) / 2;
        return NSMakeRect(x, 0, newWidth, imageSize.height);
    }
    // Image is taller - crop top/bottom
    CGFloat newHeight = imageSize.width / viewAspect;
    CGFloat y = (imageSize.height - newHeight) / 2;
    return NSMakeRect(0, y, imageSize.width, newHeight);
}

/// Scroll offset clamped to [0, contentHeight - visibleHeight]
inline CGFloat clampScrollOffset(CGFloat offset, CGFloat contentHeight,
                                 CGFloat visibleHeight) {
    CGFloat maxOffset = MAX((CGFloat)0, contentHeight - visibleHeight);
    return MAX((CGFloat)0, MIN(offset, maxOffset));
}

/// Dropdown pill width for a measured title width:
/// padding + text + gap + chevron + padding
inline CGFloat pillWidthForTextWidth(CGFloat textWidth) {
    return kPillPadH + textWidth + 4 + kPillChevronWidth + kPillPadH;
}

/// Header row: [profile] [centered pills] [reload] [link].
/// Text widths are measured by the caller (fonts are AppKit); unused
/// pill rects come back as NSZeroRect.
struct HeaderGeometry {
    NSRect profileImageRect;
    NSRect linkButtonRect;
    NSRect reloadButtonRect;
    NSRect viewModePillRect;
    NSRect periodPillRect;       // charts mode only
    NSRect typePillRect;         // charts mode only
    NSRect trackCountPillRect;   // tracks mode only
    CGFloat headerEndY;          // content starts here
};

inline HeaderGeometry headerGeometry(CGFloat topY, CGFloat width, bool chartsMode,
                                     CGFloat viewModeTextWidth, CGFloat periodTextWidth,
                                     CGFloat typeTextWidth, CGFloat trackCountTextWidth) {
    HeaderGeometry h;
    h.profileImageRect = NSMakeRect(kPadding, topY, kProfileImageSize, kProfileImageSize);

    CGFloat buttonY = topY + (kHeaderRowHeight - kHeaderButtonSize) / 2;
    h.linkButtonRect = NSMakeRect(kPadding + width - kHeaderButtonSize, buttonY,
                                  kHeaderButtonSize, kHeaderButtonSize);
    h.reloadButtonRect = NSMakeRect(h.linkButtonRect.origin.x - kHeaderButtonSize - kHeaderButtonGap,
                                    buttonY, kHeaderButtonSize, kHeaderButtonSize);

    // Pills are centered in the space between profile image and buttons
    CGFloat navAreaStart = kPadding + kProfileImageSize + kHeaderSpacing;
    CGFloat navAreaWidth = width - kProfileImageSize - kHeaderSpacing -
                           (kHeaderButtonSize * 2 + kHeaderButtonGap) - kHeaderSpacing;
    CGFloat navAreaCenterX = navAreaStart + navAreaWidth / 2;
    CGFloat pillY = topY + kHeaderRowHeight / 2 - kPillHeight / 2;

    CGFloat viewModePillWidth = pillWidthForTextWidth(viewModeTextWidth);
    h.periodPillRect = NSZeroRect;
    h.typePillRect = NSZeroRect;
    h.trackCountPillRect = NSZeroRect;

    if (chartsMode) {
        // [Charts v] [Weekly v] [Albums v]
        CGFloat periodPillWidth = pillWidthForTextWidth(periodTextWidth);
        CGFloat typePillWidth = pillWidthForTextWidth(typeTextWidth);
        CGFloat totalWidth = viewModePillWidth + kPillGap + periodPillWidth + kPillGap + typePillWidth;
        CGFloat startX = navAreaCenterX - totalWidth / 2;

        h.viewModePillRect = NSMakeRect(startX, pillY, viewModePillWidth, kPillHeight);
        h.periodPillRect = NSMakeRect(NSMaxX(h.viewModePillRect) + kPillGap, pillY,
                                      periodPillWidth, kPillHeight);
        h.typePillRect = NSMakeRect(NSMaxX(h.periodPillRect) + kPillGap, pillY,
                                    typePillWidth, kPillHeight);
    } else {
        // [Tracks v] [Show: 10 v]
        CGFloat countPillWidth = pillWidthForTextWidth(trackCountTextWidth);
        CGFloat totalWidth = viewModePillWidth + kPillGap + countPillWidth;
        CGFloat startX = navAreaCenterX - totalWidth / 2;

        h.viewModePillRect = NSMakeRect(startX, pillY, viewModePillWidth, kPillHeight);
        h.trackCountPillRect = NSMakeRect(NSMaxX(h.viewModePillRect) + kPillGap, pillY,
                                          countPillWidth, kPillHeight);
    }

    h.headerEndY = topY + kHeaderRowHeight + kHeaderSpacing;
    return h;
}

/// What fills the content area between header and footer
enum class ContentMode { Grid, Bubbles, TrackRows };

/// Full content-area geometry: computed BEFORE drawing so both the draw
/// pass and hit-testing consume the same rects (no draw side effects)
struct ContentGeometry {
    NSRect contentAreaRect;
    CGFloat contentTotalHeight;      // for scroll bounds (0 = fits)
    CGFloat scrollOffset;            // input offset clamped to valid range
    CGFloat albumSize;               // grid tile side (0 in other modes)
    std::vector<NSRect> itemRects;   // album tiles, bubbles, or track rows
    CGFloat footerY;
};

inline ContentGeometry contentGeometry(NSSize boundsSize, CGFloat headerEndY,
                                       ContentMode mode, NSInteger itemCount,
                                       CGFloat requestedScrollOffset) {
    ContentGeometry c;
    CGFloat contentWidth = boundsSize.width - kPadding * 2;
    c.footerY = boundsSize.height - kFooterHeight - kPadding;

    CGFloat contentStartY = headerEndY;
    CGFloat availableHeight = (c.footerY - kPadding) - contentStartY;
    c.contentAreaRect = NSMakeRect(kPadding, contentStartY, contentWidth, availableHeight);
    c.albumSize = 0;

    // Content height first, so the scroll clamp uses CURRENT content
    GridGeometry grid = {};
    switch (mode) {
        case ContentMode::TrackRows:
            c.contentTotalHeight = itemCount * kTrackRowHeight;
            break;
        case ContentMode::Bubbles:
            c.contentTotalHeight = 0;  // bubbles fit the visible area
            break;
        case ContentMode::Grid:
            c.albumSize = albumSizeForWidth(contentWidth);
            grid = gridGeometryForWidth(contentWidth, c.albumSize, itemCount);
            c.contentTotalHeight = itemCount > 0 ? grid.contentHeight : 0;
            break;
    }
    c.scrollOffset = clampScrollOffset(requestedScrollOffset, c.contentTotalHeight,
                                       availableHeight);

    CGFloat scrolledStartY = contentStartY - c.scrollOffset;

    switch (mode) {
        case ContentMode::TrackRows:
            for (NSInteger i = 0; i < itemCount; i++) {
                c.itemRects.push_back(NSMakeRect(kPadding, scrolledStartY + i * kTrackRowHeight,
                                                 contentWidth, kTrackRowHeight));
            }
            break;

        case ContentMode::Bubbles: {
            CGFloat bubbleSize = MIN(contentWidth, availableHeight);
            CGFloat bubbleStartY = contentStartY + (availableHeight - bubbleSize) / 2;
            CGFloat areaSize = bubbleAreaSize(contentWidth, bubbleSize);
            CGFloat offsetX = kPadding + (contentWidth - areaSize) / 2;
            NSInteger count = MIN(itemCount, kMaxBubbles);
            for (NSInteger i = 0; i < count; i++) {
                c.itemRects.push_back(bubbleRectForIndex(i, offsetX, bubbleStartY, areaSize));
            }
            break;
        }

        case ContentMode::Grid:
            for (NSInteger i = 0; i < itemCount; i++) {
                c.itemRects.push_back(gridRectForIndex(grid, c.albumSize, scrolledStartY, i));
            }
            break;
    }

    return c;
}

}  // namespace WidgetLayout

/// Footer status line, e.g.
/// "15 day streak | 7 scrobbles today | 2 queued"
/// "15 day streak (continue today) | 0 scrobbles today"
/// "42+ day streak... | 200+ scrobbles today"
static inline NSString *WidgetFooterStatusText(BOOL streakEnabled,
                                               NSInteger streakDays,
                                               BOOL discoveryInProgress,
                                               BOOL needsContinuation,
                                               NSInteger scrobbledToday,
                                               NSInteger queueCount) {
    NSMutableString *statusText = [NSMutableString string];

    // Streak (shown first when >= 2 days)
    if (streakEnabled && streakDays >= 2) {
        if (discoveryInProgress) {
            [statusText appendFormat:@"%ld+ day streak...", (long)streakDays];
        } else if (needsContinuation) {
            [statusText appendFormat:@"%ld day streak (continue today)", (long)streakDays];
        } else {
            [statusText appendFormat:@"%ld day streak", (long)streakDays];
        }
        [statusText appendString:@" | "];
    }

    // Scrobbled today
    if (scrobbledToday >= 200) {
        [statusText appendString:@"200+ scrobbles today"];
    } else {
        [statusText appendFormat:@"%ld scrobbles today", (long)scrobbledToday];
    }

    // Queue status
    if (queueCount > 0) {
        [statusText appendFormat:@" | %ld queued", (long)queueCount];
    }

    return statusText;
}

/// Error footer: message truncated to 60 chars with a retry hint appended
static inline NSString *WidgetFooterErrorText(NSString *errorMessage) {
    NSString *displayError = errorMessage;
    if (displayError.length > 60) {
        displayError = [[displayError substringToIndex:57] stringByAppendingString:@"..."];
    }
    return [NSString stringWithFormat:@"%@ (click refresh)", displayError];
}
