//
//  ScrobbleWidgetView.mm
//  foo_jl_scrobble_mac
//
//  Custom NSView for displaying Last.fm stats widget
//

#import "ScrobbleWidgetView.h"
#import "../Core/TopAlbum.h"
#import "../Core/RecentTrack.h"
#import <QuartzCore/QuartzCore.h>

#import "../Core/WidgetLayoutMath.h"

static const CGFloat kArrowWidth = 32.0;
static const CGFloat kArrowChevronSize = 16.0;
static const CGFloat kTrackRowHeight = 44.0;
static const CGFloat kTrackArtSize = 36.0;
// Layout constants owned by WidgetLayoutMath.h (single source of truth)
static const CGFloat kAlbumSpacing = WidgetLayout::kAlbumSpacing;
static const CGFloat kProfileHeight = 40.0;
static const CGFloat kFooterHeight = 20.0;
static const CGFloat kPadding = WidgetLayout::kPadding;
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
// Period/Type dropdown pill rects
@property (nonatomic, assign) NSRect periodPillRect;
@property (nonatomic, assign) BOOL isOverPeriodPill;
@property (nonatomic, assign) NSRect typePillRect;
@property (nonatomic, assign) BOOL isOverTypePill;
// Reload button
@property (nonatomic, assign) NSRect reloadButtonRect;
@property (nonatomic, assign) BOOL isOverReloadButton;
// View mode pill
@property (nonatomic, assign) NSRect viewModePillRect;
@property (nonatomic, assign) BOOL isOverViewModePill;
// Track count pill (Tracks mode only)
@property (nonatomic, assign) NSRect trackCountPillRect;
@property (nonatomic, assign) BOOL isOverTrackCountPill;
// Content area for arrow navigation
@property (nonatomic, assign) NSRect contentAreaRect;
@property (nonatomic, assign) BOOL isOverLeftArrow;
@property (nonatomic, assign) BOOL isOverRightArrow;
// Recent track row rects for hit testing
@property (nonatomic, strong) NSMutableArray<NSValue *> *trackRowRects;
@property (nonatomic, assign) NSInteger hoveredTrackIndex;
// Animation state
@property (nonatomic, assign) BOOL isAnimatingTransition;
// Glass effect
@property (nonatomic, strong, nullable) NSVisualEffectView *glassEffectView;
// Scroll state
@property (nonatomic, assign) CGFloat contentScrollOffset;   // Current scroll offset (0 = top)
@property (nonatomic, assign) CGFloat contentTotalHeight;    // Total content height (for scroll bounds)
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
        _currentPeriod = ScrobbleChartPeriodWeekly;
        _currentType = ScrobbleChartTypeAlbums;
        _periodTitle = [ScrobbleWidgetView titleForPeriod:_currentPeriod];
        _typeTitle = [ScrobbleWidgetView titleForType:_currentType];
        _hoveredAlbumIndex = -1;
        _hoveredTrackIndex = -1;
        _albumRects = [NSMutableArray array];
        _trackRowRects = [NSMutableArray array];
        _viewMode = ScrobbleWidgetViewModeCharts;
        _viewModeTitle = [ScrobbleWidgetView titleForViewMode:_viewMode];
        _recentTrackCount = 10;
        _contentScrollOffset = 0;
        _contentTotalHeight = 0;
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
    // Intentionally returns no intrinsic size - let layout system decide
    return NSMakeSize(NSViewNoIntrinsicMetric, NSViewNoIntrinsicMetric);
}

// Override fittingSize to not constrain layout
- (NSSize)fittingSize {
    // Return current bounds - let layout system control sizing
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

#pragma mark - Background Settings

- (void)setUseGlassBackground:(BOOL)useGlassBackground {
    if (_useGlassBackground == useGlassBackground) return;
    _useGlassBackground = useGlassBackground;

    if (useGlassBackground) {
        if (!_glassEffectView) {
            _glassEffectView = [[NSVisualEffectView alloc] initWithFrame:self.bounds];
            _glassEffectView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            _glassEffectView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
            _glassEffectView.material = NSVisualEffectMaterialSidebar;
            _glassEffectView.state = NSVisualEffectStateActive;
        }
        [self addSubview:_glassEffectView positioned:NSWindowBelow relativeTo:nil];
    } else {
        [_glassEffectView removeFromSuperview];
    }
    [self setNeedsDisplay:YES];
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

+ (NSString *)titleForViewMode:(ScrobbleWidgetViewMode)mode {
    switch (mode) {
        case ScrobbleWidgetViewModeCharts: return @"Charts";
        case ScrobbleWidgetViewModeTracks: return @"Tracks";
        default: return @"Charts";
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
    return WidgetLayout::albumSizeForWidth(availableWidth);
}

#pragma mark - Mouse Events

- (void)mouseEntered:(NSEvent *)event {
    _isHovered = YES;
    [self animateArrowOpacity:1.0];
}

- (void)mouseExited:(NSEvent *)event {
    _isHovered = NO;
    _hoveredAlbumIndex = -1;
    _hoveredTrackIndex = -1;
    _isOverProfileLink = NO;
    _isOverPeriodPill = NO;
    _isOverTypePill = NO;
    _isOverViewModePill = NO;
    _isOverTrackCountPill = NO;
    _isOverLeftArrow = NO;
    _isOverRightArrow = NO;
    [self animateArrowOpacity:0.0];
    [self setNeedsDisplay:YES];
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];

    NSInteger oldHoveredAlbum = _hoveredAlbumIndex;
    NSInteger oldHoveredTrack = _hoveredTrackIndex;
    BOOL wasOverProfileLink = _isOverProfileLink;
    BOOL wasOverPeriod = _isOverPeriodPill;
    BOOL wasOverType = _isOverTypePill;
    BOOL wasOverReload = _isOverReloadButton;
    BOOL wasOverViewMode = _isOverViewModePill;
    BOOL wasOverTrackCount = _isOverTrackCountPill;
    BOOL wasOverLeftArrow = _isOverLeftArrow;
    BOOL wasOverRightArrow = _isOverRightArrow;

    // Check if over profile link button
    _isOverProfileLink = !NSIsEmptyRect(_profileLinkRect) && NSPointInRect(location, _profileLinkRect);

    // Check reload button
    _isOverReloadButton = !NSIsEmptyRect(_reloadButtonRect) && NSPointInRect(location, _reloadButtonRect);

    // Check view mode pill
    _isOverViewModePill = !NSIsEmptyRect(_viewModePillRect) && NSPointInRect(location, _viewModePillRect);

    // Check period pill (Charts mode only)
    _isOverPeriodPill = (_viewMode == ScrobbleWidgetViewModeCharts) &&
        !NSIsEmptyRect(_periodPillRect) && NSPointInRect(location, _periodPillRect);

    // Check type pill (Charts mode only)
    _isOverTypePill = (_viewMode == ScrobbleWidgetViewModeCharts) &&
        !NSIsEmptyRect(_typePillRect) && NSPointInRect(location, _typePillRect);

    // Check track count pill (Tracks mode only)
    _isOverTrackCountPill = (_viewMode == ScrobbleWidgetViewModeTracks) &&
        !NSIsEmptyRect(_trackCountPillRect) && NSPointInRect(location, _trackCountPillRect);

    // Check content area arrow zones
    if (!NSIsEmptyRect(_contentAreaRect) && NSPointInRect(location, _contentAreaRect)) {
        _isOverLeftArrow = (location.x - _contentAreaRect.origin.x) < kArrowWidth;
        _isOverRightArrow = (_contentAreaRect.origin.x + _contentAreaRect.size.width - location.x) < kArrowWidth;
    } else {
        _isOverLeftArrow = NO;
        _isOverRightArrow = NO;
    }

    // Check which album is being hovered (Charts mode)
    _hoveredAlbumIndex = -1;
    if (_viewMode == ScrobbleWidgetViewModeCharts) {
        for (NSInteger i = 0; i < (NSInteger)_albumRects.count; i++) {
            NSRect rect = [_albumRects[i] rectValue];
            if (NSPointInRect(location, rect)) {
                _hoveredAlbumIndex = i;
                break;
            }
        }
    }

    // Check which track row is being hovered (Tracks mode)
    _hoveredTrackIndex = -1;
    if (_viewMode == ScrobbleWidgetViewModeTracks) {
        for (NSInteger i = 0; i < (NSInteger)_trackRowRects.count; i++) {
            NSRect rect = [_trackRowRects[i] rectValue];
            if (NSPointInRect(location, rect)) {
                _hoveredTrackIndex = i;
                break;
            }
        }
    }

    if (oldHoveredAlbum != _hoveredAlbumIndex || oldHoveredTrack != _hoveredTrackIndex ||
        wasOverProfileLink != _isOverProfileLink ||
        wasOverPeriod != _isOverPeriodPill || wasOverType != _isOverTypePill ||
        wasOverReload != _isOverReloadButton ||
        wasOverViewMode != _isOverViewModePill || wasOverTrackCount != _isOverTrackCountPill ||
        wasOverLeftArrow != _isOverLeftArrow || wasOverRightArrow != _isOverRightArrow) {
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

    // Check if clicking on reload button
    if (!NSIsEmptyRect(_reloadButtonRect) && NSPointInRect(location, _reloadButtonRect)) {
        if ([_delegate respondsToSelector:@selector(widgetViewRequestsRefresh:)]) {
            [_delegate widgetViewRequestsRefresh:self];
        }
        return;
    }

    // Check view mode pill
    if (_isOverViewModePill) {
        [self showViewModeMenu];
        return;
    }

    // Check period pill (Charts mode)
    if (_isOverPeriodPill && _viewMode == ScrobbleWidgetViewModeCharts) {
        [self showPeriodMenu];
        return;
    }

    // Check type pill (Charts mode)
    if (_isOverTypePill && _viewMode == ScrobbleWidgetViewModeCharts) {
        [self showTypeMenu];
        return;
    }

    // Check track count pill (Tracks mode)
    if (_isOverTrackCountPill && _viewMode == ScrobbleWidgetViewModeTracks) {
        [self showTrackCountMenu];
        return;
    }

    // Check content area arrows
    if (_isOverLeftArrow) {
        if ([_delegate respondsToSelector:@selector(widgetViewNavigatePreviousViewMode:)]) {
            [_delegate widgetViewNavigatePreviousViewMode:self];
        }
        return;
    }
    if (_isOverRightArrow) {
        if ([_delegate respondsToSelector:@selector(widgetViewNavigateNextViewMode:)]) {
            [_delegate widgetViewNavigateNextViewMode:self];
        }
        return;
    }

    // Check if clicking on an album (Charts mode)
    if (_viewMode == ScrobbleWidgetViewModeCharts) {
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

    // Check if clicking on a track row (Tracks mode)
    if (_viewMode == ScrobbleWidgetViewModeTracks) {
        for (NSInteger i = 0; i < (NSInteger)_trackRowRects.count; i++) {
            NSRect rect = [_trackRowRects[i] rectValue];
            if (NSPointInRect(location, rect)) {
                if ([_delegate respondsToSelector:@selector(widgetView:didClickRecentTrackAtIndex:)]) {
                    [_delegate widgetView:self didClickRecentTrackAtIndex:i];
                }
                return;
            }
        }
    }
}

- (void)scrollWheel:(NSEvent *)event {
    if (_state != ScrobbleWidgetStateReady) return;
    if (NSIsEmptyRect(_contentAreaRect)) return;

    // Only scroll if mouse is in content area
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];
    if (!NSPointInRect(location, _contentAreaRect)) {
        [super scrollWheel:event];
        return;
    }

    CGFloat maxOffset = MAX(0, _contentTotalHeight - _contentAreaRect.size.height);
    if (maxOffset <= 0) return;  // Content fits, no scrolling needed

    // deltaY is positive when scrolling up (content moves down), negative when scrolling down
    CGFloat delta = event.scrollingDeltaY;
    if (event.hasPreciseScrollingDeltas) {
        _contentScrollOffset -= delta;
    } else {
        _contentScrollOffset -= delta * 20.0;  // Line-based scrolling
    }

    _contentScrollOffset = WidgetLayout::clampScrollOffset(_contentScrollOffset,
                                                           _contentTotalHeight,
                                                           _contentAreaRect.size.height);

    [self setNeedsDisplay:YES];
}

- (void)showPeriodMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Period"];

    NSMenuItem *weeklyItem = [[NSMenuItem alloc] initWithTitle:@"Weekly" action:@selector(selectPeriodWeekly:) keyEquivalent:@""];
    weeklyItem.target = self;
    weeklyItem.state = (_currentPeriod == ScrobbleChartPeriodWeekly) ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:weeklyItem];

    NSMenuItem *monthlyItem = [[NSMenuItem alloc] initWithTitle:@"Monthly" action:@selector(selectPeriodMonthly:) keyEquivalent:@""];
    monthlyItem.target = self;
    monthlyItem.state = (_currentPeriod == ScrobbleChartPeriodMonthly) ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:monthlyItem];

    NSMenuItem *overallItem = [[NSMenuItem alloc] initWithTitle:@"All Time" action:@selector(selectPeriodOverall:) keyEquivalent:@""];
    overallItem.target = self;
    overallItem.state = (_currentPeriod == ScrobbleChartPeriodOverall) ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:overallItem];

    NSPoint menuPoint = NSMakePoint(_periodPillRect.origin.x, _periodPillRect.origin.y + _periodPillRect.size.height);
    [menu popUpMenuPositioningItem:nil atLocation:menuPoint inView:self];
}

- (void)showTypeMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Type"];

    NSMenuItem *albumsItem = [[NSMenuItem alloc] initWithTitle:@"Albums" action:@selector(selectTypeAlbums:) keyEquivalent:@""];
    albumsItem.target = self;
    albumsItem.state = (_currentType == ScrobbleChartTypeAlbums) ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:albumsItem];

    NSMenuItem *artistsItem = [[NSMenuItem alloc] initWithTitle:@"Artists" action:@selector(selectTypeArtists:) keyEquivalent:@""];
    artistsItem.target = self;
    artistsItem.state = (_currentType == ScrobbleChartTypeArtists) ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:artistsItem];

    NSMenuItem *tracksItem = [[NSMenuItem alloc] initWithTitle:@"Tracks" action:@selector(selectTypeTracks:) keyEquivalent:@""];
    tracksItem.target = self;
    tracksItem.state = (_currentType == ScrobbleChartTypeTracks) ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:tracksItem];

    NSPoint menuPoint = NSMakePoint(_typePillRect.origin.x, _typePillRect.origin.y + _typePillRect.size.height);
    [menu popUpMenuPositioningItem:nil atLocation:menuPoint inView:self];
}

- (void)selectPeriodWeekly:(id)sender {
    if ([_delegate respondsToSelector:@selector(widgetView:didSelectPeriod:)]) {
        [_delegate widgetView:self didSelectPeriod:ScrobbleChartPeriodWeekly];
    }
}

- (void)selectPeriodMonthly:(id)sender {
    if ([_delegate respondsToSelector:@selector(widgetView:didSelectPeriod:)]) {
        [_delegate widgetView:self didSelectPeriod:ScrobbleChartPeriodMonthly];
    }
}

- (void)selectPeriodOverall:(id)sender {
    if ([_delegate respondsToSelector:@selector(widgetView:didSelectPeriod:)]) {
        [_delegate widgetView:self didSelectPeriod:ScrobbleChartPeriodOverall];
    }
}

- (void)selectTypeAlbums:(id)sender {
    if ([_delegate respondsToSelector:@selector(widgetView:didSelectType:)]) {
        [_delegate widgetView:self didSelectType:ScrobbleChartTypeAlbums];
    }
}

- (void)selectTypeArtists:(id)sender {
    if ([_delegate respondsToSelector:@selector(widgetView:didSelectType:)]) {
        [_delegate widgetView:self didSelectType:ScrobbleChartTypeArtists];
    }
}

- (void)selectTypeTracks:(id)sender {
    if ([_delegate respondsToSelector:@selector(widgetView:didSelectType:)]) {
        [_delegate widgetView:self didSelectType:ScrobbleChartTypeTracks];
    }
}

- (void)showViewModeMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"View"];

    NSMenuItem *chartsItem = [[NSMenuItem alloc] initWithTitle:@"Charts" action:@selector(selectViewModeCharts:) keyEquivalent:@""];
    chartsItem.target = self;
    chartsItem.state = (_viewMode == ScrobbleWidgetViewModeCharts) ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:chartsItem];

    NSMenuItem *tracksItem = [[NSMenuItem alloc] initWithTitle:@"Tracks" action:@selector(selectViewModeTracks:) keyEquivalent:@""];
    tracksItem.target = self;
    tracksItem.state = (_viewMode == ScrobbleWidgetViewModeTracks) ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:tracksItem];

    NSPoint menuPoint = NSMakePoint(_viewModePillRect.origin.x, _viewModePillRect.origin.y + _viewModePillRect.size.height);
    [menu popUpMenuPositioningItem:nil atLocation:menuPoint inView:self];
}

- (void)selectViewModeCharts:(id)sender {
    if ([_delegate respondsToSelector:@selector(widgetView:didSelectViewMode:)]) {
        [_delegate widgetView:self didSelectViewMode:ScrobbleWidgetViewModeCharts];
    }
}

- (void)selectViewModeTracks:(id)sender {
    if ([_delegate respondsToSelector:@selector(widgetView:didSelectViewMode:)]) {
        [_delegate widgetView:self didSelectViewMode:ScrobbleWidgetViewModeTracks];
    }
}

- (void)showTrackCountMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Show"];

    for (NSNumber *count in @[@10, @30, @50]) {
        NSString *title = [NSString stringWithFormat:@"%@", count];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(selectTrackCount:) keyEquivalent:@""];
        item.target = self;
        item.tag = count.integerValue;
        item.state = (_recentTrackCount == count.integerValue) ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:item];
    }

    NSPoint menuPoint = NSMakePoint(_trackCountPillRect.origin.x, _trackCountPillRect.origin.y + _trackCountPillRect.size.height);
    [menu popUpMenuPositioningItem:nil atLocation:menuPoint inView:self];
}

- (void)selectTrackCount:(NSMenuItem *)sender {
    if ([_delegate respondsToSelector:@selector(widgetView:didSelectTrackCount:)]) {
        [_delegate widgetView:self didSelectTrackCount:sender.tag];
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

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:1.0/60.0 repeats:YES block:^(NSTimer *t) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                [t invalidate];
                return;
            }

            NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - startTime;
            CGFloat progress = MIN(1.0, elapsed / duration);

            // Ease out
            progress = 1.0 - pow(1.0 - progress, 2);

            strongSelf->_arrowOpacity = startOpacity + (targetOpacity - startOpacity) * progress;
            [strongSelf setNeedsDisplay:YES];

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

    // Background (skip if using glass effect - it handles its own background)
    if (!_useGlassBackground) {
        NSColor *bgColor = _backgroundColor ?: [NSColor windowBackgroundColor];
        [bgColor setFill];
        NSRectFill(dirtyRect);
    }

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
    CGFloat viewHeight = self.bounds.size.height;
    CGFloat y = kPadding;

    // Profile section (compact header) - shared across all display styles
    CGFloat headerEndY = [self drawProfileSectionAtY:y width:contentWidth];

    // Footer is sticky at bottom
    CGFloat footerY = viewHeight - kFooterHeight - kPadding;

    // Available space for content (between header and footer)
    CGFloat contentStartY = headerEndY;
    CGFloat contentEndY = footerY - kPadding;
    CGFloat availableHeight = contentEndY - contentStartY;

    // Store content area for arrow hit testing
    _contentAreaRect = NSMakeRect(kPadding, contentStartY, contentWidth, availableHeight);

    // Clamp scroll offset before drawing (content may have changed)
    CGFloat maxOffset = MAX(0, _contentTotalHeight - availableHeight);
    if (_contentScrollOffset > maxOffset) _contentScrollOffset = maxOffset;
    if (_contentScrollOffset < 0) _contentScrollOffset = 0;

    // Clip to content area so scrolled content doesn't overflow into header/footer
    [NSGraphicsContext saveGraphicsState];
    NSBezierPath *clipPath = [NSBezierPath bezierPathWithRect:_contentAreaRect];
    [clipPath addClip];

    // Apply scroll offset: shift drawing origin upward
    CGFloat scrolledStartY = contentStartY - _contentScrollOffset;

    if (_viewMode == ScrobbleWidgetViewModeTracks) {
        // Recent tracks list
        [self drawRecentTracksListAtY:scrolledStartY width:contentWidth];
    } else if (_displayStyle == ScrobbleDisplayStylePlayback2025) {
        // Bubble layout - no scrolling (fits in visible area)
        _contentTotalHeight = 0;
        CGFloat bubbleSize = MIN(contentWidth, availableHeight);
        CGFloat bubbleStartY = contentStartY + (availableHeight - bubbleSize) / 2;
        [self drawBubbleLayoutAtY:bubbleStartY width:contentWidth availableHeight:bubbleSize];
    } else {
        // Calculate album size based on available width
        CGFloat oldAlbumSize = _calculatedAlbumSize;
        _calculatedAlbumSize = [self calculateAlbumSizeForWidth:contentWidth];

        if (fabs(oldAlbumSize - _calculatedAlbumSize) > 0.1) {
            NSLog(@"[ScrobbleWidget] drawReadyState - bounds: %@, contentWidth: %.1f, albumSize: %.1f -> %.1f, maxAlbums: %ld",
                  NSStringFromRect(self.bounds), contentWidth, oldAlbumSize, _calculatedAlbumSize, (long)_maxAlbums);
        }

        // Album grid (top-aligned)
        [self drawAlbumGridAtY:scrolledStartY width:contentWidth];
    }

    [NSGraphicsContext restoreGraphicsState];

    // Navigation arrows (drawn over content area on hover, outside clip)
    if (_isHovered && _arrowOpacity > 0.01) {
        [self drawNavigationArrowsInRect:_contentAreaRect];
    }

    // Status footer (sticky at bottom)
    [self drawStatusFooterAtY:footerY width:contentWidth];
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

    // Reload and Link buttons on the far right
    CGFloat buttonSize = 22.0;
    CGFloat buttonGap = 2.0;

    // Link button (rightmost)
    _profileLinkRect = NSMakeRect(kPadding + width - buttonSize, y + (rowHeight - buttonSize) / 2,
                                   buttonSize, buttonSize);
    NSColor *linkColor = _isOverProfileLink ? [NSColor controlAccentColor] : [NSColor secondaryLabelColor];
    [self drawExternalLinkIconInRect:_profileLinkRect color:linkColor];

    // Reload button (left of link button)
    _reloadButtonRect = NSMakeRect(_profileLinkRect.origin.x - buttonSize - buttonGap, y + (rowHeight - buttonSize) / 2,
                                    buttonSize, buttonSize);
    NSColor *reloadColor = _isOverReloadButton ? [NSColor controlAccentColor] : [NSColor secondaryLabelColor];
    [self drawReloadIconInRect:_reloadButtonRect color:reloadColor];

    // Calculate navigation area (between profile and buttons)
    CGFloat navAreaStart = x;
    CGFloat navAreaWidth = width - profileSize - spacing - (buttonSize * 2 + buttonGap) - spacing;
    CGFloat navAreaCenterX = navAreaStart + navAreaWidth / 2;

    // Measure text sizes for dropdown pills
    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor labelColor]
    };
    NSString *viewModeText = _viewModeTitle ?: @"Charts";
    NSSize viewModeSize = [viewModeText sizeWithAttributes:titleAttrs];

    CGFloat chevronWidth = 8.0, pillPadH = 8.0;
    CGFloat pillGap = 4.0;
    CGFloat pillHeight = 20.0;
    CGFloat centerY = y + rowHeight / 2;

    // Calculate pill widths - view mode pill is always visible
    CGFloat viewModePillWidth = pillPadH + viewModeSize.width + 4 + chevronWidth + pillPadH;
    CGFloat totalWidth = viewModePillWidth;

    // Clear conditional pill rects
    _periodPillRect = NSZeroRect;
    _typePillRect = NSZeroRect;
    _trackCountPillRect = NSZeroRect;

    if (_viewMode == ScrobbleWidgetViewModeCharts) {
        // Charts mode: [Charts v] [Weekly v] [Albums v]
        NSString *periodText = _periodTitle ?: @"Weekly";
        NSString *typeText = _typeTitle ?: @"Albums";
        NSSize periodSize = [periodText sizeWithAttributes:titleAttrs];
        NSSize typeSize = [typeText sizeWithAttributes:titleAttrs];
        CGFloat periodPillWidth = pillPadH + periodSize.width + 4 + chevronWidth + pillPadH;
        CGFloat typePillWidth = pillPadH + typeSize.width + 4 + chevronWidth + pillPadH;
        totalWidth += pillGap + periodPillWidth + pillGap + typePillWidth;
        CGFloat startX = navAreaCenterX - totalWidth / 2;

        // Draw view mode pill
        [self drawPill:viewModeText atX:startX centerY:centerY width:viewModePillWidth height:pillHeight
                 attrs:titleAttrs chevronWidth:chevronWidth padH:pillPadH hovered:_isOverViewModePill
              storeRect:&_viewModePillRect];

        // Draw period pill
        CGFloat periodStartX = startX + viewModePillWidth + pillGap;
        [self drawPill:periodText atX:periodStartX centerY:centerY width:periodPillWidth height:pillHeight
                 attrs:titleAttrs chevronWidth:chevronWidth padH:pillPadH hovered:_isOverPeriodPill
              storeRect:&_periodPillRect];

        // Draw type pill
        CGFloat typeStartX = periodStartX + periodPillWidth + pillGap;
        [self drawPill:typeText atX:typeStartX centerY:centerY width:typePillWidth height:pillHeight
                 attrs:titleAttrs chevronWidth:chevronWidth padH:pillPadH hovered:_isOverTypePill
              storeRect:&_typePillRect];
    } else {
        // Tracks mode: [Tracks v] [Show: 10 v]
        NSString *countText = [NSString stringWithFormat:@"Show: %ld", (long)_recentTrackCount];
        NSSize countSize = [countText sizeWithAttributes:titleAttrs];
        CGFloat countPillWidth = pillPadH + countSize.width + 4 + chevronWidth + pillPadH;
        totalWidth += pillGap + countPillWidth;
        CGFloat startX = navAreaCenterX - totalWidth / 2;

        // Draw view mode pill
        [self drawPill:viewModeText atX:startX centerY:centerY width:viewModePillWidth height:pillHeight
                 attrs:titleAttrs chevronWidth:chevronWidth padH:pillPadH hovered:_isOverViewModePill
              storeRect:&_viewModePillRect];

        // Draw track count pill
        CGFloat countStartX = startX + viewModePillWidth + pillGap;
        [self drawPill:countText atX:countStartX centerY:centerY width:countPillWidth height:pillHeight
                 attrs:titleAttrs chevronWidth:chevronWidth padH:pillPadH hovered:_isOverTrackCountPill
              storeRect:&_trackCountPillRect];
    }

    return y + rowHeight + spacing;
}

- (void)drawPill:(NSString *)text atX:(CGFloat)x centerY:(CGFloat)cy width:(CGFloat)w height:(CGFloat)h
           attrs:(NSDictionary *)attrs chevronWidth:(CGFloat)chevW padH:(CGFloat)padH
         hovered:(BOOL)hovered storeRect:(NSRect *)outRect {
    NSRect pill = NSMakeRect(x, cy - h / 2, w, h);
    if (outRect) *outRect = pill;
    NSColor *bg = hovered ? [NSColor colorWithWhite:0.5 alpha:0.2] : [NSColor colorWithWhite:0.5 alpha:0.12];
    [bg setFill];
    [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:h/2 yRadius:h/2] fill];

    NSSize textSize = [text sizeWithAttributes:attrs];
    CGFloat textX = x + padH;
    CGFloat textY = cy - textSize.height / 2;
    [text drawAtPoint:NSMakePoint(textX, textY) withAttributes:attrs];
    [self drawDropdownChevronAtX:textX + textSize.width + 4 centerY:cy hovered:hovered];
}

- (void)drawDropdownChevronAtX:(CGFloat)x centerY:(CGFloat)centerY hovered:(BOOL)hovered {
    CGFloat size = 4.0;
    NSColor *color = hovered ? [NSColor controlAccentColor] : [NSColor secondaryLabelColor];

    NSBezierPath *chevron = [NSBezierPath bezierPath];
    chevron.lineWidth = 1.2;
    chevron.lineCapStyle = NSLineCapStyleRound;
    chevron.lineJoinStyle = NSLineJoinStyleRound;

    // Down chevron (v shape)
    [chevron moveToPoint:NSMakePoint(x, centerY - size/2)];
    [chevron lineToPoint:NSMakePoint(x + size, centerY + size/2)];
    [chevron lineToPoint:NSMakePoint(x + size*2, centerY - size/2)];

    [color setStroke];
    [chevron stroke];
}

- (void)drawReloadIconInRect:(NSRect)rect color:(NSColor *)color {
    // Draw a circular arrow (refresh icon)
    CGFloat inset = 5.0;
    NSRect iconRect = NSInsetRect(rect, inset, inset);
    CGFloat cx = NSMidX(iconRect);
    CGFloat cy = NSMidY(iconRect);
    CGFloat radius = iconRect.size.width / 2 - 1;

    NSBezierPath *path = [NSBezierPath bezierPath];
    path.lineWidth = 1.5;
    path.lineCapStyle = NSLineCapStyleRound;

    // Draw arc (about 270 degrees, leaving a gap for the arrow)
    CGFloat startAngle = 45.0;   // degrees
    CGFloat endAngle = 315.0;    // degrees
    [path appendBezierPathWithArcWithCenter:NSMakePoint(cx, cy)
                                     radius:radius
                                 startAngle:startAngle
                                   endAngle:endAngle
                                  clockwise:NO];

    [color setStroke];
    [path stroke];

    // Draw arrowhead at the end of the arc
    CGFloat arrowAngle = endAngle * M_PI / 180.0;
    CGFloat arrowX = cx + radius * cos(arrowAngle);
    CGFloat arrowY = cy + radius * sin(arrowAngle);

    CGFloat arrowSize = 3.0;
    NSBezierPath *arrow = [NSBezierPath bezierPath];
    arrow.lineWidth = 1.5;
    arrow.lineCapStyle = NSLineCapStyleRound;
    arrow.lineJoinStyle = NSLineJoinStyleRound;

    // Arrow pointing in direction of arc travel (clockwise at this point)
    [arrow moveToPoint:NSMakePoint(arrowX - arrowSize, arrowY + arrowSize)];
    [arrow lineToPoint:NSMakePoint(arrowX, arrowY)];
    [arrow lineToPoint:NSMakePoint(arrowX + arrowSize, arrowY + arrowSize)];

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

- (CGFloat)drawBubbleLayoutAtY:(CGFloat)y width:(CGFloat)width availableHeight:(CGFloat)availableHeight {
    // Clear stored rects
    [_albumRects removeAllObjects];

    if (_topAlbums.count == 0) {
        return y;
    }

    // Use a square area for the bubble layout (passed in, already computed for centering)
    CGFloat areaSize = WidgetLayout::bubbleAreaSize(width, availableHeight);

    CGFloat offsetX = kPadding + (width - areaSize) / 2;
    CGFloat offsetY = y;

    NSInteger count = MIN((NSInteger)_topAlbums.count, WidgetLayout::kMaxBubbles);

    for (NSInteger i = 0; i < count; i++) {
        TopAlbum *album = _topAlbums[i];

        NSRect circleRect = WidgetLayout::bubbleRectForIndex(i, offsetX, offsetY, areaSize);
        CGFloat r = circleRect.size.width / 2;
        CGFloat cx = NSMidX(circleRect);
        CGFloat cy = NSMidY(circleRect);
        CGFloat diameter = circleRect.size.width;

        // Store rect for hit testing
        [_albumRects addObject:[NSValue valueWithRect:circleRect]];

        // Skip actual drawing during animation (layers handle visuals)
        if (_isAnimatingTransition) continue;

        // Clip to circle
        NSBezierPath *clipPath = [NSBezierPath bezierPathWithOvalInRect:circleRect];

        // Try to get loaded image
        NSImage *albumImage = nil;
        if (album.imageURL && _albumImages) {
            albumImage = _albumImages[album.imageURL];
        }

        if (albumImage) {
            [NSGraphicsContext saveGraphicsState];
            [clipPath addClip];
            [self drawImage:albumImage inRect:circleRect];
            [NSGraphicsContext restoreGraphicsState];
        } else {
            // Placeholder circle
            [[NSColor tertiaryLabelColor] setFill];
            [clipPath fill];

            // Draw name centered in placeholder
            if (album.name.length > 0) {
                NSMutableParagraphStyle *paraStyle = [[NSMutableParagraphStyle alloc] init];
                paraStyle.alignment = NSTextAlignmentCenter;
                paraStyle.lineBreakMode = NSLineBreakByWordWrapping;

                CGFloat fontSize = MAX(8.0, r * 0.25);
                NSDictionary *nameAttrs = @{
                    NSFontAttributeName: [NSFont systemFontOfSize:fontSize],
                    NSForegroundColorAttributeName: [NSColor secondaryLabelColor],
                    NSParagraphStyleAttributeName: paraStyle
                };

                CGFloat textInset = r * 0.3;
                NSRect textRect = NSMakeRect(cx - r + textInset, cy - r * 0.4,
                                             diameter - textInset * 2, r * 0.8);
                [album.name drawInRect:textRect withAttributes:nameAttrs];
            }
        }

        // Draw subtle circle border
        [[NSColor colorWithWhite:0.5 alpha:0.2] setStroke];
        [clipPath setLineWidth:1.0];
        [clipPath stroke];

        // Rank badge removed from bubbles - shown in tooltip instead
    }

    return offsetY + areaSize + kAlbumSpacing;
}

- (CGFloat)drawAlbumGridAtY:(CGFloat)y width:(CGFloat)width {
    // Clear stored rects
    [_albumRects removeAllObjects];

    if (_topAlbums.count == 0) {
        _contentTotalHeight = 0;
        return y;
    }

    CGFloat albumSize = _calculatedAlbumSize;
    CGFloat spacing = kAlbumSpacing;

    WidgetLayout::GridGeometry grid =
        WidgetLayout::gridGeometryForWidth(width, albumSize, (NSInteger)_topAlbums.count);
    _contentTotalHeight = grid.contentHeight;

    NSInteger index = 0;

    for (TopAlbum *album in _topAlbums) {
        NSRect albumRect = WidgetLayout::gridRectForIndex(grid, albumSize, y, index);
        CGFloat x = albumRect.origin.x;
        CGFloat rowY = albumRect.origin.y;

        // Store rect for hit testing
        [_albumRects addObject:[NSValue valueWithRect:albumRect]];

        // Skip actual drawing during animation (layers handle visuals)
        if (!_isAnimatingTransition) {
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
                    NSRect textRect = NSMakeRect(x + 4, rowY + 24, albumSize - 8, albumSize - 28);
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
            NSRect badgeRect = NSMakeRect(x + 2, rowY + 2, rankSize.width + 6, rankSize.height + 2);

            [[NSColor colorWithWhite:0 alpha:0.6] setFill];
            NSBezierPath *badgePath = [NSBezierPath bezierPathWithRoundedRect:badgeRect xRadius:3 yRadius:3];
            [badgePath fill];

            [rank drawAtPoint:NSMakePoint(x + 5, rowY + 3) withAttributes:rankAttrs];
        }

        index++;
    }

    // Bottom of the grid: every row (full or partial) advances one row height
    return y + grid.totalRows * (albumSize + spacing);
}

- (void)drawImage:(NSImage *)image inRect:(NSRect)rect {
    NSSize imageSize = image.size;
    if (imageSize.width <= 0 || imageSize.height <= 0) return;

    // Scale to fill (crop if needed)
    NSRect sourceRect = WidgetLayout::aspectFillSourceRect(imageSize, rect.size);

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
    NSDictionary *errorAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10],
        NSForegroundColorAttributeName: [NSColor systemOrangeColor]
    };

    // If there's an error message in Ready state, show it instead of normal status
    if (_errorMessage.length > 0 && _state == ScrobbleWidgetStateReady) {
        NSString *errorText = WidgetFooterErrorText(_errorMessage);
        NSRect errorRect = NSMakeRect(kPadding, y, width, 14);
        [errorText drawInRect:errorRect withAttributes:errorAttrs];
        return;
    }

    // "15 day streak | 7 scrobbles today | 2 queued         Updated 14:32"
    NSString *statusText = WidgetFooterStatusText(_streakEnabled,
                                                  _streakDays,
                                                  _streakDiscoveryInProgress,
                                                  _streakNeedsContinuation,
                                                  _scrobbledToday,
                                                  _queueCount);

    NSRect statusRect = NSMakeRect(kPadding, y, width, 14);
    [statusText drawInRect:statusRect withAttributes:statusAttrs];

    // Last updated timestamp (right-aligned)
    if (_lastUpdated) {
        static NSDateFormatter *formatter = nil;
        static dispatch_once_t formatterOnce;
        dispatch_once(&formatterOnce, ^{
            formatter = [[NSDateFormatter alloc] init];
            formatter.timeStyle = NSDateFormatterShortStyle;
            formatter.dateStyle = NSDateFormatterNoStyle;
        });

        NSString *timeText = [NSString stringWithFormat:@"Updated %@", [formatter stringFromDate:_lastUpdated]];
        NSSize timeSize = [timeText sizeWithAttributes:statusAttrs];
        NSRect timeRect = NSMakeRect(kPadding + width - timeSize.width, y, timeSize.width, 14);
        [timeText drawInRect:timeRect withAttributes:statusAttrs];
    }
}

#pragma mark - Album Tooltip

#pragma mark - Navigation Arrows

- (void)drawNavigationArrowsInRect:(NSRect)rect {
    CGFloat alpha = _arrowOpacity * 0.7;

    // Left arrow
    NSRect leftArrowRect = NSMakeRect(rect.origin.x, rect.origin.y, kArrowWidth, rect.size.height);
    [self drawArrowInRect:leftArrowRect direction:-1 hovered:_isOverLeftArrow alpha:alpha];

    // Right arrow
    NSRect rightArrowRect = NSMakeRect(rect.origin.x + rect.size.width - kArrowWidth,
                                        rect.origin.y, kArrowWidth, rect.size.height);
    [self drawArrowInRect:rightArrowRect direction:1 hovered:_isOverRightArrow alpha:alpha];
}

- (void)drawArrowInRect:(NSRect)rect direction:(int)direction hovered:(BOOL)hovered alpha:(CGFloat)alpha {
    // Semi-transparent gradient background
    CGFloat bgAlpha = alpha * (hovered ? 0.6 : 0.4);
    NSColor *bgColor = [[NSColor blackColor] colorWithAlphaComponent:bgAlpha];
    NSColor *clearColor = [[NSColor blackColor] colorWithAlphaComponent:0];
    NSGradient *gradient;
    if (direction < 0) {
        gradient = [[NSGradient alloc] initWithStartingColor:bgColor endingColor:clearColor];
    } else {
        gradient = [[NSGradient alloc] initWithStartingColor:clearColor endingColor:bgColor];
    }
    [gradient drawInRect:rect angle:0];

    // Chevron
    CGFloat centerX = rect.origin.x + rect.size.width / 2;
    CGFloat centerY = rect.origin.y + rect.size.height / 2;
    CGFloat size = kArrowChevronSize;

    NSBezierPath *arrow = [NSBezierPath bezierPath];
    arrow.lineWidth = 2.5;
    arrow.lineCapStyle = NSLineCapStyleRound;
    arrow.lineJoinStyle = NSLineJoinStyleRound;

    if (direction < 0) {
        [arrow moveToPoint:NSMakePoint(centerX + size/3, centerY - size/2)];
        [arrow lineToPoint:NSMakePoint(centerX - size/3, centerY)];
        [arrow lineToPoint:NSMakePoint(centerX + size/3, centerY + size/2)];
    } else {
        [arrow moveToPoint:NSMakePoint(centerX - size/3, centerY - size/2)];
        [arrow lineToPoint:NSMakePoint(centerX + size/3, centerY)];
        [arrow lineToPoint:NSMakePoint(centerX - size/3, centerY + size/2)];
    }

    [[[NSColor whiteColor] colorWithAlphaComponent:alpha * (hovered ? 1.0 : 0.8)] setStroke];
    [arrow stroke];
}

#pragma mark - Recent Tracks Drawing

- (void)drawRecentTracksListAtY:(CGFloat)startY width:(CGFloat)width {
    [_trackRowRects removeAllObjects];

    // Calculate total content height for scrolling
    _contentTotalHeight = _recentTracks.count * kTrackRowHeight;

    if (!_recentTracks || _recentTracks.count == 0) {
        _contentTotalHeight = 0;
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:12],
            NSForegroundColorAttributeName: [NSColor secondaryLabelColor]
        };
        NSString *text = @"No recent tracks";
        NSSize textSize = [text sizeWithAttributes:attrs];
        CGFloat textX = kPadding + (width - textSize.width) / 2;
        CGFloat textY = startY + _contentAreaRect.size.height / 2 - textSize.height / 2;
        [text drawAtPoint:NSMakePoint(textX, textY) withAttributes:attrs];
        return;
    }

    NSDictionary *trackNameAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor labelColor]
    };
    NSDictionary *artistAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11],
        NSForegroundColorAttributeName: [NSColor secondaryLabelColor]
    };
    NSDictionary *timeAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10],
        NSForegroundColorAttributeName: [NSColor tertiaryLabelColor]
    };
    NSDictionary *nowPlayingAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor controlAccentColor]
    };

    CGFloat rowY = startY;
    CGFloat artPad = 4.0;
    CGFloat textGap = 8.0;

    // Pre-compute truncation style (reused for all rows)
    NSMutableParagraphStyle *truncStyle = [[NSMutableParagraphStyle alloc] init];
    truncStyle.lineBreakMode = NSLineBreakByTruncatingTail;
    NSMutableDictionary *trackAttrsWithTrunc = [trackNameAttrs mutableCopy];
    trackAttrsWithTrunc[NSParagraphStyleAttributeName] = truncStyle;
    NSMutableDictionary *artistAttrsWithTrunc = [artistAttrs mutableCopy];
    artistAttrsWithTrunc[NSParagraphStyleAttributeName] = truncStyle;

    for (NSInteger i = 0; i < (NSInteger)_recentTracks.count; i++) {
        RecentTrack *track = _recentTracks[i];
        NSRect rowRect = NSMakeRect(kPadding, rowY, width, kTrackRowHeight);

        // Store rect for hit testing (even if off-screen, index corresponds to track index)
        [_trackRowRects addObject:[NSValue valueWithRect:rowRect]];

        // Skip drawing rows that are completely outside the visible clip rect
        if (rowY + kTrackRowHeight < _contentAreaRect.origin.y ||
            rowY > _contentAreaRect.origin.y + _contentAreaRect.size.height) {
            rowY += kTrackRowHeight;
            continue;
        }

        BOOL isHoveredRow = (_hoveredTrackIndex == i);

        // Hover background
        if (isHoveredRow) {
            [[NSColor colorWithWhite:0.5 alpha:0.08] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:rowRect xRadius:4 yRadius:4] fill];
        }

        // Now-playing accent left border
        if (track.isNowPlaying) {
            NSRect accentBar = NSMakeRect(kPadding, rowY + artPad, 2, kTrackRowHeight - artPad * 2);
            [[NSColor controlAccentColor] setFill];
            [NSBezierPath fillRect:accentBar];
        }

        // Album art thumbnail
        CGFloat artX = kPadding + (track.isNowPlaying ? 6 : 0) + artPad;
        CGFloat artY = rowY + (kTrackRowHeight - kTrackArtSize) / 2;
        NSRect artRect = NSMakeRect(artX, artY, kTrackArtSize, kTrackArtSize);

        NSImage *artImage = track.imageURL ? _albumImages[track.imageURL] : nil;
        if (artImage) {
            NSBezierPath *artClip = [NSBezierPath bezierPathWithRoundedRect:artRect xRadius:4 yRadius:4];
            [NSGraphicsContext saveGraphicsState];
            [artClip addClip];
            [artImage drawInRect:artRect fromRect:NSZeroRect
                       operation:NSCompositingOperationSourceOver fraction:1.0];
            [NSGraphicsContext restoreGraphicsState];
        } else {
            [[NSColor tertiaryLabelColor] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:artRect xRadius:4 yRadius:4] fill];
        }

        // Text area
        CGFloat textX = artX + kTrackArtSize + textGap;
        CGFloat textWidth = width - (textX - kPadding);

        // Time / Now Playing badge (right-aligned)
        NSString *timeText = [track relativeTimeString];
        NSDictionary *timeDisplayAttrs = track.isNowPlaying ? nowPlayingAttrs : timeAttrs;
        NSSize timeSize = [timeText sizeWithAttributes:timeDisplayAttrs];
        CGFloat timeX = kPadding + width - timeSize.width;
        CGFloat availTextWidth = textWidth - timeSize.width - 8;

        // Track name (first line)
        CGFloat nameY = rowY + (kTrackRowHeight / 2) - 14;
        NSRect nameRect = NSMakeRect(textX, nameY, availTextWidth, 16);
        [track.name drawInRect:nameRect withAttributes:trackAttrsWithTrunc];

        // Artist name (second line)
        CGFloat artistY = nameY + 15;
        NSRect artistRect = NSMakeRect(textX, artistY, availTextWidth, 14);
        [track.artist drawInRect:artistRect withAttributes:artistAttrsWithTrunc];

        // Time text (right-aligned, vertically centered)
        CGFloat timeY = rowY + (kTrackRowHeight - timeSize.height) / 2;
        [timeText drawAtPoint:NSMakePoint(timeX, timeY) withAttributes:timeDisplayAttrs];

        // Separator line (except last row)
        rowY += kTrackRowHeight;
        if (i < (NSInteger)_recentTracks.count - 1) {
            [[NSColor separatorColor] setStroke];
            NSBezierPath *sep = [NSBezierPath bezierPath];
            [sep moveToPoint:NSMakePoint(textX, rowY)];
            [sep lineToPoint:NSMakePoint(kPadding + width, rowY)];
            sep.lineWidth = 0.5;
            [sep stroke];
        }
    }
}

- (void)drawAlbumTooltipForIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_topAlbums.count || index >= (NSInteger)_albumRects.count) {
        return;
    }

    TopAlbum *album = _topAlbums[index];
    NSRect albumRect = [_albumRects[index] rectValue];

    // Build tooltip text
    NSString *artistText = album.artist.length > 0 ? album.artist : @"Unknown Artist";
    NSString *albumText = album.name.length > 0 ? album.name : @"Unknown Album";
    // Include rank in tooltip for bubble view
    NSString *playsText;
    if (_displayStyle == ScrobbleDisplayStylePlayback2025 && album.rank > 0) {
        playsText = [NSString stringWithFormat:@"#%ld - %ld plays", (long)album.rank, (long)album.playcount];
    } else {
        playsText = [NSString stringWithFormat:@"%ld plays", (long)album.playcount];
    }

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

- (void)setDisplayStyle:(ScrobbleDisplayStyle)style animated:(BOOL)animated {
    if (_displayStyle == style) return;

    if (!animated || !self.window || _topAlbums.count == 0) {
        _displayStyle = style;
        [self setNeedsDisplay:YES];
        return;
    }

    // Capture current item rects and corner radii
    NSArray<NSValue *> *oldRects = [_albumRects copy];
    BOOL wasGrid = (_displayStyle == ScrobbleDisplayStyleDefault);
    CGFloat oldCornerRadius = wasGrid ? 4.0 : 1000.0;  // grid uses rounded rect, bubble uses circle

    // Switch to new style and redraw to get new rects (but suppress actual drawing)
    _displayStyle = style;
    _isAnimatingTransition = YES;
    [self display];  // Force synchronous draw to populate new _albumRects (items not drawn)

    NSArray<NSValue *> *newRects = [_albumRects copy];
    BOOL isGrid = (_displayStyle == ScrobbleDisplayStyleDefault);
    CGFloat newCornerRadius = isGrid ? 4.0 : 1000.0;

    NSInteger count = MIN((NSInteger)oldRects.count, (NSInteger)newRects.count);
    if (count == 0) return;

    NSTimeInterval duration = 0.4;
    CAMediaTimingFunction *timing = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];

    // Create animated layers for each item
    NSMutableArray<CALayer *> *animLayers = [NSMutableArray array];

    for (NSInteger i = 0; i < count; i++) {
        NSRect fromRect = [oldRects[i] rectValue];
        NSRect toRect = [newRects[i] rectValue];

        // Get image for this item
        NSImage *itemImage = nil;
        if (i < (NSInteger)_topAlbums.count) {
            TopAlbum *album = _topAlbums[i];
            if (album.imageURL && _albumImages) {
                itemImage = _albumImages[album.imageURL];
            }
        }

        CALayer *itemLayer = [CALayer layer];
        itemLayer.frame = fromRect;
        if (itemImage) {
            itemLayer.contents = itemImage;
            itemLayer.contentsGravity = kCAGravityResizeAspectFill;
        } else {
            itemLayer.backgroundColor = [NSColor tertiaryLabelColor].CGColor;
        }
        itemLayer.masksToBounds = YES;
        CGFloat fromRadius = MIN(oldCornerRadius, MIN(fromRect.size.width, fromRect.size.height) / 2);
        itemLayer.cornerRadius = fromRadius;

        [self.layer addSublayer:itemLayer];
        [animLayers addObject:itemLayer];

        // Animate bounds (size change)
        CABasicAnimation *boundsAnim = [CABasicAnimation animationWithKeyPath:@"bounds"];
        boundsAnim.fromValue = [NSValue valueWithRect:NSMakeRect(0, 0, fromRect.size.width, fromRect.size.height)];
        boundsAnim.toValue = [NSValue valueWithRect:NSMakeRect(0, 0, toRect.size.width, toRect.size.height)];
        boundsAnim.duration = duration;
        boundsAnim.timingFunction = timing;

        // Animate position (center point translation)
        CABasicAnimation *posAnim = [CABasicAnimation animationWithKeyPath:@"position"];
        CGPoint fromCenter = CGPointMake(NSMidX(fromRect), NSMidY(fromRect));
        CGPoint toCenter = CGPointMake(NSMidX(toRect), NSMidY(toRect));
        posAnim.fromValue = [NSValue valueWithPoint:NSPointFromCGPoint(fromCenter)];
        posAnim.toValue = [NSValue valueWithPoint:NSPointFromCGPoint(toCenter)];
        posAnim.duration = duration;
        posAnim.timingFunction = timing;

        // Animate corner radius (square-ish to circle or vice versa)
        CGFloat toRadius = MIN(newCornerRadius, MIN(toRect.size.width, toRect.size.height) / 2);
        CABasicAnimation *radiusAnim = [CABasicAnimation animationWithKeyPath:@"cornerRadius"];
        radiusAnim.fromValue = @(fromRadius);
        radiusAnim.toValue = @(toRadius);
        radiusAnim.duration = duration;
        radiusAnim.timingFunction = timing;

        // Group animations
        CAAnimationGroup *group = [CAAnimationGroup animation];
        group.animations = @[boundsAnim, posAnim, radiusAnim];
        group.duration = duration;
        group.fillMode = kCAFillModeForwards;
        group.removedOnCompletion = NO;

        [itemLayer addAnimation:group forKey:@"transition"];

        // Set final values
        itemLayer.frame = toRect;
        itemLayer.cornerRadius = toRadius;
    }

    // Remove overlay layers after animation completes
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        for (CALayer *layer in animLayers) {
            [layer removeFromSuperlayer];
        }
        self->_isAnimatingTransition = NO;
        [self setNeedsDisplay:YES];
    });
}

- (void)refreshDisplay {
    [self setNeedsDisplay:YES];
    // Force immediate redraw - foobar2000's view hierarchy may not
    // propagate setNeedsDisplay from embedded widget views.
    [self displayIfNeeded];
}

#pragma mark - Scroll Reset

- (void)setViewMode:(ScrobbleWidgetViewMode)viewMode {
    if (_viewMode != viewMode) {
        _viewMode = viewMode;
        _contentScrollOffset = 0;
    }
}

- (void)setCurrentPeriod:(ScrobbleChartPeriod)currentPeriod {
    if (_currentPeriod != currentPeriod) {
        _currentPeriod = currentPeriod;
        _contentScrollOffset = 0;
    }
}

- (void)setCurrentType:(ScrobbleChartType)currentType {
    if (_currentType != currentType) {
        _currentType = currentType;
        _contentScrollOffset = 0;
    }
}

- (void)setTopAlbums:(NSArray<TopAlbum *> *)topAlbums {
    _topAlbums = [topAlbums copy];
    _contentScrollOffset = 0;
}

- (void)setRecentTracks:(NSArray<RecentTrack *> *)recentTracks {
    _recentTracks = [recentTracks copy];
    _contentScrollOffset = 0;
}

@end
