#import "AlbumGridView.h"
#import "../Core/AlbumItem.h"
#import "../Core/AlbumArtCache.h"
#import "../fb2k_sdk.h"
#import "../../../../shared/UIStyles.h"

NSPasteboardType const AlbumViewVancedPasteboardType = @"com.foobar2000.albumviewvanced.albums";

static const CGFloat kCellPadding      = 12.0;
static const CGFloat kContentInsetLeft = 10.0;
static const CGFloat kTextAreaHeight   = 48.0;
static const CGFloat kTrackRowHeight   = 22.0;
static const CGFloat kTrackListPadding = 8.0;
static const CGFloat kCornerRadius     = 6.0;
static const CGFloat kRatingWidth      = 70.0;

#pragma mark - Layout helpers

/// Cell size = thumbnail + text area + padding between cells
static inline CGFloat cellTotalHeight(CGFloat thumbSize) {
    return thumbSize + kTextAreaHeight + kCellPadding;
}

static inline NSInteger columnsForWidth(CGFloat viewWidth, CGFloat thumbSize) {
    NSInteger cols = (NSInteger)floor((viewWidth + kCellPadding) / (thumbSize + kCellPadding));
    return MAX(cols, 1);
}

static inline CGFloat cellWidth(CGFloat viewWidth, NSInteger cols) {
    return floor((viewWidth - kCellPadding * (cols - 1)) / cols);
}

static inline CGFloat contentWidthForView(CGFloat viewWidth) {
    return MAX(1.0, viewWidth - kContentInsetLeft);
}

@implementation AlbumGridView {
    NSInteger _selectedAlbumIndex;
    NSInteger _selectedTrackIndex;
    NSInteger _expandedAlbumIndex;
    NSInteger _hoveredAlbumIndex;
    NSImage  *_placeholderImage;
    NSTrackingArea *_trackingArea;

    // Drag state
    NSPoint   _mouseDownPoint;
    BOOL      _dragInitiated;

    // Delayed expand/collapse (to avoid expand on double-click)
    NSTimer  *_expandTimer;
    NSInteger _pendingExpandAlbumIndex;
    BOOL      _pendingExpandShouldCollapse;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _thumbnailSize = 140.0;
        _selectedAlbumIndex = NSNotFound;
        _selectedTrackIndex = NSNotFound;
        _expandedAlbumIndex = NSNotFound;
        _hoveredAlbumIndex = NSNotFound;
        _pendingExpandAlbumIndex = NSNotFound;
        _albums = @[];
        self.wantsLayer = YES;
    }
    return self;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_trackingArea) [self removeTrackingArea:_trackingArea];
    _trackingArea = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow
               owner:self
            userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    GridHitResult hit = [self hitTestAtPoint:point];
    NSInteger newHover = (hit.trackIndex == NSNotFound) ? hit.albumIndex : NSNotFound;
    if (newHover != _hoveredAlbumIndex) {
        _hoveredAlbumIndex = newHover;
        [self setNeedsDisplay:YES];
    }
}

- (void)mouseExited:(NSEvent *)event {
    if (_hoveredAlbumIndex != NSNotFound) {
        _hoveredAlbumIndex = NSNotFound;
        [self setNeedsDisplay:YES];
    }
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }

- (NSInteger)expandedAlbumIndex { return _expandedAlbumIndex; }

- (void)reloadData {
    [self recalcFrameHeight];
    [self setNeedsDisplay:YES];
}

- (void)collapseExpandedAlbum {
    _expandedAlbumIndex = NSNotFound;
    _selectedTrackIndex = NSNotFound;
    [self reloadData];
}

- (nullable AlbumItem *)selectedAlbum {
    if (_selectedAlbumIndex == NSNotFound || !_albums) return nil;
    if (_selectedAlbumIndex >= (NSInteger)_albums.count) return nil;
    return _albums[_selectedAlbumIndex];
}

- (nullable AlbumTrack *)selectedTrack {
    AlbumItem *album = [self selectedAlbum];
    if (!album || _selectedTrackIndex == NSNotFound) return nil;
    if (_selectedTrackIndex >= (NSInteger)album.tracks.count) return nil;
    return album.tracks[_selectedTrackIndex];
}

#pragma mark - Layout calculation

- (void)recalcFrameHeight {
    CGFloat w = self.superview ? self.superview.bounds.size.width : self.bounds.size.width;
    if (w <= 0) w = 300;

    CGFloat contentW = contentWidthForView(w);
    NSInteger cols = columnsForWidth(contentW, _thumbnailSize);
    NSInteger albumCount = (NSInteger)_albums.count;
    CGFloat cw = cellWidth(contentW, cols);
    CGFloat ch = cellTotalHeight(cw);

    CGFloat totalHeight = 0;
    NSInteger row = 0;
    for (NSInteger i = 0; i < albumCount; i += cols) {
        totalHeight += ch;

        // If expanded album is in this row, add track list height
        if (_expandedAlbumIndex != NSNotFound) {
            NSInteger rowStart = i;
            NSInteger rowEnd = MIN(i + cols, albumCount);
            if (_expandedAlbumIndex >= rowStart && _expandedAlbumIndex < rowEnd) {
                AlbumItem *expanded = _albums[_expandedAlbumIndex];
                totalHeight += [self trackListHeightForAlbum:expanded width:w];
            }
        }
        row++;
    }

    totalHeight += kCellPadding;
    if (totalHeight < 100) totalHeight = 100;

    NSRect f = self.frame;
    f.size.height = totalHeight;
    f.size.width = w;
    [self setFrameSize:f.size];
}

static const CGFloat kTrackHeaderHeight = 28.0;

- (CGFloat)trackListHeightForAlbum:(AlbumItem *)album width:(CGFloat)viewWidth {
    return kTrackListPadding * 2 + kTrackHeaderHeight + album.trackCount * kTrackRowHeight;
}

#pragma mark - Drawing

- (NSAttributedString *)starStringForRating:(NSInteger)rating enabled:(BOOL)enabled {
    NSMutableAttributedString *stars = [[NSMutableAttributedString alloc] init];
    NSFont *font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
    for (NSInteger i = 1; i <= 5; i++) {
        BOOL filled = i <= rating;
        NSColor *color;
        if (!enabled) {
            color = [fb2k_ui::secondaryTextColor() colorWithAlphaComponent:0.25];
        } else if (filled) {
            color = [NSColor controlAccentColor];
        } else {
            color = [fb2k_ui::secondaryTextColor() colorWithAlphaComponent:0.55];
        }
        [stars appendAttributedString:[[NSAttributedString alloc] initWithString:(filled ? @"★" : @"☆")
                                                                      attributes:@{NSFontAttributeName: font,
                                                                                   NSForegroundColorAttributeName: color}]];
    }
    return stars;
}

- (void)drawRating:(NSInteger)rating inRect:(NSRect)rect enabled:(BOOL)enabled {
    NSAttributedString *stars = [self starStringForRating:rating enabled:enabled];
    NSSize size = stars.size;
    CGFloat x = rect.origin.x + MAX(0, (rect.size.width - size.width) / 2.0);
    CGFloat y = rect.origin.y + round((rect.size.height - size.height) / 2.0);
    [stars drawAtPoint:NSMakePoint(x, y)];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    NSRect bounds = self.bounds;
    CGFloat w = bounds.size.width;
    if (w <= 0 || !_albums || _albums.count == 0) return;

    CGFloat contentW = contentWidthForView(w);
    NSInteger cols = columnsForWidth(contentW, _thumbnailSize);
    CGFloat cw = cellWidth(contentW, cols);
    CGFloat thumbSize = cw;
    CGFloat ch = cellTotalHeight(cw);

    if (!_placeholderImage || fabs(_placeholderImage.size.width - thumbSize) > 1.0) {
        _placeholderImage = [AlbumArtCache placeholderImageOfSize:thumbSize];
    }

    BOOL dark = fb2k_ui::isDarkMode();
    NSColor *bgText = dark ? [NSColor colorWithWhite:1.0 alpha:0.9]
                           : [NSColor colorWithWhite:0.1 alpha:0.9];
    NSColor *secondaryText = dark ? [NSColor colorWithWhite:1.0 alpha:0.55]
                                  : [NSColor colorWithWhite:0.0 alpha:0.55];
    NSColor *selectionColor = [[NSColor controlAccentColor] colorWithAlphaComponent:0.35];

    NSFont *artistFont = [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold];
    NSFont *albumFont  = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
    NSFont *yearFont   = [NSFont systemFontOfSize:10.0 weight:NSFontWeightRegular];

    NSDictionary *artistAttrs = @{
        NSFontAttributeName: artistFont,
        NSForegroundColorAttributeName: bgText,
    };
    NSDictionary *albumAttrs = @{
        NSFontAttributeName: albumFont,
        NSForegroundColorAttributeName: bgText,
    };
    NSDictionary *yearAttrs = @{
        NSFontAttributeName: yearFont,
        NSForegroundColorAttributeName: secondaryText,
    };

    NSInteger albumCount = (NSInteger)_albums.count;
    CGFloat y = 0;

    for (NSInteger rowStart = 0; rowStart < albumCount; rowStart += cols) {
        NSInteger rowEnd = MIN(rowStart + cols, albumCount);

        for (NSInteger i = rowStart; i < rowEnd; i++) {
            NSInteger col = i - rowStart;
            CGFloat x = kContentInsetLeft + col * (cw + kCellPadding);
            NSRect cellRect = NSMakeRect(x, y, cw, ch);

            if (!NSIntersectsRect(cellRect, dirtyRect)) continue;

            AlbumItem *album = _albums[i];

            // Selection highlight
            if (i == _selectedAlbumIndex) {
                [selectionColor setFill];
                [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(cellRect, -2, -2)
                                                xRadius:kCornerRadius
                                                yRadius:kCornerRadius] fill];
            }

            // Cover art
            NSRect artRect = NSMakeRect(x, y, thumbSize, thumbSize);
            NSImage *art = [[AlbumArtCache sharedCache] imageForPath:album.artPath
                                                                size:thumbSize
                                                          completion:^(NSImage *img) {
                [self setNeedsDisplayInRect:cellRect];
            }];

            NSImage *toDraw = art ?: _placeholderImage;
            if (toDraw) {
                NSBezierPath *clipPath = [NSBezierPath bezierPathWithRoundedRect:artRect
                                                                        xRadius:kCornerRadius
                                                                        yRadius:kCornerRadius];
                [NSGraphicsContext saveGraphicsState];
                [clipPath addClip];
                [toDraw drawInRect:artRect
                          fromRect:NSZeroRect
                         operation:NSCompositingOperationSourceOver
                          fraction:1.0
                    respectFlipped:YES
                             hints:nil];

                // Hover overlay: dim + play button
                if (i == _hoveredAlbumIndex) {
                    [[NSColor colorWithWhite:0.0 alpha:0.35] setFill];
                    NSRectFillUsingOperation(artRect, NSCompositingOperationSourceOver);

                    // Play triangle
                    CGFloat triSize = thumbSize * 0.25;
                    CGFloat cx = NSMidX(artRect);
                    CGFloat cy = NSMidY(artRect);

                    // Circle behind play icon
                    CGFloat circR = triSize * 0.9;
                    NSRect circRect = NSMakeRect(cx - circR, cy - circR, circR * 2, circR * 2);
                    [[NSColor colorWithWhite:0.0 alpha:0.5] setFill];
                    [[NSBezierPath bezierPathWithOvalInRect:circRect] fill];

                    // Triangle pointing right
                    NSBezierPath *tri = [NSBezierPath bezierPath];
                    CGFloat halfH = triSize * 0.5;
                    CGFloat offset = triSize * 0.15; // slight right shift to center visually
                    [tri moveToPoint:NSMakePoint(cx - halfH * 0.5 + offset, cy - halfH)];
                    [tri lineToPoint:NSMakePoint(cx + halfH * 0.7 + offset, cy)];
                    [tri lineToPoint:NSMakePoint(cx - halfH * 0.5 + offset, cy + halfH)];
                    [tri closePath];
                    [[NSColor colorWithWhite:1.0 alpha:0.95] setFill];
                    [tri fill];
                }

                [NSGraphicsContext restoreGraphicsState];
            }

            // Text below cover
            CGFloat textX = x + 2;
            CGFloat textW = cw - 4;
            CGFloat textY = y + thumbSize + 3;

            NSRect artistRect = NSMakeRect(textX, textY, textW, 14);
            [album.artistName drawWithRect:artistRect
                                   options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
                                attributes:artistAttrs];

            NSRect albumRect = NSMakeRect(textX, textY + 14, textW, 14);
            [album.albumName drawWithRect:albumRect
                                  options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
                               attributes:albumAttrs];

            if (album.year.length > 0) {
                NSRect yearRect = NSMakeRect(textX, textY + 28, MAX(0, textW - kRatingWidth - 4), 13);
                [album.year drawWithRect:yearRect
                                 options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
                              attributes:yearAttrs];
            }

            NSRect ratingRect = NSMakeRect(textX + textW - kRatingWidth, textY + 27, kRatingWidth, 15);
            [self drawRating:album.rating inRect:ratingRect enabled:YES];
        }

        y += ch;

        // Draw expanded track list if this row contains the expanded album
        if (_expandedAlbumIndex != NSNotFound &&
            _expandedAlbumIndex >= rowStart && _expandedAlbumIndex < rowEnd) {
            AlbumItem *expanded = _albums[_expandedAlbumIndex];
            CGFloat trackListH = [self trackListHeightForAlbum:expanded width:w];
            NSRect trackRect = NSMakeRect(0, y, w, trackListH);

            if (NSIntersectsRect(trackRect, dirtyRect)) {
                [self drawTrackListForAlbum:expanded inRect:trackRect dark:dark];
            }
            y += trackListH;
        }
    }
}

- (void)drawTrackListForAlbum:(AlbumItem *)album inRect:(NSRect)rect dark:(BOOL)dark {
    NSColor *trackBg = dark ? [NSColor colorWithWhite:0.12 alpha:0.8]
                            : [NSColor colorWithWhite:0.95 alpha:0.8];
    [trackBg setFill];
    NSRectFill(rect);

    [[NSColor separatorColor] setFill];
    NSRectFill(NSMakeRect(rect.origin.x, rect.origin.y, rect.size.width, 1.0));

    NSColor *textColor = dark ? [NSColor colorWithWhite:1.0 alpha:0.85]
                              : [NSColor colorWithWhite:0.1 alpha:0.85];
    NSColor *numColor  = dark ? [NSColor colorWithWhite:1.0 alpha:0.5]
                              : [NSColor colorWithWhite:0.0 alpha:0.5];
    NSColor *artistColor = dark ? [NSColor colorWithWhite:1.0 alpha:0.55]
                                : [NSColor colorWithWhite:0.0 alpha:0.55];
    NSColor *selColor  = [[NSColor controlAccentColor] colorWithAlphaComponent:0.25];

    // Album header: "Artist - [Year] Album"
    CGFloat headerY = rect.origin.y + kTrackListPadding;
    NSString *headerStr;
    if (album.year.length > 0) {
        headerStr = [NSString stringWithFormat:@"%@ - [%@] %@", album.artistName, album.year, album.albumName];
    } else {
        headerStr = [NSString stringWithFormat:@"%@ - %@", album.artistName, album.albumName];
    }
    NSDictionary *headerAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13.0 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: textColor,
    };
    NSRect headerRect = NSMakeRect(kTrackListPadding + 4, headerY, rect.size.width - kTrackListPadding * 2 - 8, kTrackHeaderHeight - 4);
    [headerStr drawWithRect:headerRect
                    options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
                 attributes:headerAttrs];

    // Separator below header
    CGFloat sepY = headerY + kTrackHeaderHeight - 1;
    [[NSColor separatorColor] setFill];
    NSRectFill(NSMakeRect(rect.origin.x + kTrackListPadding, sepY, rect.size.width - kTrackListPadding * 2, 0.5));

    // Track rows
    NSFont *trackFont    = [NSFont systemFontOfSize:12.0];
    NSFont *durationFont = [NSFont monospacedDigitSystemFontOfSize:11.0 weight:NSFontWeightRegular];

    NSDictionary *numAttrs = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11.0 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: numColor,
    };
    NSDictionary *titleAttrs = @{
        NSFontAttributeName: trackFont,
        NSForegroundColorAttributeName: textColor,
    };
    NSDictionary *artistAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11.0],
        NSForegroundColorAttributeName: artistColor,
    };
    NSDictionary *durAttrs = @{
        NSFontAttributeName: durationFont,
        NSForegroundColorAttributeName: numColor,
    };

    NSMutableParagraphStyle *rightAlign = [[NSMutableParagraphStyle alloc] init];
    rightAlign.alignment = NSTextAlignmentRight;
    NSMutableDictionary *durAttrsRight = [durAttrs mutableCopy];
    durAttrsRight[NSParagraphStyleAttributeName] = rightAlign;

    CGFloat baseY = headerY + kTrackHeaderHeight;
    CGFloat numW = 30;
    CGFloat durW = 55;
    CGFloat ratingW = kRatingWidth;
    CGFloat artistW = MIN(rect.size.width * 0.25, 180);
    CGFloat leftMargin = kTrackListPadding + numW;
    CGFloat titleW = rect.size.width - leftMargin - artistW - ratingW - durW - kTrackListPadding * 2;

    for (NSUInteger i = 0; i < album.tracks.count; i++) {
        AlbumTrack *track = album.tracks[i];
        CGFloat rowY = baseY + i * kTrackRowHeight;

        if (_expandedAlbumIndex == _selectedAlbumIndex && (NSInteger)i == _selectedTrackIndex) {
            [selColor setFill];
            NSRectFill(NSMakeRect(rect.origin.x + 4, rowY, rect.size.width - 8, kTrackRowHeight));
        }

        // Track number
        NSString *numStr = [NSString stringWithFormat:@"%lu", (unsigned long)track.trackNumber];
        [numStr drawWithRect:NSMakeRect(kTrackListPadding, rowY + 3, numW - 4, kTrackRowHeight - 4)
                     options:NSStringDrawingUsesLineFragmentOrigin
                  attributes:numAttrs];

        // Title
        [track.title drawWithRect:NSMakeRect(leftMargin, rowY + 2, titleW, kTrackRowHeight - 2)
                          options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
                       attributes:titleAttrs];

        // Artist
        CGFloat artistX = leftMargin + titleW + kTrackListPadding;
        [album.artistName drawWithRect:NSMakeRect(artistX, rowY + 3, artistW - kTrackListPadding, kTrackRowHeight - 4)
                                options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
                             attributes:artistAttrs];

        // Rating
        CGFloat ratingX = rect.size.width - durW - ratingW - kTrackListPadding;
        [self drawRating:track.rating inRect:NSMakeRect(ratingX, rowY + 2, ratingW, kTrackRowHeight - 4) enabled:YES];

        // Duration
        CGFloat durX = rect.size.width - durW - kTrackListPadding;
        [track.duration drawWithRect:NSMakeRect(durX, rowY + 3, durW, kTrackRowHeight - 4)
                             options:NSStringDrawingUsesLineFragmentOrigin
                          attributes:durAttrsRight];
    }
}

#pragma mark - Hit testing

typedef struct {
    NSInteger albumIndex;
    NSInteger trackIndex; // NSNotFound if not in track list
} GridHitResult;

typedef struct {
    NSInteger albumIndex;
    NSInteger trackIndex;
    NSInteger rating;
} RatingHitResult;

- (GridHitResult)hitTestAtPoint:(NSPoint)point {
    GridHitResult result = { NSNotFound, NSNotFound };
    CGFloat w = self.bounds.size.width;
    if (w <= 0 || !_albums || _albums.count == 0) return result;

    CGFloat contentW = contentWidthForView(w);
    NSInteger cols = columnsForWidth(contentW, _thumbnailSize);
    CGFloat cw = cellWidth(contentW, cols);
    CGFloat ch = cellTotalHeight(cw);
    NSInteger albumCount = (NSInteger)_albums.count;

    CGFloat y = 0;
    for (NSInteger rowStart = 0; rowStart < albumCount; rowStart += cols) {
        NSInteger rowEnd = MIN(rowStart + cols, albumCount);
        CGFloat rowBottom = y + ch;

        if (point.y >= y && point.y < rowBottom) {
            if (point.x < kContentInsetLeft) {
                return result;
            }
            CGFloat localX = point.x - kContentInsetLeft;
            NSInteger col = (NSInteger)(localX / (cw + kCellPadding));
            if (col >= 0 && col < (rowEnd - rowStart)) {
                CGFloat cellX = col * (cw + kCellPadding);
                if (localX >= cellX && localX < cellX + cw) {
                    result.albumIndex = rowStart + col;
                }
            }
            return result;
        }

        y += ch;

        // Check track list region
        if (_expandedAlbumIndex != NSNotFound &&
            _expandedAlbumIndex >= rowStart && _expandedAlbumIndex < rowEnd) {
            AlbumItem *expanded = _albums[_expandedAlbumIndex];
            CGFloat trackListH = [self trackListHeightForAlbum:expanded width:w];

            if (point.y >= y && point.y < y + trackListH) {
                CGFloat localY = point.y - y - kTrackListPadding - kTrackHeaderHeight;
                if (localY >= 0) {
                    NSInteger trackIdx = (NSInteger)(localY / kTrackRowHeight);
                    if (trackIdx >= 0 && trackIdx < (NSInteger)expanded.tracks.count) {
                        result.albumIndex = _expandedAlbumIndex;
                        result.trackIndex = trackIdx;
                    }
                }
                return result;
            }
            y += trackListH;
        }
    }
    return result;
}

- (NSInteger)ratingValueForPoint:(NSPoint)point inRect:(NSRect)rect {
    if (NSIsEmptyRect(rect) || !NSPointInRect(point, rect)) return 0;
    CGFloat localX = point.x - rect.origin.x;
    NSInteger rating = (NSInteger)floor((localX / MAX(rect.size.width, 1.0)) * 5.0) + 1;
    return MAX(1, MIN(5, rating));
}

- (RatingHitResult)ratingHitTestAtPoint:(NSPoint)point {
    RatingHitResult result = { NSNotFound, NSNotFound, 0 };
    CGFloat w = self.bounds.size.width;
    if (w <= 0 || !_albums || _albums.count == 0) return result;

    CGFloat contentW = contentWidthForView(w);
    NSInteger cols = columnsForWidth(contentW, _thumbnailSize);
    CGFloat cw = cellWidth(contentW, cols);
    CGFloat thumbSize = cw;
    CGFloat ch = cellTotalHeight(cw);
    NSInteger albumCount = (NSInteger)_albums.count;

    CGFloat y = 0;
    for (NSInteger rowStart = 0; rowStart < albumCount; rowStart += cols) {
        NSInteger rowEnd = MIN(rowStart + cols, albumCount);

        for (NSInteger i = rowStart; i < rowEnd; i++) {
            NSInteger col = i - rowStart;
            CGFloat x = kContentInsetLeft + col * (cw + kCellPadding);
            CGFloat textX = x + 2;
            CGFloat textW = cw - 4;
            CGFloat textY = y + thumbSize + 3;
            NSRect ratingRect = NSMakeRect(textX + textW - kRatingWidth, textY + 27, kRatingWidth, 15);
            NSInteger rating = [self ratingValueForPoint:point inRect:ratingRect];
            if (rating > 0) {
                result.albumIndex = i;
                result.rating = rating;
                return result;
            }
        }

        y += ch;

        if (_expandedAlbumIndex != NSNotFound &&
            _expandedAlbumIndex >= rowStart && _expandedAlbumIndex < rowEnd) {
            AlbumItem *expanded = _albums[_expandedAlbumIndex];
            CGFloat trackListH = [self trackListHeightForAlbum:expanded width:w];
            CGFloat headerY = y + kTrackListPadding;
            CGFloat baseY = headerY + kTrackHeaderHeight;
            CGFloat durW = 55;
            CGFloat ratingX = w - durW - kRatingWidth - kTrackListPadding;

            for (NSUInteger i = 0; i < expanded.tracks.count; i++) {
                CGFloat rowY = baseY + i * kTrackRowHeight;
                NSRect ratingRect = NSMakeRect(ratingX, rowY + 2, kRatingWidth, kTrackRowHeight - 4);
                NSInteger rating = [self ratingValueForPoint:point inRect:ratingRect];
                if (rating > 0) {
                    result.albumIndex = _expandedAlbumIndex;
                    result.trackIndex = (NSInteger)i;
                    result.rating = rating;
                    return result;
                }
            }
            y += trackListH;
        }
    }
    return result;
}

#pragma mark - Mouse events

- (void)_cancelExpandTimer {
    [_expandTimer invalidate];
    _expandTimer = nil;
    _pendingExpandAlbumIndex = NSNotFound;
}

- (void)_performPendingExpand:(NSTimer *)timer {
    _expandTimer = nil;
    NSInteger albumIndex = _pendingExpandAlbumIndex;
    BOOL shouldCollapse  = _pendingExpandShouldCollapse;
    _pendingExpandAlbumIndex = NSNotFound;

    if (albumIndex == NSNotFound) return;

    if (shouldCollapse) {
        [self collapseExpandedAlbum];
        _selectedAlbumIndex = albumIndex;
        [self setNeedsDisplay:YES];
    } else {
        _selectedAlbumIndex = albumIndex;
        _selectedTrackIndex = NSNotFound;
        _expandedAlbumIndex = albumIndex;
        [self reloadData];
        [self scrollTrackListIntoView];
    }
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    _mouseDownPoint = point;
    _dragInitiated = NO;

    // Double-click: cancel any pending expand and let mouseUp handle playback
    if (event.clickCount == 2) {
        [self _cancelExpandTimer];
        return;
    }

    RatingHitResult ratingHit = [self ratingHitTestAtPoint:point];
    if (ratingHit.rating > 0 && ratingHit.albumIndex != NSNotFound && ratingHit.albumIndex < (NSInteger)_albums.count) {
        [self _cancelExpandTimer];
        _selectedAlbumIndex = ratingHit.albumIndex;
        AlbumItem *album = _albums[ratingHit.albumIndex];
        if (ratingHit.trackIndex != NSNotFound && ratingHit.trackIndex < (NSInteger)album.tracks.count) {
            _selectedTrackIndex = ratingHit.trackIndex;
            AlbumTrack *track = album.tracks[ratingHit.trackIndex];
            NSInteger newRating = (track.rating == ratingHit.rating) ? 0 : ratingHit.rating;
            track.rating = newRating;
            [_delegate albumGridView:self wantsSetRating:newRating forTrack:track inAlbum:album];
        } else {
            _selectedTrackIndex = NSNotFound;
            NSInteger newRating = (album.rating == ratingHit.rating) ? 0 : ratingHit.rating;
            album.rating = newRating;
            for (AlbumTrack *track in album.tracks) track.rating = newRating;
            [_delegate albumGridView:self wantsSetRating:newRating forAlbum:album];
        }
        [self setNeedsDisplay:YES];
        return;
    }

    GridHitResult hit = [self hitTestAtPoint:point];

    if (hit.albumIndex == NSNotFound) {
        [self _cancelExpandTimer];
        _selectedAlbumIndex = NSNotFound;
        _selectedTrackIndex = NSNotFound;
        if (_expandedAlbumIndex != NSNotFound) {
            [self collapseExpandedAlbum];
        } else {
            [self setNeedsDisplay:YES];
        }
        return;
    }

    if (hit.trackIndex != NSNotFound) {
        [self _cancelExpandTimer];
        _selectedAlbumIndex = hit.albumIndex;
        _selectedTrackIndex = hit.trackIndex;
        [self setNeedsDisplay:YES];
        return;
    }

    // Clicked on an album cell — select immediately, but delay expand/collapse
    // so a fast double-click can cancel it before it fires
    _selectedAlbumIndex = hit.albumIndex;
    [self setNeedsDisplay:YES];

    [self _cancelExpandTimer];
    _pendingExpandAlbumIndex      = hit.albumIndex;
    _pendingExpandShouldCollapse  = (hit.albumIndex == _expandedAlbumIndex);
    _expandTimer = [NSTimer scheduledTimerWithTimeInterval:[NSEvent doubleClickInterval]
                                                   target:self
                                                 selector:@selector(_performPendingExpand:)
                                                 userInfo:nil
                                                  repeats:NO];
}

- (void)scrollTrackListIntoView {
    if (_expandedAlbumIndex == NSNotFound) return;

    CGFloat w = self.bounds.size.width;
    NSInteger cols = columnsForWidth(w, _thumbnailSize);
    CGFloat cw = cellWidth(w, cols);
    CGFloat ch = cellTotalHeight(cw);
    NSInteger albumCount = (NSInteger)_albums.count;

    CGFloat y = 0;
    for (NSInteger rowStart = 0; rowStart < albumCount; rowStart += cols) {
        NSInteger rowEnd = MIN(rowStart + cols, albumCount);
        y += ch;
        if (_expandedAlbumIndex >= rowStart && _expandedAlbumIndex < rowEnd) {
            AlbumItem *expanded = _albums[_expandedAlbumIndex];
            CGFloat trackListH = [self trackListHeightForAlbum:expanded width:w];
            NSRect trackRect = NSMakeRect(0, y, w, trackListH);
            [self scrollRectToVisible:trackRect];
            return;
        }
        if (_expandedAlbumIndex != NSNotFound &&
            _expandedAlbumIndex >= rowStart && _expandedAlbumIndex < rowEnd) {
            AlbumItem *expanded = _albums[_expandedAlbumIndex];
            y += [self trackListHeightForAlbum:expanded width:w];
        }
    }
}

- (void)mouseUp:(NSEvent *)event {
    if (event.clickCount == 2) {
        NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
        GridHitResult hit = [self hitTestAtPoint:point];
        if (hit.albumIndex != NSNotFound && hit.albumIndex < (NSInteger)_albums.count) {
            AlbumItem *album = _albums[hit.albumIndex];
            if (hit.trackIndex != NSNotFound) {
                [_delegate albumGridView:self wantsPlayTrack:album.tracks[hit.trackIndex]
                                 inAlbum:album];
            } else {
                [_delegate albumGridView:self wantsPlayAlbum:album];
            }
        }
    }
}

- (void)mouseDragged:(NSEvent *)event {
    if (_dragInitiated) return;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat dx = point.x - _mouseDownPoint.x;
    CGFloat dy = point.y - _mouseDownPoint.y;
    if (sqrt(dx * dx + dy * dy) < 5.0) return;

    _dragInitiated = YES;
    [self startDragFromPoint:_mouseDownPoint event:event];
}

- (void)rightMouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    GridHitResult hit = [self hitTestAtPoint:point];
    if (hit.albumIndex == NSNotFound) return;

    _selectedAlbumIndex = hit.albumIndex;
    _selectedTrackIndex = hit.trackIndex;
    [self setNeedsDisplay:YES];

    AlbumItem *album = _albums[hit.albumIndex];
    NSPoint screenPoint = [self convertPoint:point toView:nil];
    screenPoint = [self.window convertPointToScreen:screenPoint];

    if (hit.trackIndex != NSNotFound) {
        [_delegate albumGridView:self requestsContextMenuForTrack:album.tracks[hit.trackIndex]
                         inAlbum:album atPoint:screenPoint];
    } else {
        [_delegate albumGridView:self requestsContextMenuForAlbum:album atPoint:screenPoint];
    }
}

#pragma mark - Keyboard

- (void)keyDown:(NSEvent *)event {
    NSString *chars = event.charactersIgnoringModifiers;
    if (!chars || chars.length == 0) {
        [super keyDown:event];
        return;
    }

    unichar ch = [chars characterAtIndex:0];

    if (ch == 'q' || ch == 'Q') {
        if (_selectedAlbumIndex != NSNotFound && _selectedAlbumIndex < (NSInteger)_albums.count) {
            AlbumItem *album = _albums[_selectedAlbumIndex];
            if (_selectedTrackIndex != NSNotFound) {
                [_delegate albumGridView:self wantsQueueTrack:album.tracks[_selectedTrackIndex]
                                 inAlbum:album];
            } else {
                [_delegate albumGridView:self wantsQueueAlbum:album];
            }
        }
        return;
    }

    if (ch == '\r') {
        if (_selectedAlbumIndex != NSNotFound && _selectedAlbumIndex < (NSInteger)_albums.count) {
            AlbumItem *album = _albums[_selectedAlbumIndex];
            if (_selectedTrackIndex != NSNotFound && _selectedTrackIndex < (NSInteger)album.tracks.count) {
                [_delegate albumGridView:self wantsPlayTrack:album.tracks[_selectedTrackIndex] inAlbum:album];
            } else {
                [_delegate albumGridView:self wantsPlayAlbum:album];
            }
        }
        return;
    }

    if (ch == ' ') {
        playback_control::get()->toggle_pause();
        return;
    }

    if (ch == 27) { // Escape
        [self collapseExpandedAlbum];
        return;
    }

    // Arrow key navigation
    CGFloat w = self.bounds.size.width;
    NSInteger cols = columnsForWidth(w, _thumbnailSize);

    if (ch == NSLeftArrowFunctionKey) {
        if (_selectedAlbumIndex > 0) {
            _selectedAlbumIndex--;
            _expandedAlbumIndex = NSNotFound;
            _selectedTrackIndex = NSNotFound;
            [self reloadData];
            [self scrollToAlbumIndex:_selectedAlbumIndex];
        }
    } else if (ch == NSRightArrowFunctionKey) {
        if (_selectedAlbumIndex < (NSInteger)_albums.count - 1) {
            _selectedAlbumIndex++;
            _expandedAlbumIndex = NSNotFound;
            _selectedTrackIndex = NSNotFound;
            [self reloadData];
            [self scrollToAlbumIndex:_selectedAlbumIndex];
        }
    } else if (ch == NSUpArrowFunctionKey) {
        if (_selectedTrackIndex != NSNotFound && _selectedTrackIndex > 0) {
            _selectedTrackIndex--;
            [self setNeedsDisplay:YES];
        } else if (_selectedTrackIndex == 0) {
            _selectedTrackIndex = NSNotFound;
            [self setNeedsDisplay:YES];
        } else if (_selectedAlbumIndex - cols >= 0) {
            _selectedAlbumIndex -= cols;
            _expandedAlbumIndex = NSNotFound;
            _selectedTrackIndex = NSNotFound;
            [self reloadData];
            [self scrollToAlbumIndex:_selectedAlbumIndex];
        }
    } else if (ch == NSDownArrowFunctionKey) {
        if (_expandedAlbumIndex == _selectedAlbumIndex && _selectedTrackIndex == NSNotFound) {
            AlbumItem *album = _albums[_selectedAlbumIndex];
            if (album.tracks.count > 0) {
                _selectedTrackIndex = 0;
                [self setNeedsDisplay:YES];
            }
        } else if (_selectedTrackIndex != NSNotFound) {
            AlbumItem *album = _albums[_selectedAlbumIndex];
            if (_selectedTrackIndex < (NSInteger)album.tracks.count - 1) {
                _selectedTrackIndex++;
                [self setNeedsDisplay:YES];
            }
        } else if (_selectedAlbumIndex + cols < (NSInteger)_albums.count) {
            _selectedAlbumIndex += cols;
            _expandedAlbumIndex = NSNotFound;
            _selectedTrackIndex = NSNotFound;
            [self reloadData];
            [self scrollToAlbumIndex:_selectedAlbumIndex];
        }
    } else {
        [super keyDown:event];
    }
}

- (void)scrollToAlbumIndex:(NSInteger)index {
    if (index == NSNotFound) return;
    CGFloat w = self.bounds.size.width;
    NSInteger cols = columnsForWidth(w, _thumbnailSize);
    CGFloat cw = cellWidth(w, cols);
    CGFloat ch = cellTotalHeight(cw);

    NSInteger row = index / cols;
    CGFloat y = row * ch;
    [self scrollRectToVisible:NSMakeRect(0, y, w, ch)];
}

- (void)scrollToAlbumWithTrackPath:(NSString *)path {
    if (!path || _albums.count == 0) return;
    for (NSInteger i = 0; i < (NSInteger)_albums.count; i++) {
        for (AlbumTrack *t in _albums[i].tracks) {
            if ([t.path isEqualToString:path]) {
                _selectedAlbumIndex = i;
                _expandedAlbumIndex = NSNotFound;
                _selectedTrackIndex = NSNotFound;
                [self reloadData];
                [self scrollToAlbumIndex:i];
                return;
            }
        }
    }
}

#pragma mark - Drag & Drop (source)

- (void)startDragFromPoint:(NSPoint)point event:(NSEvent *)event {
    GridHitResult hit = [self hitTestAtPoint:point];
    if (hit.albumIndex == NSNotFound) return;

    AlbumItem *album = _albums[hit.albumIndex];
    NSArray<NSString *> *paths;

    if (hit.trackIndex != NSNotFound) {
        paths = @[album.tracks[hit.trackIndex].path];
    } else {
        paths = [album allTrackPaths];
    }

    // SimPlaylist-compatible payload
    NSPasteboardType simPBType = @"com.foobar2000.simplaylist.rows";
    NSDictionary *dragData = @{
        @"sourcePlaylist": @(-1),
        @"indices": @[],
        @"paths": paths,
    };
    NSData *internalData = [NSKeyedArchiver archivedDataWithRootObject:dragData
                                                 requiringSecureCoding:NO
                                                                 error:nil];

    // File URLs for Finder interop
    NSMutableArray<NSURL *> *fileURLs = [NSMutableArray array];
    for (NSString *path in paths) {
        pfc::string8 nativePath;
        try {
            filesystem::g_get_native_path([path UTF8String], nativePath);
            NSString *nsPath = [NSString stringWithUTF8String:nativePath.c_str()];
            NSURL *url = [NSURL fileURLWithPath:nsPath];
            if (url) [fileURLs addObject:url];
        } catch (...) {}
    }

    NSPasteboardItem *pbItem = [[NSPasteboardItem alloc] init];
    if (internalData) {
        [pbItem setData:internalData forType:simPBType];
    }

    // Write file URLs to pasteboard
    if (fileURLs.count > 0) {
        NSMutableArray *urlStrings = [NSMutableArray array];
        for (NSURL *url in fileURLs) {
            [urlStrings addObject:url.absoluteString];
        }
        NSData *urlData = [NSKeyedArchiver archivedDataWithRootObject:urlStrings
                                                requiringSecureCoding:NO
                                                                error:nil];
        if (urlData) {
            [pbItem setData:urlData forType:NSPasteboardTypeFileURL];
        }
    }

    NSDraggingItem *dragItem = [[NSDraggingItem alloc] initWithPasteboardWriter:pbItem];

    // Drag image: use the album art thumbnail
    NSImage *dragImage = [[AlbumArtCache sharedCache] imageForPath:album.artPath
                                                              size:_thumbnailSize
                                                        completion:nil]
                         ?: _placeholderImage
                         ?: [AlbumArtCache placeholderImageOfSize:60];

    NSSize imgSize = NSMakeSize(60, 60);
    NSRect imgRect = NSMakeRect(point.x - 30, point.y - 30, imgSize.width, imgSize.height);
    [dragItem setDraggingFrame:imgRect contents:dragImage];

    [self beginDraggingSessionWithItems:@[dragItem] event:event source:self];
}

- (NSDragOperation)draggingSession:(NSDraggingSession *)session
    sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    return NSDragOperationCopy;
}

@end
