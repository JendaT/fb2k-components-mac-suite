//
//  AlbumArtView.mm
//  foo_jl_album_art_mac
//
//  Album art view implementation with navigation arrows
//

#import "AlbumArtView.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat kArrowWidth = 40.0;
static const NSTimeInterval kArrowFadeDuration = 0.2;

@interface AlbumArtView ()
@property (nonatomic, assign) BOOL isHovering;
@property (nonatomic, assign) CGFloat arrowOpacity;
@property (nonatomic, strong, nullable) NSTrackingArea *trackingArea;
@property (nonatomic, assign) BOOL isOverLeftArrow;
@property (nonatomic, assign) BOOL isOverRightArrow;
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

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    NSRect bounds = self.bounds;

    // Draw background
    NSColor *bgColor = [self effectiveBackgroundColor];
    [bgColor setFill];
    NSRectFill(bounds);

    if (self.image) {
        [self drawImage:self.image inRect:bounds];
    } else {
        [self drawPlaceholderInRect:bounds];
    }

    // Draw navigation arrows if hovering and navigation is available
    if (self.isHovering && self.arrowOpacity > 0.01) {
        [self drawNavigationArrowsInRect:bounds];
    }
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

    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.alignment = NSTextAlignmentCenter;

    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:14.0 weight:NSFontWeightLight],
        NSForegroundColorAttributeName: [[self effectiveForegroundColor] colorWithAlphaComponent:0.5],
        NSParagraphStyleAttributeName: style
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

    self.isOverLeftArrow = self.canNavigatePrevious && location.x < kArrowWidth;
    self.isOverRightArrow = self.canNavigateNext && location.x > self.bounds.size.width - kArrowWidth;

    if (wasOverLeft != self.isOverLeftArrow || wasOverRight != self.isOverRightArrow) {
        [self setNeedsDisplay:YES];
    }
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];

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

@end
