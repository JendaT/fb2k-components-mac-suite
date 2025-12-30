//
//  ScrobbleWidgetView.mm
//  foo_jl_scrobble_mac
//
//  Custom NSView for displaying Last.fm stats widget
//

#import "ScrobbleWidgetView.h"
#import "../Core/TopAlbum.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat kArrowWidth = 32.0;
static const CGFloat kMinAlbumSize = 64.0;
static const CGFloat kMaxAlbumSize = 150.0;
static const CGFloat kAlbumSpacing = 6.0;
static const CGFloat kProfileHeight = 40.0;
static const CGFloat kFooterHeight = 20.0;
static const CGFloat kPadding = 8.0;
static const NSTimeInterval kArrowFadeDuration = 0.15;

@interface ScrobbleWidgetView ()
@property (nonatomic, strong) NSTrackingArea *trackingArea;
@property (nonatomic, assign) BOOL isHovered;
@property (nonatomic, assign) CGFloat arrowOpacity;
@property (nonatomic, assign) CGFloat calculatedAlbumSize;
@property (nonatomic, assign) NSInteger hoveredAlbumIndex;  // -1 if none
@property (nonatomic, strong) NSMutableArray<NSValue *> *albumRects;  // Store album rects for hit testing
@property (nonatomic, assign) NSRect profileLinkRect;  // Last.fm link button rect
@property (nonatomic, assign) BOOL isOverProfileLink;
// Period row navigation
@property (nonatomic, assign) NSRect periodRowRect;
@property (nonatomic, assign) BOOL isOverPeriodLeftArrow;
@property (nonatomic, assign) BOOL isOverPeriodRightArrow;
// Type row navigation
@property (nonatomic, assign) NSRect typeRowRect;
@property (nonatomic, assign) BOOL isOverTypeLeftArrow;
@property (nonatomic, assign) BOOL isOverTypeRightArrow;
@end

@implementation ScrobbleWidgetView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _state = ScrobbleWidgetStateLoading;
        _maxAlbums = 10;  // Default, will be updated by controller from config
        _scrobbledToday = 0;
        _queueCount = 0;
        _arrowOpacity = 0.0;
        _canNavigatePrevious = YES;  // Always allow navigation
        _canNavigateNext = YES;
        _currentPeriod = ScrobbleChartPeriodWeekly;
        _currentType = ScrobbleChartTypeAlbums;
        _periodTitle = [ScrobbleWidgetView titleForPeriod:_currentPeriod];
        _typeTitle = [ScrobbleWidgetView titleForType:_currentType];
        _hoveredAlbumIndex = -1;
        _albumRects = [NSMutableArray array];
        self.wantsLayer = YES;

        // Use minimum priorities so the view doesn't resist being resized by the layout system
        [self setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
        [self setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationVertical];

        [self setupTrackingArea];
    }
    return self;
}

// Don't constrain intrinsic size - let layout system decide
- (NSSize)intrinsicContentSize {
    NSLog(@"[ScrobbleWidget] intrinsicContentSize called - returning NoIntrinsicMetric");
    return NSMakeSize(NSViewNoIntrinsicMetric, NSViewNoIntrinsicMetric);
}

// Override fittingSize to not constrain layout
- (NSSize)fittingSize {
    NSLog(@"[ScrobbleWidget] fittingSize called - returning bounds size: %@", NSStringFromSize(self.bounds.size));
    return self.bounds.size;
}

- (void)dealloc {
    if (_trackingArea) {
        [self removeTrackingArea:_trackingArea];
    }
}

#pragma mark - Legacy Property Accessors

- (ScrobbleChartPage)currentPage {
    return _currentPeriod;
}

- (void)setCurrentPage:(ScrobbleChartPage)currentPage {
    _currentPeriod = currentPage;
}

- (NSString *)chartTitle {
    return [NSString stringWithFormat:@"%@ %@", _periodTitle ?: @"", _typeTitle ?: @""];
}

- (void)setChartTitle:(NSString *)chartTitle {
    // Parse or ignore - use periodTitle and typeTitle instead
}

#pragma mark - Class Methods

+ (NSString *)apiPeriodForPeriod:(ScrobbleChartPeriod)period {
    switch (period) {
        case ScrobbleChartPeriodWeekly:  return @"7day";
        case ScrobbleChartPeriodMonthly: return @"1month";
        case ScrobbleChartPeriodOverall: return @"overall";
        default: return @"7day";
    }
}

+ (NSString *)titleForPeriod:(ScrobbleChartPeriod)period {
    switch (period) {
        case ScrobbleChartPeriodWeekly:  return @"Weekly";
        case ScrobbleChartPeriodMonthly: return @"Monthly";
        case ScrobbleChartPeriodOverall: return @"All Time";
        default: return @"Weekly";
    }
}

+ (NSString *)titleForType:(ScrobbleChartType)type {
    switch (type) {
        case ScrobbleChartTypeAlbums:  return @"Albums";
        case ScrobbleChartTypeArtists: return @"Artists";
        case ScrobbleChartTypeTracks:  return @"Tracks";
        default: return @"Albums";
    }
}

// Legacy aliases
+ (NSString *)periodForPage:(ScrobbleChartPage)page {
    return [self apiPeriodForPeriod:page];
}

+ (NSString *)titleForPage:(ScrobbleChartPage)page {
    return [NSString stringWithFormat:@"%@ Top Albums", [self titleForPeriod:page]];
}

#pragma mark - Tracking Area

- (void)setupTrackingArea {
    if (_trackingArea) {
        [self removeTrackingArea:_trackingArea];
    }

    NSTrackingAreaOptions options = (NSTrackingMouseEnteredAndExited |
                                     NSTrackingMouseMoved |
                                     NSTrackingActiveAlways |
                                     NSTrackingInVisibleRect);

    _trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                 options:options
                                                   owner:self
                                                userInfo:nil];
    [self addTrackingArea:_trackingArea];

    NSLog(@"[ScrobbleWidget] setupTrackingArea - bounds: %@, window: %@",
          NSStringFromRect(self.bounds), self.window ? @"YES" : @"NO");
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    [self setupTrackingArea];
}

#pragma mark - View Sizing

- (void)setFrameSize:(NSSize)newSize {
    NSSize oldSize = self.frame.size;
    [super setFrameSize:newSize];
    if (!NSEqualSizes(oldSize, newSize)) {
        NSLog(@"[ScrobbleWidget] setFrameSize: %@ -> %@", NSStringFromSize(oldSize), NSStringFromSize(newSize));
        [self setNeedsDisplay:YES];
    }
}

- (void)setBounds:(NSRect)bounds {
    NSRect oldBounds = self.bounds;
    [super setBounds:bounds];
    if (!NSEqualRects(oldBounds, bounds)) {
        NSLog(@"[ScrobbleWidget] setBounds: %@ -> %@", NSStringFromRect(oldBounds), NSStringFromRect(bounds));
        [self setNeedsDisplay:YES];
    }
}

- (void)setFrame:(NSRect)frame {
    NSRect oldFrame = self.frame;
    [super setFrame:frame];
    if (!NSEqualRects(oldFrame, frame)) {
        NSLog(@"[ScrobbleWidget] setFrame: %@ -> %@", NSStringFromRect(oldFrame), NSStringFromRect(frame));
        [self setNeedsDisplay:YES];
    }
}

- (void)layout {
    [super layout];
    [self setNeedsDisplay:YES];
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    [super resizeSubviewsWithOldSize:oldSize];
    [self setNeedsDisplay:YES];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) {
        NSLog(@"[ScrobbleWidget] viewDidMoveToWindow - bounds: %@", NSStringFromRect(self.bounds));
        [self setupTrackingArea];
        [self setNeedsDisplay:YES];
    }
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

#pragma mark - Layout Calculation

- (CGFloat)calculateAlbumSizeForWidth:(CGFloat)availableWidth {
    // Calculate optimal album size to show 4-6 albums per row
    // Target: fit 5 albums ideally, but allow 4-6 based on width

    // Try different album counts per row and pick the one closest to target size
    CGFloat targetSize = 130.0;  // Preferred album size
    CGFloat bestSize = kMinAlbumSize;

    for (NSInteger albumsPerRow = 3; albumsPerRow <= 8; albumsPerRow++) {
        CGFloat totalSpacing = kAlbumSpacing * (albumsPerRow - 1);
        CGFloat size = (availableWidth - totalSpacing) / albumsPerRow;

        // Clamp to min/max
        size = MAX(kMinAlbumSize, MIN(kMaxAlbumSize, size));

        // Pick the size closest to target that's within bounds
        if (fabs(size - targetSize) < fabs(bestSize - targetSize)) {
            bestSize = size;
        }
    }

    return bestSize;
}

#pragma mark - Mouse Events

- (void)mouseEntered:(NSEvent *)event {
    _isHovered = YES;
    NSLog(@"[ScrobbleWidget] mouseEntered - bounds: %@", NSStringFromRect(self.bounds));
    [self animateArrowOpacity:1.0];
}

- (void)mouseExited:(NSEvent *)event {
    _isHovered = NO;
    _hoveredAlbumIndex = -1;
    _isOverProfileLink = NO;
    _isOverPeriodLeftArrow = NO;
    _isOverPeriodRightArrow = NO;
    _isOverTypeLeftArrow = NO;
    _isOverTypeRightArrow = NO;
    [self animateArrowOpacity:0.0];
    [self setNeedsDisplay:YES];
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];

    NSInteger oldHoveredAlbum = _hoveredAlbumIndex;
    BOOL wasOverProfileLink = _isOverProfileLink;
    BOOL wasOverPeriodLeft = _isOverPeriodLeftArrow;
    BOOL wasOverPeriodRight = _isOverPeriodRightArrow;
    BOOL wasOverTypeLeft = _isOverTypeLeftArrow;
    BOOL wasOverTypeRight = _isOverTypeRightArrow;

    // Check if over profile link button
    _isOverProfileLink = !NSIsEmptyRect(_profileLinkRect) && NSPointInRect(location, _profileLinkRect);

    // Check period navigation (pill-shaped control)
    _isOverPeriodLeftArrow = NO;
    _isOverPeriodRightArrow = NO;
    if (!NSIsEmptyRect(_periodRowRect) && NSPointInRect(location, _periodRowRect)) {
        CGFloat thirdWidth = _periodRowRect.size.width / 3;
        CGFloat relX = location.x - _periodRowRect.origin.x;
        if (relX < thirdWidth) {
            _isOverPeriodLeftArrow = YES;
        } else if (relX > thirdWidth * 2) {
            _isOverPeriodRightArrow = YES;
        }
    }

    // Check type navigation (pill-shaped control)
    _isOverTypeLeftArrow = NO;
    _isOverTypeRightArrow = NO;
    if (!NSIsEmptyRect(_typeRowRect) && NSPointInRect(location, _typeRowRect)) {
        CGFloat thirdWidth = _typeRowRect.size.width / 3;
        CGFloat relX = location.x - _typeRowRect.origin.x;
        if (relX < thirdWidth) {
            _isOverTypeLeftArrow = YES;
        } else if (relX > thirdWidth * 2) {
            _isOverTypeRightArrow = YES;
        }
    }

    // Check which album is being hovered
    _hoveredAlbumIndex = -1;
    for (NSInteger i = 0; i < (NSInteger)_albumRects.count; i++) {
        NSRect rect = [_albumRects[i] rectValue];
        if (NSPointInRect(location, rect)) {
            _hoveredAlbumIndex = i;
            break;
        }
    }

    if (oldHoveredAlbum != _hoveredAlbumIndex || wasOverProfileLink != _isOverProfileLink ||
        wasOverPeriodLeft != _isOverPeriodLeftArrow || wasOverPeriodRight != _isOverPeriodRightArrow ||
        wasOverTypeLeft != _isOverTypeLeftArrow || wasOverTypeRight != _isOverTypeRightArrow) {
        [self setNeedsDisplay:YES];
    }
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];

    // Check if clicking on profile link
    if (!NSIsEmptyRect(_profileLinkRect) && NSPointInRect(location, _profileLinkRect)) {
        if ([_delegate respondsToSelector:@selector(widgetViewOpenLastFmProfile:)]) {
            [_delegate widgetViewOpenLastFmProfile:self];
        }
        return;
    }

    // Check period row navigation
    if (_isOverPeriodLeftArrow) {
        if ([_delegate respondsToSelector:@selector(widgetViewNavigatePreviousPeriod:)]) {
            [_delegate widgetViewNavigatePreviousPeriod:self];
        }
        return;
    }
    if (_isOverPeriodRightArrow) {
        if ([_delegate respondsToSelector:@selector(widgetViewNavigateNextPeriod:)]) {
            [_delegate widgetViewNavigateNextPeriod:self];
        }
        return;
    }

    // Check type row navigation
    if (_isOverTypeLeftArrow) {
        if ([_delegate respondsToSelector:@selector(widgetViewNavigatePreviousType:)]) {
            [_delegate widgetViewNavigatePreviousType:self];
        }
        return;
    }
    if (_isOverTypeRightArrow) {
        if ([_delegate respondsToSelector:@selector(widgetViewNavigateNextType:)]) {
            [_delegate widgetViewNavigateNextType:self];
        }
        return;
    }

    // Check if clicking on an album
    for (NSInteger i = 0; i < (NSInteger)_albumRects.count; i++) {
        NSRect rect = [_albumRects[i] rectValue];
        if (NSPointInRect(location, rect)) {
            if ([_delegate respondsToSelector:@selector(widgetView:didClickAlbumAtIndex:)]) {
                [_delegate widgetView:self didClickAlbumAtIndex:i];
            }
            return;
        }
    }
}

- (void)rightMouseDown:(NSEvent *)event {
    if ([_delegate respondsToSelector:@selector(widgetViewRequestsContextMenu:atPoint:)]) {
        NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
        [_delegate widgetViewRequestsContextMenu:self atPoint:point];
    }
}

#pragma mark - Animation

- (void)animateArrowOpacity:(CGFloat)targetOpacity {
    CGFloat startOpacity = _arrowOpacity;
    NSTimeInterval duration = kArrowFadeDuration;
    NSTimeInterval startTime = [NSDate timeIntervalSinceReferenceDate];

    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:1.0/60.0 repeats:YES block:^(NSTimer *t) {
            NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - startTime;
            CGFloat progress = MIN(1.0, elapsed / duration);

            // Ease out
            progress = 1.0 - pow(1.0 - progress, 2);

            self->_arrowOpacity = startOpacity + (targetOpacity - startOpacity) * progress;
            [self setNeedsDisplay:YES];

            if (progress >= 1.0) {
                [t invalidate];
            }
        }];
        [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    });
}

#pragma mark - Drawing

- (BOOL)isFlipped {
    return YES;  // Use top-left origin for easier layout
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    // Log first draw to help diagnose sizing issues
    static BOOL firstDraw = YES;
    if (firstDraw) {
        NSLog(@"[ScrobbleWidget] FIRST drawRect - bounds: %@, state: %ld, isHovered: %d",
              NSStringFromRect(self.bounds), (long)_state, _isHovered);
        firstDraw = NO;
    }

    // Background
    [[NSColor windowBackgroundColor] setFill];
    NSRectFill(dirtyRect);

    switch (_state) {
        case ScrobbleWidgetStateLoading:
            [self drawCenteredText:@"Loading..." color:[NSColor secondaryLabelColor]];
            break;

        case ScrobbleWidgetStateNotAuth:
            [self drawCenteredText:@"Not signed in to Last.fm" color:[NSColor secondaryLabelColor]];
            break;

        case ScrobbleWidgetStateEmpty:
            [self drawCenteredText:@"No listening data yet" color:[NSColor secondaryLabelColor]];
            break;

        case ScrobbleWidgetStateError:
            [self drawCenteredText:(_errorMessage ?: @"Error loading data") color:[NSColor systemRedColor]];
            break;

        case ScrobbleWidgetStateReady:
            [self drawReadyState];
            break;
    }

    // Draw hover tooltip for album
    if (_hoveredAlbumIndex >= 0 && _hoveredAlbumIndex < (NSInteger)_topAlbums.count) {
        [self drawAlbumTooltipForIndex:_hoveredAlbumIndex];
    }

    // Draw loading overlay when refreshing (keeps content visible)
    if (_isRefreshing) {
        [self drawRefreshingOverlay];
    }
}

- (void)drawRefreshingOverlay {
    // Semi-transparent overlay
    [[NSColor colorWithWhite:0.0 alpha:0.3] setFill];
    NSRectFillUsingOperation(self.bounds, NSCompositingOperationSourceOver);

    // Loading indicator in center
    CGFloat indicatorSize = 32.0;
    CGFloat centerX = NSMidX(self.bounds);
    CGFloat centerY = NSMidY(self.bounds);

    // Draw spinning dots indicator (simple version - static dots in a circle)
    NSInteger dotCount = 8;
    CGFloat dotRadius = 3.0;
    CGFloat circleRadius = indicatorSize / 2 - dotRadius;

    for (NSInteger i = 0; i < dotCount; i++) {
        CGFloat angle = (CGFloat)i / dotCount * 2 * M_PI - M_PI_2;
        CGFloat dotX = centerX + cos(angle) * circleRadius;
        CGFloat dotY = centerY + sin(angle) * circleRadius;

        // Fade dots based on position
        CGFloat alpha = 0.3 + 0.7 * (CGFloat)i / dotCount;
        [[NSColor colorWithWhite:1.0 alpha:alpha] setFill];

        NSRect dotRect = NSMakeRect(dotX - dotRadius, dotY - dotRadius, dotRadius * 2, dotRadius * 2);
        NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:dotRect];
        [dot fill];
    }
}

- (void)drawReadyState {
    CGFloat contentWidth = self.bounds.size.width - (kPadding * 2);
    CGFloat y = kPadding;

    // Calculate album size based on available width
    CGFloat oldAlbumSize = _calculatedAlbumSize;
    _calculatedAlbumSize = [self calculateAlbumSizeForWidth:contentWidth];

    // Log when album size changes
    if (fabs(oldAlbumSize - _calculatedAlbumSize) > 0.1) {
        NSLog(@"[ScrobbleWidget] drawReadyState - bounds: %@, contentWidth: %.1f, albumSize: %.1f -> %.1f, maxAlbums: %ld",
              NSStringFromRect(self.bounds), contentWidth, oldAlbumSize, _calculatedAlbumSize, (long)_maxAlbums);
    }

    // Profile section (compact header)
    y = [self drawProfileSectionAtY:y width:contentWidth];

    // Album grid
    y = [self drawAlbumGridAtY:y width:contentWidth];

    // Status footer
    [self drawStatusFooterAtY:y width:contentWidth];
}

- (CGFloat)drawProfileSectionAtY:(CGFloat)y width:(CGFloat)width {
    CGFloat profileSize = 28.0;
    CGFloat spacing = 6.0;
    CGFloat rowHeight = 28.0;

    // Single header row: [Profile] [< Period >] [< Type >] [Link]
    CGFloat x = kPadding;

    // Profile image (if available)
    NSRect imageRect = NSMakeRect(x, y, profileSize, profileSize);
    if (_profileImage) {
        NSBezierPath *clipPath = [NSBezierPath bezierPathWithRoundedRect:imageRect
                                                                 xRadius:profileSize / 2
                                                                 yRadius:profileSize / 2];
        [NSGraphicsContext saveGraphicsState];
        [clipPath addClip];
        [_profileImage drawInRect:imageRect
                         fromRect:NSZeroRect
                        operation:NSCompositingOperationSourceOver
                         fraction:1.0];
        [NSGraphicsContext restoreGraphicsState];
    } else {
        // Placeholder circle
        [[NSColor tertiaryLabelColor] setFill];
        NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:imageRect];
        [circle fill];
    }
    x += profileSize + spacing;

    // Link button on the far right
    CGFloat linkButtonSize = 22.0;
    _profileLinkRect = NSMakeRect(kPadding + width - linkButtonSize, y + (rowHeight - linkButtonSize) / 2,
                                   linkButtonSize, linkButtonSize);
    NSColor *linkColor = _isOverProfileLink ? [NSColor controlAccentColor] : [NSColor secondaryLabelColor];
    [self drawExternalLinkIconInRect:_profileLinkRect color:linkColor];

    // Calculate navigation area (between profile and link button)
    CGFloat navAreaStart = x;
    CGFloat navAreaWidth = width - profileSize - spacing - linkButtonSize - spacing;
    CGFloat navAreaCenterX = navAreaStart + navAreaWidth / 2;

    // Measure text sizes for combined pill
    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor labelColor]
    };
    NSString *periodText = _periodTitle ?: @"Weekly";
    NSString *typeText = _typeTitle ?: @"Albums";
    NSSize periodSize = [periodText sizeWithAttributes:titleAttrs];
    NSSize typeSize = [typeText sizeWithAttributes:titleAttrs];

    CGFloat arrowWidth = 6.0, arrowGap = 6.0, pillPadding = 8.0;
    CGFloat dividerGap = 6.0;  // Space between the two controls inside the pill (reduced)
    CGFloat pillHeight = 20.0;

    // Calculate total width for combined pill: [< Period >  < Type >]
    CGFloat periodContentWidth = arrowWidth + arrowGap + periodSize.width + arrowGap + arrowWidth;
    CGFloat typeContentWidth = arrowWidth + arrowGap + typeSize.width + arrowGap + arrowWidth;
    CGFloat totalContentWidth = periodContentWidth + dividerGap + typeContentWidth;
    CGFloat combinedPillWidth = totalContentWidth + pillPadding * 2;

    // Center the combined pill
    CGFloat pillStartX = navAreaCenterX - combinedPillWidth / 2;
    CGFloat centerY = y + rowHeight / 2;

    // Draw single unified pill background
    NSRect pillRect = NSMakeRect(pillStartX, centerY - pillHeight / 2, combinedPillWidth, pillHeight);
    [[NSColor colorWithWhite:0.5 alpha:0.12] setFill];
    NSBezierPath *pillPath = [NSBezierPath bezierPathWithRoundedRect:pillRect
                                                             xRadius:pillHeight / 2
                                                             yRadius:pillHeight / 2];
    [pillPath fill];

    // Period control rect (for hit testing) - left half of pill
    CGFloat periodRectWidth = pillPadding + periodContentWidth + dividerGap / 2;
    _periodRowRect = NSMakeRect(pillStartX, y, periodRectWidth, rowHeight);

    // Type control rect (for hit testing) - right half of pill
    CGFloat typeRectStart = pillStartX + periodRectWidth;
    CGFloat typeRectWidth = dividerGap / 2 + typeContentWidth + pillPadding;
    _typeRowRect = NSMakeRect(typeRectStart, y, typeRectWidth, rowHeight);

    // Draw period content: < Weekly >
    CGFloat periodCenterX = pillStartX + pillPadding + periodContentWidth / 2;
    [self drawNavigationContentAtCenterX:periodCenterX
                                  centerY:centerY
                                    title:periodText
                                titleSize:periodSize
                               arrowWidth:arrowWidth
                                 arrowGap:arrowGap
                          isOverLeftArrow:_isOverPeriodLeftArrow
                         isOverRightArrow:_isOverPeriodRightArrow];

    // Draw type content: < Albums >
    CGFloat typeCenterX = pillStartX + pillPadding + periodContentWidth + dividerGap + typeContentWidth / 2;
    [self drawNavigationContentAtCenterX:typeCenterX
                                  centerY:centerY
                                    title:typeText
                                titleSize:typeSize
                               arrowWidth:arrowWidth
                                 arrowGap:arrowGap
                          isOverLeftArrow:_isOverTypeLeftArrow
                         isOverRightArrow:_isOverTypeRightArrow];

    return y + rowHeight + spacing;
}

- (void)drawCompactNavigationInRect:(NSRect)rect title:(NSString *)title
                     isOverLeftArrow:(BOOL)isOverLeft isOverRightArrow:(BOOL)isOverRight {
    // Title attributes
    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor labelColor]
    };

    NSSize titleSize = [title sizeWithAttributes:titleAttrs];
    CGFloat centerX = rect.origin.x + rect.size.width / 2;
    CGFloat centerY = rect.origin.y + rect.size.height / 2;

    // Calculate tight pill size around content
    CGFloat arrowWidth = 6.0;
    CGFloat arrowGap = 6.0;
    CGFloat pillPadding = 8.0;
    CGFloat contentWidth = arrowWidth + arrowGap + titleSize.width + arrowGap + arrowWidth;
    CGFloat pillWidth = contentWidth + pillPadding * 2;
    CGFloat pillHeight = 20.0;

    NSRect pillRect = NSMakeRect(centerX - pillWidth / 2, centerY - pillHeight / 2, pillWidth, pillHeight);

    // Draw subtle pill background
    [[NSColor colorWithWhite:0.5 alpha:0.12] setFill];
    NSBezierPath *pillPath = [NSBezierPath bezierPathWithRoundedRect:pillRect
                                                             xRadius:pillHeight / 2
                                                             yRadius:pillHeight / 2];
    [pillPath fill];

    // Draw title centered
    CGFloat titleX = centerX - titleSize.width / 2;
    CGFloat titleY = centerY - titleSize.height / 2;
    [title drawAtPoint:NSMakePoint(titleX, titleY) withAttributes:titleAttrs];

    // Small arrows close to text
    CGFloat arrowY = centerY;

    // Left arrow (just before text)
    CGFloat leftArrowX = titleX - arrowGap - arrowWidth;
    NSColor *leftColor = isOverLeft ? [NSColor controlAccentColor] : [NSColor tertiaryLabelColor];
    [self drawSmallArrowAtX:leftArrowX y:arrowY direction:-1 color:leftColor];

    // Right arrow (just after text)
    CGFloat rightArrowX = titleX + titleSize.width + arrowGap;
    NSColor *rightColor = isOverRight ? [NSColor controlAccentColor] : [NSColor tertiaryLabelColor];
    [self drawSmallArrowAtX:rightArrowX y:arrowY direction:1 color:rightColor];
}

- (void)drawNavigationContentAtCenterX:(CGFloat)centerX centerY:(CGFloat)centerY
                                  title:(NSString *)title titleSize:(NSSize)titleSize
                             arrowWidth:(CGFloat)arrowWidth arrowGap:(CGFloat)arrowGap
                        isOverLeftArrow:(BOOL)isOverLeft isOverRightArrow:(BOOL)isOverRight {
    // Draw title centered at given position
    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor labelColor]
    };

    CGFloat titleX = centerX - titleSize.width / 2;
    CGFloat titleY = centerY - titleSize.height / 2;
    [title drawAtPoint:NSMakePoint(titleX, titleY) withAttributes:titleAttrs];

    // Left arrow (just before text)
    CGFloat leftArrowX = titleX - arrowGap - arrowWidth;
    NSColor *leftColor = isOverLeft ? [NSColor controlAccentColor] : [NSColor tertiaryLabelColor];
    [self drawSmallArrowAtX:leftArrowX y:centerY direction:-1 color:leftColor];

    // Right arrow (just after text)
    CGFloat rightArrowX = titleX + titleSize.width + arrowGap;
    NSColor *rightColor = isOverRight ? [NSColor controlAccentColor] : [NSColor tertiaryLabelColor];
    [self drawSmallArrowAtX:rightArrowX y:centerY direction:1 color:rightColor];
}

- (void)drawSmallArrowAtX:(CGFloat)x y:(CGFloat)y direction:(int)direction color:(NSColor *)color {
    CGFloat size = 5.0;

    NSBezierPath *arrow = [NSBezierPath bezierPath];
    arrow.lineWidth = 1.2;
    arrow.lineCapStyle = NSLineCapStyleRound;
    arrow.lineJoinStyle = NSLineJoinStyleRound;

    if (direction < 0) {
        // Left arrow <
        [arrow moveToPoint:NSMakePoint(x + size, y - size/2)];
        [arrow lineToPoint:NSMakePoint(x, y)];
        [arrow lineToPoint:NSMakePoint(x + size, y + size/2)];
    } else {
        // Right arrow >
        [arrow moveToPoint:NSMakePoint(x, y - size/2)];
        [arrow lineToPoint:NSMakePoint(x + size, y)];
        [arrow lineToPoint:NSMakePoint(x, y + size/2)];
    }

    [color setStroke];
    [arrow stroke];
}

- (void)drawNavigationRowInRect:(NSRect)rect title:(NSString *)title
                 isOverLeftArrow:(BOOL)isOverLeft isOverRightArrow:(BOOL)isOverRight
                      arrowWidth:(CGFloat)arrowWidth {
    // Draw centered title with arrows on each side
    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor secondaryLabelColor]
    };

    NSSize titleSize = [title sizeWithAttributes:titleAttrs];
    CGFloat centerX = rect.origin.x + rect.size.width / 2;
    CGFloat titleX = centerX - titleSize.width / 2;
    CGFloat titleY = rect.origin.y + (rect.size.height - titleSize.height) / 2;

    [title drawAtPoint:NSMakePoint(titleX, titleY) withAttributes:titleAttrs];

    // Left arrow
    CGFloat arrowY = rect.origin.y + rect.size.height / 2;
    CGFloat leftArrowX = titleX - arrowWidth - 4;
    NSColor *leftColor = isOverLeft ? [NSColor controlAccentColor] : [NSColor tertiaryLabelColor];
    [self drawInlineArrowAtX:leftArrowX y:arrowY direction:-1 color:leftColor];

    // Right arrow
    CGFloat rightArrowX = titleX + titleSize.width + 4;
    NSColor *rightColor = isOverRight ? [NSColor controlAccentColor] : [NSColor tertiaryLabelColor];
    [self drawInlineArrowAtX:rightArrowX y:arrowY direction:1 color:rightColor];
}

- (void)drawInlineArrowAtX:(CGFloat)x y:(CGFloat)y direction:(int)direction color:(NSColor *)color {
    CGFloat size = 8.0;

    NSBezierPath *arrow = [NSBezierPath bezierPath];
    arrow.lineWidth = 1.5;
    arrow.lineCapStyle = NSLineCapStyleRound;
    arrow.lineJoinStyle = NSLineJoinStyleRound;

    if (direction < 0) {
        // Left arrow <
        [arrow moveToPoint:NSMakePoint(x + size, y - size/2)];
        [arrow lineToPoint:NSMakePoint(x, y)];
        [arrow lineToPoint:NSMakePoint(x + size, y + size/2)];
    } else {
        // Right arrow >
        [arrow moveToPoint:NSMakePoint(x, y - size/2)];
        [arrow lineToPoint:NSMakePoint(x + size, y)];
        [arrow lineToPoint:NSMakePoint(x, y + size/2)];
    }

    [color setStroke];
    [arrow stroke];
}

- (void)drawExternalLinkIconInRect:(NSRect)rect color:(NSColor *)color {
    // Draw a simple external link icon (arrow pointing out of box)
    CGFloat inset = 5.0;
    NSRect iconRect = NSInsetRect(rect, inset, inset);
    CGFloat size = iconRect.size.width;

    NSBezierPath *path = [NSBezierPath bezierPath];
    path.lineWidth = 1.5;
    path.lineCapStyle = NSLineCapStyleRound;
    path.lineJoinStyle = NSLineJoinStyleRound;

    CGFloat x = iconRect.origin.x;
    CGFloat y = iconRect.origin.y;

    // Draw box (bottom-left corner open)
    [path moveToPoint:NSMakePoint(x + size * 0.4, y)];
    [path lineToPoint:NSMakePoint(x, y)];
    [path lineToPoint:NSMakePoint(x, y + size)];
    [path lineToPoint:NSMakePoint(x + size, y + size)];
    [path lineToPoint:NSMakePoint(x + size, y + size * 0.6)];

    // Draw arrow
    [path moveToPoint:NSMakePoint(x + size * 0.4, y + size * 0.6)];
    [path lineToPoint:NSMakePoint(x + size, y)];

    // Arrow head
    [path moveToPoint:NSMakePoint(x + size * 0.6, y)];
    [path lineToPoint:NSMakePoint(x + size, y)];
    [path lineToPoint:NSMakePoint(x + size, y + size * 0.4)];

    [color setStroke];
    [path stroke];
}

- (CGFloat)drawAlbumGridAtY:(CGFloat)y width:(CGFloat)width {
    // Clear stored rects
    [_albumRects removeAllObjects];

    if (_topAlbums.count == 0) {
        return y;
    }

    CGFloat albumSize = _calculatedAlbumSize;
    CGFloat spacing = kAlbumSpacing;

    // Calculate how many albums fit per row
    NSInteger albumsPerRow = (NSInteger)((width + spacing) / (albumSize + spacing));
    if (albumsPerRow < 1) albumsPerRow = 1;

    // Center the grid
    CGFloat totalGridWidth = albumsPerRow * albumSize + (albumsPerRow - 1) * spacing;
    CGFloat startX = kPadding + (width - totalGridWidth) / 2;

    CGFloat x = startX;
    NSInteger col = 0;

    for (TopAlbum *album in _topAlbums) {
        NSRect albumRect = NSMakeRect(x, y, albumSize, albumSize);

        // Store rect for hit testing
        [_albumRects addObject:[NSValue valueWithRect:albumRect]];

        // Try to get loaded image
        NSImage *albumImage = nil;
        if (album.imageURL && _albumImages) {
            albumImage = _albumImages[album.imageURL];
        }

        if (albumImage) {
            // Draw the album artwork scaled to fill
            [self drawImage:albumImage inRect:albumRect];
        } else {
            // Draw placeholder
            [[NSColor tertiaryLabelColor] setFill];
            NSRectFill(albumRect);

            // Draw album name centered in placeholder (below rank badge area)
            if (album.name.length > 0) {
                NSMutableParagraphStyle *paraStyle = [[NSMutableParagraphStyle alloc] init];
                paraStyle.alignment = NSTextAlignmentCenter;
                paraStyle.lineBreakMode = NSLineBreakByWordWrapping;

                NSDictionary *nameAttrs = @{
                    NSFontAttributeName: [NSFont systemFontOfSize:10],
                    NSForegroundColorAttributeName: [NSColor secondaryLabelColor],
                    NSParagraphStyleAttributeName: paraStyle
                };

                // Inset to avoid rank badge (top-left) and leave margins
                NSRect textRect = NSMakeRect(x + 4, y + 24, albumSize - 8, albumSize - 28);
                [album.name drawInRect:textRect withAttributes:nameAttrs];
            }
        }

        // Draw rank badge (semi-transparent background)
        NSString *rank = [NSString stringWithFormat:@"%ld", (long)album.rank];
        NSDictionary *rankAttrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:9 weight:NSFontWeightBold],
            NSForegroundColorAttributeName: [NSColor whiteColor]
        };
        NSSize rankSize = [rank sizeWithAttributes:rankAttrs];
        NSRect badgeRect = NSMakeRect(x + 2, y + 2, rankSize.width + 6, rankSize.height + 2);

        [[NSColor colorWithWhite:0 alpha:0.6] setFill];
        NSBezierPath *badgePath = [NSBezierPath bezierPathWithRoundedRect:badgeRect xRadius:3 yRadius:3];
        [badgePath fill];

        [rank drawAtPoint:NSMakePoint(x + 5, y + 3) withAttributes:rankAttrs];

        col++;
        if (col >= albumsPerRow) {
            col = 0;
            x = startX;
            y += albumSize + spacing;
        } else {
            x += albumSize + spacing;
        }
    }

    // If we ended mid-row, move to next line
    if (col > 0) {
        y += albumSize + spacing;
    }

    return y;
}

- (void)drawImage:(NSImage *)image inRect:(NSRect)rect {
    NSSize imageSize = image.size;
    if (imageSize.width <= 0 || imageSize.height <= 0) return;

    // Scale to fill (crop if needed)
    CGFloat imageAspect = imageSize.width / imageSize.height;
    CGFloat viewAspect = rect.size.width / rect.size.height;

    NSRect sourceRect;
    if (imageAspect > viewAspect) {
        // Image is wider - crop sides
        CGFloat newWidth = imageSize.height * viewAspect;
        CGFloat x = (imageSize.width - newWidth) / 2;
        sourceRect = NSMakeRect(x, 0, newWidth, imageSize.height);
    } else {
        // Image is taller - crop top/bottom
        CGFloat newHeight = imageSize.width / viewAspect;
        CGFloat y = (imageSize.height - newHeight) / 2;
        sourceRect = NSMakeRect(0, y, imageSize.width, newHeight);
    }

    [image drawInRect:rect
             fromRect:sourceRect
            operation:NSCompositingOperationSourceOver
             fraction:1.0
       respectFlipped:YES
                hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
}

- (void)drawStatusFooterAtY:(CGFloat)y width:(CGFloat)width {
    NSDictionary *statusAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10],
        NSForegroundColorAttributeName: [NSColor tertiaryLabelColor]
    };

    // Scrobbled today
    NSString *todayText;
    if (_scrobbledToday >= 200) {
        todayText = @"200+ scrobbles today";
    } else {
        todayText = [NSString stringWithFormat:@"%ld scrobbles today", (long)_scrobbledToday];
    }

    // Queue status
    NSString *queueText = @"";
    if (_queueCount > 0) {
        queueText = [NSString stringWithFormat:@" | %ld queued", (long)_queueCount];
    }

    NSString *statusText = [todayText stringByAppendingString:queueText];
    NSRect statusRect = NSMakeRect(kPadding, y, width, 14);
    [statusText drawInRect:statusRect withAttributes:statusAttrs];

    // Last updated timestamp (right-aligned)
    if (_lastUpdated) {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.timeStyle = NSDateFormatterShortStyle;
        formatter.dateStyle = NSDateFormatterNoStyle;

        NSString *timeText = [NSString stringWithFormat:@"Updated %@", [formatter stringFromDate:_lastUpdated]];
        NSSize timeSize = [timeText sizeWithAttributes:statusAttrs];
        NSRect timeRect = NSMakeRect(kPadding + width - timeSize.width, y, timeSize.width, 14);
        [timeText drawInRect:timeRect withAttributes:statusAttrs];
    }
}

#pragma mark - Album Tooltip

- (void)drawAlbumTooltipForIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_topAlbums.count || index >= (NSInteger)_albumRects.count) {
        return;
    }

    TopAlbum *album = _topAlbums[index];
    NSRect albumRect = [_albumRects[index] rectValue];

    // Build tooltip text
    NSString *artistText = album.artist.length > 0 ? album.artist : @"Unknown Artist";
    NSString *albumText = album.name.length > 0 ? album.name : @"Unknown Album";
    NSString *playsText = [NSString stringWithFormat:@"%ld plays", (long)album.playcount];

    // Calculate tooltip size
    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: [NSColor whiteColor]
    };
    NSDictionary *subtitleAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:0.85 alpha:1.0]
    };
    NSDictionary *playsAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:9],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:0.7 alpha:1.0]
    };

    NSSize albumSize = [albumText sizeWithAttributes:titleAttrs];
    NSSize artistSize = [artistText sizeWithAttributes:subtitleAttrs];
    NSSize playsSize = [playsText sizeWithAttributes:playsAttrs];

    CGFloat tooltipWidth = MAX(albumSize.width, MAX(artistSize.width, playsSize.width)) + 16;
    CGFloat tooltipHeight = albumSize.height + artistSize.height + playsSize.height + 14;

    // Clamp width
    tooltipWidth = MIN(tooltipWidth, 250);
    tooltipWidth = MAX(tooltipWidth, 100);

    // Position tooltip below the album, centered
    CGFloat tooltipX = albumRect.origin.x + (albumRect.size.width - tooltipWidth) / 2;
    CGFloat tooltipY = albumRect.origin.y + albumRect.size.height + 4;

    // Keep tooltip within view bounds
    if (tooltipX < kPadding) tooltipX = kPadding;
    if (tooltipX + tooltipWidth > self.bounds.size.width - kPadding) {
        tooltipX = self.bounds.size.width - kPadding - tooltipWidth;
    }

    // If tooltip would go below view, show it above the album instead
    if (tooltipY + tooltipHeight > self.bounds.size.height - kPadding) {
        tooltipY = albumRect.origin.y - tooltipHeight - 4;
    }

    NSRect tooltipRect = NSMakeRect(tooltipX, tooltipY, tooltipWidth, tooltipHeight);

    // Draw tooltip background with shadow
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowColor = [[NSColor blackColor] colorWithAlphaComponent:0.4];
    shadow.shadowOffset = NSMakeSize(0, -2);
    shadow.shadowBlurRadius = 6;

    [NSGraphicsContext saveGraphicsState];
    [shadow set];

    [[NSColor colorWithWhite:0.15 alpha:0.95] setFill];
    NSBezierPath *bgPath = [NSBezierPath bezierPathWithRoundedRect:tooltipRect xRadius:6 yRadius:6];
    [bgPath fill];

    [NSGraphicsContext restoreGraphicsState];

    // Draw border
    [[NSColor colorWithWhite:0.3 alpha:1.0] setStroke];
    [bgPath stroke];

    // Draw text
    CGFloat textX = tooltipRect.origin.x + 8;
    CGFloat textY = tooltipRect.origin.y + 6;

    NSRect albumTextRect = NSMakeRect(textX, textY, tooltipWidth - 16, albumSize.height);
    [albumText drawInRect:albumTextRect withAttributes:titleAttrs];

    textY += albumSize.height + 2;
    NSRect artistTextRect = NSMakeRect(textX, textY, tooltipWidth - 16, artistSize.height);
    [artistText drawInRect:artistTextRect withAttributes:subtitleAttrs];

    textY += artistSize.height + 2;
    NSRect playsTextRect = NSMakeRect(textX, textY, tooltipWidth - 16, playsSize.height);
    [playsText drawInRect:playsTextRect withAttributes:playsAttrs];
}

#pragma mark - Helper Methods

- (void)drawCenteredText:(NSString *)text color:(NSColor *)color {
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13],
        NSForegroundColorAttributeName: color
    };

    NSSize size = [text sizeWithAttributes:attrs];
    CGFloat x = (self.bounds.size.width - size.width) / 2;
    CGFloat y = (self.bounds.size.height - size.height) / 2;

    [text drawAtPoint:NSMakePoint(x, y) withAttributes:attrs];
}

#pragma mark - Public Methods

- (void)refreshDisplay {
    [self setNeedsDisplay:YES];
}

@end
