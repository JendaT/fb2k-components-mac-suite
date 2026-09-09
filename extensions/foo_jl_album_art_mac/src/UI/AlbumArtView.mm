//
//  AlbumArtView.mm
//  foo_jl_album_art_mac
//
//  Album art view implementation with navigation arrows
//

#import "AlbumArtView.h"
#import "../Core/ArtworkResult.h"
#import "../Core/RemoteArtworkTypes.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat kArrowWidth = 40.0;
static const NSTimeInterval kArrowFadeDuration = 0.2;
static const CGFloat kFooterHeight = 80.0;  // Increased to fit type labels
static const CGFloat kThumbnailSize = 48.0;
static const CGFloat kThumbnailSpacing = 8.0;
static const CGFloat kTypeLabelHeight = 12.0;

// Footer layout, shared by the drawing and hit-testing paths
static const CGFloat kThumbnailRowTopInset = 22.0;   // Below the count label
static const CGFloat kCancelButtonTopOffset = 10.0;  // Below the message text
static const CGFloat kCancelButtonHitSlopX = 6.0;
static const CGFloat kCancelButtonHitSlopY = 4.0;

static NSString *const kCancelButtonTitle = @"Cancel";

// Text attributes are rebuilt on every draw only where the colour is
// appearance-dependent; the paragraph styles and fonts never change.
static NSParagraphStyle *CenteredParagraphStyle(void) {
    static NSParagraphStyle *style = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableParagraphStyle *mutableStyle = [[NSMutableParagraphStyle alloc] init];
        mutableStyle.alignment = NSTextAlignmentCenter;
        style = [mutableStyle copy];
    });
    return style;
}

static NSFont *CancelButtonFont(void) {
    static NSFont *font = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        font = [NSFont systemFontOfSize:10.0];
    });
    return font;
}

static NSSize CancelButtonTextSize(void) {
    static NSSize size;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        size = [kCancelButtonTitle sizeWithAttributes:@{NSFontAttributeName: CancelButtonFont()}];
    });
    return size;
}

@interface AlbumArtView ()
@property (nonatomic, assign) BOOL isHovering;
@property (nonatomic, assign) CGFloat arrowOpacity;
@property (nonatomic, strong, nullable) NSTrackingArea *trackingArea;
@property (nonatomic, assign) BOOL isOverLeftArrow;
@property (nonatomic, assign) BOOL isOverRightArrow;

// Footer state
@property (nonatomic, assign) BOOL footerVisible;
@property (nonatomic, assign) CGFloat footerAnimatedHeight;
@property (nonatomic, assign) NSInteger hoveredThumbnailIndex;

// Animated search dots
@property (nonatomic, assign) NSUInteger searchAnimationFrame;
@property (nonatomic, strong, nullable) NSTimer *searchAnimationTimer;

// Cancel button hover state
@property (nonatomic, assign) BOOL isOverCancelButton;
@end

@implementation AlbumArtView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (void)commonInit {
    self.wantsLayer = YES;
    self.layer.backgroundColor = [[NSColor clearColor] CGColor];
    _isSquare = NO;
    _isZoomable = NO;
    _arrowOpacity = 0.0;
    _canNavigatePrevious = NO;
    _canNavigateNext = NO;

    // Footer defaults
    _footerState = AlbumArtFooterStateIdle;
    _footerVisible = NO;
    _footerAnimatedHeight = 0;
    _hoveredThumbnailIndex = -1;
    _searchAnimationFrame = 0;
    _isOverCancelButton = NO;

    // Ensure the view doesn't resist being resized by the layout system
    [self setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    [self setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
}

- (void)viewWillMoveToWindow:(NSWindow *)newWindow {
    [super viewWillMoveToWindow:newWindow];

    // Stop the search animation when the panel is detached; otherwise the
    // repeating timer keeps firing (and, before the weak-timer fix, leaked
    // the view). It restarts on the next search if the view is reattached.
    if (newWindow == nil) {
        [self stopSearchAnimation];
    }
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];

    if (self.trackingArea) {
        [self removeTrackingArea:self.trackingArea];
    }

    self.trackingArea = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:(NSTrackingMouseEnteredAndExited |
                      NSTrackingMouseMoved |
                      NSTrackingActiveInKeyWindow)
               owner:self
            userInfo:nil];
    [self addTrackingArea:self.trackingArea];
}

- (BOOL)isFlipped {
    return YES;  // Use top-left origin like UIKit
}

- (NSSize)intrinsicContentSize {
    // Return no intrinsic size - this view should fill its container,
    // not influence the container's size based on image dimensions
    return NSMakeSize(NSViewNoIntrinsicMetric, NSViewNoIntrinsicMetric);
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    NSRect bounds = self.bounds;
    CGFloat footerH = self.footerAnimatedHeight;

    // Calculate artwork area (above footer)
    NSRect artworkRect = bounds;
    if (footerH > 0) {
        artworkRect.size.height -= footerH;
    }

    // Fill only the invalidated region. Filling the whole bounds here would
    // erase the (potentially very large) artwork every time only the footer
    // is invalidated - e.g. the 0.4s search-animation tick, which redraws
    // just the footer rect.
    NSColor *bgColor = [self effectiveBackgroundColor];
    [bgColor setFill];
    NSRectFill(dirtyRect);

    // Rescaling a full-resolution image with high interpolation is expensive;
    // only do it when the artwork area is actually part of the dirty region.
    if (NSIntersectsRect(dirtyRect, artworkRect)) {
        if (self.image) {
            [self drawImage:self.image inRect:artworkRect];
        } else {
            [self drawPlaceholderInRect:artworkRect];
        }

        // Draw navigation arrows if hovering and navigation is available
        if (self.isHovering && self.arrowOpacity > 0.01) {
            [self drawNavigationArrowsInRect:artworkRect];
        }
    }

    // Draw footer if visible
    if (footerH > 0) {
        NSRect footerRect = [self currentFooterRect];
        if (NSIntersectsRect(dirtyRect, footerRect)) {
            [self drawFooterInRect:footerRect];
        }
    }
}

// The footer occupies the bottom strip of the view; NSZeroRect when hidden.
// Drawing and hit-testing both derive their geometry from this rect.
- (NSRect)currentFooterRect {
    CGFloat footerH = self.footerAnimatedHeight;
    if (footerH <= 0) {
        return NSZeroRect;
    }
    return NSMakeRect(0, self.bounds.size.height - footerH, self.bounds.size.width, footerH);
}

// The artwork strips that the navigation arrows are drawn into
- (NSRect)arrowStripRectForDirection:(int)direction {
    NSRect bounds = self.bounds;
    CGFloat artworkHeight = bounds.size.height - self.footerAnimatedHeight;
    CGFloat x = (direction < 0) ? 0 : bounds.size.width - kArrowWidth;
    return NSMakeRect(x, 0, kArrowWidth, artworkHeight);
}

- (void)drawImage:(NSImage*)image inRect:(NSRect)rect {
    NSSize imageSize = image.size;
    if (imageSize.width <= 0 || imageSize.height <= 0) return;

    NSRect targetRect = rect;

    if (self.isSquare) {
        // Make the view square by using the smaller dimension
        CGFloat side = MIN(rect.size.width, rect.size.height);
        targetRect = NSMakeRect(
            (rect.size.width - side) / 2,
            (rect.size.height - side) / 2,
            side, side
        );
    }

    // Calculate scaled rect maintaining aspect ratio
    CGFloat imageAspect = imageSize.width / imageSize.height;
    CGFloat viewAspect = targetRect.size.width / targetRect.size.height;

    NSRect drawRect;
    if (imageAspect > viewAspect) {
        // Image is wider - fit to width
        CGFloat height = targetRect.size.width / imageAspect;
        drawRect = NSMakeRect(
            targetRect.origin.x,
            targetRect.origin.y + (targetRect.size.height - height) / 2,
            targetRect.size.width,
            height
        );
    } else {
        // Image is taller - fit to height
        CGFloat width = targetRect.size.height * imageAspect;
        drawRect = NSMakeRect(
            targetRect.origin.x + (targetRect.size.width - width) / 2,
            targetRect.origin.y,
            width,
            targetRect.size.height
        );
    }

    [image drawInRect:drawRect
             fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver
             fraction:1.0
       respectFlipped:YES
                hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
}

- (void)drawPlaceholderInRect:(NSRect)rect {
    // Draw "No artwork" or type name placeholder
    NSString *text = self.artworkTypeName ?: @"No Artwork";

    static NSFont *placeholderFont = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        placeholderFont = [NSFont systemFontOfSize:14.0 weight:NSFontWeightLight];
    });

    NSDictionary *attrs = @{
        NSFontAttributeName: placeholderFont,
        NSForegroundColorAttributeName: [[self effectiveForegroundColor] colorWithAlphaComponent:0.5],
        NSParagraphStyleAttributeName: CenteredParagraphStyle()
    };

    NSSize textSize = [text sizeWithAttributes:attrs];
    NSRect textRect = NSMakeRect(
        (rect.size.width - textSize.width) / 2,
        (rect.size.height - textSize.height) / 2,
        textSize.width,
        textSize.height
    );

    [text drawInRect:textRect withAttributes:attrs];
}

- (void)drawNavigationArrowsInRect:(NSRect)rect {
    CGFloat alpha = self.arrowOpacity * 0.7;

    // Left arrow
    if (self.canNavigatePrevious) {
        NSRect leftArrowRect = NSMakeRect(0, 0, kArrowWidth, rect.size.height);
        [self drawArrowInRect:leftArrowRect
                    direction:-1
                      hovered:self.isOverLeftArrow
                        alpha:alpha];
    }

    // Right arrow
    if (self.canNavigateNext) {
        NSRect rightArrowRect = NSMakeRect(rect.size.width - kArrowWidth, 0, kArrowWidth, rect.size.height);
        [self drawArrowInRect:rightArrowRect
                    direction:1
                      hovered:self.isOverRightArrow
                        alpha:alpha];
    }
}

- (void)drawArrowInRect:(NSRect)rect direction:(int)direction hovered:(BOOL)hovered alpha:(CGFloat)alpha {
    // Draw semi-transparent background
    NSColor *bgColor = [[NSColor blackColor] colorWithAlphaComponent:alpha * (hovered ? 0.6 : 0.4)];
    [bgColor setFill];

    // Create gradient for edge fade
    NSGradient *gradient;
    if (direction < 0) {
        // Left arrow - fade from left to right
        gradient = [[NSGradient alloc] initWithStartingColor:bgColor
                                                 endingColor:[bgColor colorWithAlphaComponent:0]];
    } else {
        // Right arrow - fade from right to left
        gradient = [[NSGradient alloc] initWithStartingColor:[bgColor colorWithAlphaComponent:0]
                                                 endingColor:bgColor];
    }
    [gradient drawInRect:rect angle:0];

    // Draw arrow chevron
    CGFloat arrowSize = 16.0;
    CGFloat centerX = rect.origin.x + rect.size.width / 2;
    CGFloat centerY = rect.size.height / 2;

    NSBezierPath *arrow = [NSBezierPath bezierPath];
    arrow.lineWidth = 2.5;
    arrow.lineCapStyle = NSLineCapStyleRound;
    arrow.lineJoinStyle = NSLineJoinStyleRound;

    if (direction < 0) {
        // Left arrow <
        [arrow moveToPoint:NSMakePoint(centerX + arrowSize/3, centerY - arrowSize/2)];
        [arrow lineToPoint:NSMakePoint(centerX - arrowSize/3, centerY)];
        [arrow lineToPoint:NSMakePoint(centerX + arrowSize/3, centerY + arrowSize/2)];
    } else {
        // Right arrow >
        [arrow moveToPoint:NSMakePoint(centerX - arrowSize/3, centerY - arrowSize/2)];
        [arrow lineToPoint:NSMakePoint(centerX + arrowSize/3, centerY)];
        [arrow lineToPoint:NSMakePoint(centerX - arrowSize/3, centerY + arrowSize/2)];
    }

    NSColor *arrowColor = [[NSColor whiteColor] colorWithAlphaComponent:alpha * (hovered ? 1.0 : 0.8)];
    [arrowColor setStroke];
    [arrow stroke];
}

#pragma mark - Colors

- (NSColor*)effectiveBackgroundColor {
    if (@available(macOS 10.14, *)) {
        return [NSColor controlBackgroundColor];
    }
    return [NSColor windowBackgroundColor];
}

- (NSColor*)effectiveForegroundColor {
    if (@available(macOS 10.14, *)) {
        return [NSColor labelColor];
    }
    return [NSColor textColor];
}

#pragma mark - Mouse Events

- (void)mouseEntered:(NSEvent *)event {
    self.isHovering = YES;
    [self animateArrowOpacity:1.0];
}

- (void)mouseExited:(NSEvent *)event {
    self.isHovering = NO;
    self.isOverLeftArrow = NO;
    self.isOverRightArrow = NO;
    [self animateArrowOpacity:0.0];
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];

    BOOL wasOverLeft = self.isOverLeftArrow;
    BOOL wasOverRight = self.isOverRightArrow;
    NSInteger wasHoveredThumb = self.hoveredThumbnailIndex;
    BOOL wasOverCancel = self.isOverCancelButton;

    self.isOverLeftArrow = self.canNavigatePrevious && location.x < kArrowWidth;
    self.isOverRightArrow = self.canNavigateNext && location.x > self.bounds.size.width - kArrowWidth;

    // Check for thumbnail hover
    self.hoveredThumbnailIndex = [self thumbnailIndexAtPoint:location];

    // Check for cancel button hover
    self.isOverCancelButton = (self.footerState == AlbumArtFooterStateSearching &&
                               [self isCancelButtonAtPoint:location]);

    // Invalidate only the affected region; a full-bounds invalidation would
    // re-scale the full-resolution artwork for a footer-only hover change.
    if (wasOverLeft != self.isOverLeftArrow) {
        [self setNeedsDisplayInRect:[self arrowStripRectForDirection:-1]];
    }
    if (wasOverRight != self.isOverRightArrow) {
        [self setNeedsDisplayInRect:[self arrowStripRectForDirection:1]];
    }
    if (wasHoveredThumb != self.hoveredThumbnailIndex ||
        wasOverCancel != self.isOverCancelButton) {
        NSRect footerRect = [self currentFooterRect];
        if (!NSIsEmptyRect(footerRect)) {
            [self setNeedsDisplayInRect:footerRect];
        }
    }
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];

    // Check if clicking Cancel in search footer
    if (self.footerState == AlbumArtFooterStateSearching && [self isCancelButtonAtPoint:location]) {
        if ([self.delegate respondsToSelector:@selector(albumArtViewDidRequestCancelSearch:)]) {
            [self.delegate albumArtViewDidRequestCancelSearch:self];
        }
        return;
    }

    // Check if clicking on a thumbnail in footer
    NSInteger thumbIndex = [self thumbnailIndexAtPoint:location];
    if (thumbIndex >= 0) {
        if ([self.delegate respondsToSelector:@selector(albumArtView:didSelectThumbnailAtIndex:)]) {
            [self.delegate albumArtView:self didSelectThumbnailAtIndex:thumbIndex];
        }
        return;
    }

    // Check if clicking on arrows
    if (self.isHovering) {
        if (self.canNavigatePrevious && location.x < kArrowWidth) {
            if ([self.delegate respondsToSelector:@selector(albumArtViewNavigatePrevious:)]) {
                [self.delegate albumArtViewNavigatePrevious:self];
            }
            return;
        }

        if (self.canNavigateNext && location.x > self.bounds.size.width - kArrowWidth) {
            if ([self.delegate respondsToSelector:@selector(albumArtViewNavigateNext:)]) {
                [self.delegate albumArtViewNavigateNext:self];
            }
            return;
        }
    }
}

- (void)rightMouseDown:(NSEvent *)event {
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];

    if ([self.delegate respondsToSelector:@selector(albumArtViewRequestsContextMenu:atPoint:)]) {
        [self.delegate albumArtViewRequestsContextMenu:self atPoint:location];
    }
}

#pragma mark - Animation

- (void)animateArrowOpacity:(CGFloat)targetOpacity {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = kArrowFadeDuration;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];

        // Animate opacity
        self.arrowOpacity = targetOpacity;
        [self setNeedsDisplay:YES];
    }];

    // Force redraw during animation
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kArrowFadeDuration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self setNeedsDisplay:YES];
    });
}

#pragma mark - Public Methods

- (void)refreshDisplay {
    [self setNeedsDisplay:YES];
}

- (void)setImage:(NSImage *)image {
    _image = image;
    [self setNeedsDisplay:YES];
}

- (void)setCanNavigatePrevious:(BOOL)canNavigatePrevious {
    _canNavigatePrevious = canNavigatePrevious;
    [self setNeedsDisplay:YES];
}

- (void)setCanNavigateNext:(BOOL)canNavigateNext {
    _canNavigateNext = canNavigateNext;
    [self setNeedsDisplay:YES];
}

#pragma mark - Footer Drawing

- (void)drawFooterInRect:(NSRect)rect {
    // Draw footer background
    NSColor *footerBg = [[self effectiveBackgroundColor] blendedColorWithFraction:0.05
                                                                           ofColor:[NSColor blackColor]];
    [footerBg setFill];
    NSRectFill(rect);

    // Draw top separator line
    NSColor *separatorColor = [[self effectiveForegroundColor] colorWithAlphaComponent:0.1];
    [separatorColor setFill];
    NSRectFill(NSMakeRect(rect.origin.x, rect.origin.y, rect.size.width, 1));

    switch (self.footerState) {
        case AlbumArtFooterStateSearching:
            [self drawSearchingFooterInRect:rect];
            break;

        case AlbumArtFooterStateThumbnails:
            [self drawThumbnailsFooterInRect:rect];
            break;

        case AlbumArtFooterStateError:
            [self drawErrorFooterInRect:rect];
            break;

        case AlbumArtFooterStateIdle:
        default:
            break;
    }
}

- (void)drawSearchingFooterInRect:(NSRect)rect {
    // Animated dots suffix. The message arrives without an ellipsis; the
    // trailing dots belong to this animation and are owned here.
    static NSString *const dotFrames[] = { @"", @".", @"..", @"..." };
    static const NSUInteger dotFrameCount = sizeof(dotFrames) / sizeof(dotFrames[0]);
    NSString *dots = dotFrames[self.searchAnimationFrame % dotFrameCount];

    NSString *baseMessage = self.footerMessage ?: @"Searching";
    NSString *message = [baseMessage stringByAppendingString:dots];

    static NSFont *messageFont = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        messageFont = [NSFont systemFontOfSize:11.0];
    });

    NSDictionary *attrs = @{
        NSFontAttributeName: messageFont,
        NSForegroundColorAttributeName: [[self effectiveForegroundColor] colorWithAlphaComponent:0.7],
        NSParagraphStyleAttributeName: CenteredParagraphStyle()
    };

    NSSize textSize = [message sizeWithAttributes:attrs];
    NSRect textRect = NSMakeRect(
        rect.origin.x + (rect.size.width - textSize.width) / 2,
        rect.origin.y + (rect.size.height - textSize.height) / 2 - 8,
        textSize.width,
        textSize.height
    );

    [message drawInRect:textRect withAttributes:attrs];

    // Draw "Cancel" link below the message
    NSDictionary *cancelAttrs = @{
        NSFontAttributeName: CancelButtonFont(),
        NSForegroundColorAttributeName: self.isOverCancelButton
            ? [NSColor controlAccentColor]
            : [[self effectiveForegroundColor] colorWithAlphaComponent:0.5],
        NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle),
        NSParagraphStyleAttributeName: CenteredParagraphStyle()
    };

    [kCancelButtonTitle drawInRect:[self cancelButtonRectInFooter:rect]
                    withAttributes:cancelAttrs];
}

#pragma mark - Footer Geometry

- (NSRect)cancelButtonRectInFooter:(NSRect)footerRect {
    NSSize textSize = CancelButtonTextSize();
    return NSMakeRect(
        footerRect.origin.x + (footerRect.size.width - textSize.width) / 2,
        footerRect.origin.y + (footerRect.size.height - textSize.height) / 2 + kCancelButtonTopOffset,
        textSize.width,
        textSize.height
    );
}

- (NSRect)thumbnailRectAtIndex:(NSUInteger)index inFooter:(NSRect)footerRect {
    NSUInteger count = self.footerThumbnails.count;
    if (count == 0) {
        return NSZeroRect;
    }

    CGFloat totalWidth = count * kThumbnailSize + (count - 1) * kThumbnailSpacing;
    CGFloat startX = footerRect.origin.x + (footerRect.size.width - totalWidth) / 2;

    return NSMakeRect(
        startX + index * (kThumbnailSize + kThumbnailSpacing),
        footerRect.origin.y + kThumbnailRowTopInset,
        kThumbnailSize,
        kThumbnailSize
    );
}

- (void)drawThumbnailsFooterInRect:(NSRect)rect {
    if (self.footerThumbnails.count == 0) {
        return;
    }

    // Draw count label at top of footer
    NSString *countLabel = [NSString stringWithFormat:@"%lu images found",
                            (unsigned long)self.footerThumbnails.count];

    static NSFont *countFont = nil;
    static NSFont *typeLabelFont = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        countFont = [NSFont systemFontOfSize:10.0];
        typeLabelFont = [NSFont systemFontOfSize:8.0];
    });

    NSDictionary *countAttrs = @{
        NSFontAttributeName: countFont,
        NSForegroundColorAttributeName: [[self effectiveForegroundColor] colorWithAlphaComponent:0.7]
    };

    NSSize countSize = [countLabel sizeWithAttributes:countAttrs];
    NSRect countRect = NSMakeRect(
        rect.origin.x + (rect.size.width - countSize.width) / 2,
        rect.origin.y + 6,
        countSize.width,
        countSize.height
    );
    [countLabel drawInRect:countRect withAttributes:countAttrs];

    NSDictionary *typeLabelAttrs = @{
        NSFontAttributeName: typeLabelFont,
        NSForegroundColorAttributeName: [[self effectiveForegroundColor] colorWithAlphaComponent:0.5],
        NSParagraphStyleAttributeName: CenteredParagraphStyle()
    };

    for (NSUInteger i = 0; i < self.footerThumbnails.count; i++) {
        NSImage *thumb = self.footerThumbnails[i];
        NSRect thumbRect = [self thumbnailRectAtIndex:i inFooter:rect];

        // Draw thumbnail with aspect fit
        [self drawThumbnail:thumb inRect:thumbRect hovered:(NSInteger)i == self.hoveredThumbnailIndex];

        // Draw type label below thumbnail
        if (i < self.footerResults.count) {
            ArtworkResult *result = self.footerResults[i];
            NSString *typeLabel = RemoteArtworkTypeName(result.artworkType);

            NSRect labelRect = NSMakeRect(thumbRect.origin.x - 4,
                                          NSMaxY(thumbRect) + 2,
                                          kThumbnailSize + 8,
                                          kTypeLabelHeight);
            [typeLabel drawInRect:labelRect withAttributes:typeLabelAttrs];
        }
    }
}

- (void)drawThumbnail:(NSImage *)image inRect:(NSRect)rect hovered:(BOOL)hovered {
    // Draw background
    NSColor *thumbBg = [[NSColor blackColor] colorWithAlphaComponent:0.1];
    [thumbBg setFill];
    NSRectFill(rect);

    // Draw image
    if (image) {
        NSSize imageSize = image.size;
        if (imageSize.width > 0 && imageSize.height > 0) {
            CGFloat scale = MIN(rect.size.width / imageSize.width,
                               rect.size.height / imageSize.height);
            CGFloat w = imageSize.width * scale;
            CGFloat h = imageSize.height * scale;
            NSRect drawRect = NSMakeRect(
                rect.origin.x + (rect.size.width - w) / 2,
                rect.origin.y + (rect.size.height - h) / 2,
                w, h
            );

            [image drawInRect:drawRect
                     fromRect:NSZeroRect
                    operation:NSCompositingOperationSourceOver
                     fraction:1.0
               respectFlipped:YES
                        hints:nil];
        }
    }

    // Draw hover highlight
    if (hovered) {
        NSColor *highlightColor = [[NSColor systemBlueColor] colorWithAlphaComponent:0.3];
        [highlightColor setFill];
        NSRectFillUsingOperation(rect, NSCompositingOperationSourceOver);

        // Draw border
        NSColor *borderColor = [NSColor systemBlueColor];
        [borderColor setStroke];
        NSBezierPath *border = [NSBezierPath bezierPathWithRect:NSInsetRect(rect, 0.5, 0.5)];
        border.lineWidth = 2.0;
        [border stroke];
    }
}

- (void)drawErrorFooterInRect:(NSRect)rect {
    NSString *message = self.footerMessage ?: @"Search failed";

    static NSDictionary *attrs = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:11.0],
            NSForegroundColorAttributeName: [NSColor systemRedColor],
            NSParagraphStyleAttributeName: CenteredParagraphStyle()
        };
    });

    NSSize textSize = [message sizeWithAttributes:attrs];
    NSRect textRect = NSMakeRect(
        rect.origin.x + (rect.size.width - textSize.width) / 2,
        rect.origin.y + (rect.size.height - textSize.height) / 2,
        textSize.width,
        textSize.height
    );

    [message drawInRect:textRect withAttributes:attrs];
}

#pragma mark - Footer Public Methods

- (CGFloat)footerHeight {
    return self.footerAnimatedHeight;
}

- (void)setFooterVisible:(BOOL)visible animated:(BOOL)animated {
    if (self.footerVisible == visible) {
        return;
    }

    self.footerVisible = visible;
    CGFloat targetHeight = visible ? kFooterHeight : 0;

    if (animated) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.25;
            context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            self.footerAnimatedHeight = targetHeight;
            [self setNeedsDisplay:YES];
        }];
    } else {
        self.footerAnimatedHeight = targetHeight;
        [self setNeedsDisplay:YES];
    }
}

- (void)showSearchProgress:(NSString *)message {
    self.footerState = AlbumArtFooterStateSearching;
    self.footerMessage = message;
    self.footerThumbnails = nil;
    self.footerResults = nil;
    [self setFooterVisible:YES animated:YES];
    [self startSearchAnimation];
}

- (void)showThumbnails:(NSArray<NSImage *> *)thumbnails results:(NSArray<ArtworkResult *> *)results {
    [self stopSearchAnimation];
    BOOL footerWasVisible = self.footerVisible;
    self.footerState = AlbumArtFooterStateThumbnails;
    self.footerMessage = nil;
    self.footerThumbnails = thumbnails;
    self.footerResults = results;
    self.isOverCancelButton = NO;
    [self setFooterVisible:YES animated:NO];

    // Thumbnails arrive one download at a time. Once the footer is up, only
    // the footer needs redrawing - invalidating the whole view would re-scale
    // the full-resolution artwork on every completed thumbnail.
    if (footerWasVisible) {
        [self setNeedsDisplayInRect:[self currentFooterRect]];
    } else {
        [self setNeedsDisplay:YES];
    }
}

- (void)showError:(NSString *)message {
    [self stopSearchAnimation];
    self.footerState = AlbumArtFooterStateError;
    self.footerMessage = message;
    self.footerThumbnails = nil;
    self.footerResults = nil;
    self.isOverCancelButton = NO;
    [self setFooterVisible:YES animated:NO];
    [self setNeedsDisplay:YES];
}

- (void)hideFooter {
    [self stopSearchAnimation];
    self.footerState = AlbumArtFooterStateIdle;
    self.footerMessage = nil;
    self.footerThumbnails = nil;
    self.footerResults = nil;
    self.hoveredThumbnailIndex = -1;
    self.isOverCancelButton = NO;
    [self setFooterVisible:NO animated:YES];
}

#pragma mark - Search Animation

- (void)startSearchAnimation {
    if (self.searchAnimationTimer) return;

    self.searchAnimationFrame = 0;
    // Block-based timer with a weak self so the timer does not retain the view.
    // A target-based repeating timer would keep the view (and its full-res
    // image) alive forever if the panel is torn down mid-search.
    __weak typeof(self) weakSelf = self;
    self.searchAnimationTimer = [NSTimer scheduledTimerWithTimeInterval:0.4
                                                                repeats:YES
                                                                  block:^(NSTimer *timer) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf searchAnimationTick];
        } else {
            [timer invalidate];
        }
    }];
}

- (void)stopSearchAnimation {
    [self.searchAnimationTimer invalidate];
    self.searchAnimationTimer = nil;
    self.searchAnimationFrame = 0;
}

- (void)searchAnimationTick {
    self.searchAnimationFrame++;
    if (self.footerState == AlbumArtFooterStateSearching) {
        // Only redraw the footer region
        [self setNeedsDisplayInRect:[self currentFooterRect]];
    } else {
        [self stopSearchAnimation];
    }
}

#pragma mark - Cancel Button Hit Test

- (BOOL)isCancelButtonAtPoint:(NSPoint)point {
    NSRect footerRect = [self currentFooterRect];
    if (NSIsEmptyRect(footerRect) || point.y < footerRect.origin.y) {
        return NO;
    }

    // Same rect the link is drawn into, widened slightly for easier clicking
    NSRect cancelHitRect = NSInsetRect([self cancelButtonRectInFooter:footerRect],
                                       -kCancelButtonHitSlopX,
                                       -kCancelButtonHitSlopY);

    return NSPointInRect(point, cancelHitRect);
}

#pragma mark - Footer Mouse Handling

- (NSInteger)thumbnailIndexAtPoint:(NSPoint)point {
    if (self.footerState != AlbumArtFooterStateThumbnails || self.footerThumbnails.count == 0) {
        return -1;
    }

    NSRect footerRect = [self currentFooterRect];
    if (NSIsEmptyRect(footerRect) || point.y < footerRect.origin.y) {
        return -1;
    }

    for (NSUInteger i = 0; i < self.footerThumbnails.count; i++) {
        if (NSPointInRect(point, [self thumbnailRectAtIndex:i inFooter:footerRect])) {
            return (NSInteger)i;
        }
    }

    return -1;
}

@end
