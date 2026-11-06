//
//  LightboxWindowController.mm
//  foo_jl_biography_mac
//
//  Full-screen lightbox for viewing artist images
//

#import "LightboxWindowController.h"
#import "../Core/ArtistImage.h"
#import "../Core/ArtistImageCache.h"
#import <Carbon/Carbon.h>  // QUAL-4: For named key codes (kVK_*)

// UI Constants
static const CGFloat kBackgroundAlpha = 0.85;
static const CGFloat kArrowSize = 40.0;
static const CGFloat kArrowPadding = 20.0;
static const CGFloat kCounterFontSize = 14.0;
static const CGFloat kCounterPadding = 16.0;

#pragma mark - LightboxView

@interface LightboxView : NSView

@property (nonatomic, strong, nullable) NSImage *image;
@property (nonatomic, assign) BOOL isLoading;
@property (nonatomic, assign) BOOL showLeftArrow;
@property (nonatomic, assign) BOOL showRightArrow;
@property (nonatomic, copy, nullable) NSString *counterText;

@property (nonatomic, copy, nullable) void (^onLeftClick)(void);
@property (nonatomic, copy, nullable) void (^onRightClick)(void);
@property (nonatomic, copy, nullable) void (^onBackgroundClick)(void);

@end

@implementation LightboxView {
    NSRect _leftArrowRect;
    NSRect _rightArrowRect;
    NSRect _imageRect;
    BOOL _isHoveringLeft;
    BOOL _isHoveringRight;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        NSTrackingArea *trackingArea = [[NSTrackingArea alloc]
                                        initWithRect:self.bounds
                                        options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                        owner:self
                                        userInfo:nil];
        [self addTrackingArea:trackingArea];
    }
    return self;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

// QUAL-12: Accessibility
- (BOOL)isAccessibilityElement {
    return YES;
}

- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilityGroupRole;
}

- (NSString *)accessibilityLabel {
    return [NSString stringWithFormat:@"Lightbox image viewer. %@", self.counterText ?: @""];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    NSRect bounds = self.bounds;

    // Dark background
    [[NSColor colorWithWhite:0.0 alpha:kBackgroundAlpha] setFill];
    NSRectFill(bounds);

    // Calculate image rect (centered, aspect-fit)
    CGFloat maxImageWidth = bounds.size.width - (kArrowSize + kArrowPadding) * 2 - 40;
    CGFloat maxImageHeight = bounds.size.height - 80;

    if (self.image) {
        NSSize imageSize = self.image.size;
        CGFloat scale = MIN(maxImageWidth / imageSize.width, maxImageHeight / imageSize.height);
        scale = MIN(scale, 1.0);  // Don't upscale

        CGFloat drawWidth = imageSize.width * scale;
        CGFloat drawHeight = imageSize.height * scale;

        _imageRect = NSMakeRect((bounds.size.width - drawWidth) / 2,
                                (bounds.size.height - drawHeight) / 2,
                                drawWidth, drawHeight);

        [self.image drawInRect:_imageRect
                      fromRect:NSZeroRect
                     operation:NSCompositingOperationSourceOver
                      fraction:1.0];
    } else if (self.isLoading) {
        // Loading indicator
        NSString *loadingText = @"Loading...";
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:16],
            NSForegroundColorAttributeName: [NSColor secondaryLabelColor]
        };
        NSSize textSize = [loadingText sizeWithAttributes:attrs];
        NSPoint textPoint = NSMakePoint((bounds.size.width - textSize.width) / 2,
                                        (bounds.size.height - textSize.height) / 2);
        [loadingText drawAtPoint:textPoint withAttributes:attrs];
    }

    // Arrow areas
    _leftArrowRect = NSMakeRect(kArrowPadding,
                                (bounds.size.height - kArrowSize) / 2,
                                kArrowSize, kArrowSize);
    _rightArrowRect = NSMakeRect(bounds.size.width - kArrowSize - kArrowPadding,
                                 (bounds.size.height - kArrowSize) / 2,
                                 kArrowSize, kArrowSize);

    // Draw arrows
    if (self.showLeftArrow) {
        [self drawArrowInRect:_leftArrowRect pointingLeft:YES hovered:_isHoveringLeft];
    }
    if (self.showRightArrow) {
        [self drawArrowInRect:_rightArrowRect pointingLeft:NO hovered:_isHoveringRight];
    }

    // Counter text (e.g., "3 / 12")
    if (self.counterText.length > 0) {
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:kCounterFontSize weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: [NSColor colorWithWhite:1.0 alpha:0.7]
        };
        NSSize textSize = [self.counterText sizeWithAttributes:attrs];
        NSPoint textPoint = NSMakePoint((bounds.size.width - textSize.width) / 2,
                                        kCounterPadding);
        [self.counterText drawAtPoint:textPoint withAttributes:attrs];
    }
}

- (void)drawArrowInRect:(NSRect)rect pointingLeft:(BOOL)left hovered:(BOOL)hovered {
    // Background circle
    NSColor *bgColor = hovered ? [NSColor colorWithWhite:1.0 alpha:0.3] : [NSColor colorWithWhite:1.0 alpha:0.15];
    [bgColor setFill];
    [[NSBezierPath bezierPathWithOvalInRect:rect] fill];

    // Arrow
    NSBezierPath *arrow = [NSBezierPath bezierPath];
    CGFloat centerX = NSMidX(rect);
    CGFloat centerY = NSMidY(rect);
    CGFloat arrowW = 10;
    CGFloat arrowH = 16;

    if (left) {
        [arrow moveToPoint:NSMakePoint(centerX + arrowW/2, centerY - arrowH/2)];
        [arrow lineToPoint:NSMakePoint(centerX - arrowW/2, centerY)];
        [arrow lineToPoint:NSMakePoint(centerX + arrowW/2, centerY + arrowH/2)];
    } else {
        [arrow moveToPoint:NSMakePoint(centerX - arrowW/2, centerY - arrowH/2)];
        [arrow lineToPoint:NSMakePoint(centerX + arrowW/2, centerY)];
        [arrow lineToPoint:NSMakePoint(centerX - arrowW/2, centerY + arrowH/2)];
    }

    arrow.lineWidth = 2.5;
    arrow.lineCapStyle = NSLineCapStyleRound;
    arrow.lineJoinStyle = NSLineJoinStyleRound;
    [[NSColor whiteColor] setStroke];
    [arrow stroke];
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];

    BOOL wasHoveringLeft = _isHoveringLeft;
    BOOL wasHoveringRight = _isHoveringRight;

    _isHoveringLeft = self.showLeftArrow && NSPointInRect(location, _leftArrowRect);
    _isHoveringRight = self.showRightArrow && NSPointInRect(location, _rightArrowRect);

    if (_isHoveringLeft != wasHoveringLeft || _isHoveringRight != wasHoveringRight) {
        [self setNeedsDisplay:YES];
    }
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];
    NSLog(@"[Lightbox] mouseDown at (%.0f, %.0f), imageRect: (%.0f,%.0f,%.0f,%.0f)",
          location.x, location.y,
          _imageRect.origin.x, _imageRect.origin.y,
          _imageRect.size.width, _imageRect.size.height);

    if (self.showLeftArrow && NSPointInRect(location, _leftArrowRect)) {
        NSLog(@"[Lightbox] Left arrow clicked");
        if (self.onLeftClick) self.onLeftClick();
    } else if (self.showRightArrow && NSPointInRect(location, _rightArrowRect)) {
        NSLog(@"[Lightbox] Right arrow clicked");
        if (self.onRightClick) self.onRightClick();
    } else if (!NSPointInRect(location, _imageRect)) {
        NSLog(@"[Lightbox] Background clicked - closing");
        if (self.onBackgroundClick) self.onBackgroundClick();
    } else {
        NSLog(@"[Lightbox] Image clicked - no action");
    }
}

- (void)keyDown:(NSEvent *)event {
    // QUAL-4: Use named key constants from Carbon/Events.h
    switch (event.keyCode) {
        case kVK_LeftArrow:
            if (self.showLeftArrow && self.onLeftClick) self.onLeftClick();
            break;
        case kVK_RightArrow:
            if (self.showRightArrow && self.onRightClick) self.onRightClick();
            break;
        case kVK_Escape:
            if (self.onBackgroundClick) self.onBackgroundClick();
            break;
        default:
            [super keyDown:event];
            break;
    }
}

@end

#pragma mark - LightboxWindowController

@interface LightboxWindowController ()

@property (nonatomic, copy) NSArray<ArtistImage *> *images;
@property (nonatomic, assign, readwrite) NSUInteger currentIndex;
@property (nonatomic, strong) LightboxView *lightboxView;
@property (nonatomic, strong, nullable) NSImage *currentImage;

@end

@implementation LightboxWindowController

- (instancetype)initWithImages:(NSArray<ArtistImage *> *)images
                  initialIndex:(NSUInteger)index {
    // QUAL-8: Create with zero rect and defer, will be sized in showRelativeToWindow:
    // SEC-12: Use NSNormalWindowLevel instead of NSFloatingWindowLevel
    NSWindow *window = [[NSPanel alloc] initWithContentRect:NSZeroRect
                                                  styleMask:NSWindowStyleMaskBorderless
                                                    backing:NSBackingStoreBuffered
                                                      defer:YES];
    window.level = NSNormalWindowLevel;
    window.backgroundColor = [NSColor clearColor];
    window.opaque = NO;
    window.hasShadow = NO;
    window.releasedWhenClosed = NO;
    window.collectionBehavior = NSWindowCollectionBehaviorTransient;

    self = [super initWithWindow:window];
    if (self) {
        _images = [images copy];
        _currentIndex = MIN(index, images.count > 0 ? images.count - 1 : 0);

        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    self.lightboxView = [[LightboxView alloc] initWithFrame:self.window.contentView.bounds];
    self.lightboxView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.window.contentView addSubview:self.lightboxView];

    __weak typeof(self) weakSelf = self;

    self.lightboxView.onLeftClick = ^{
        [weakSelf showPreviousImage];
    };

    self.lightboxView.onRightClick = ^{
        [weakSelf showNextImage];
    };

    self.lightboxView.onBackgroundClick = ^{
        [weakSelf closeLightbox];
    };

    [self updateDisplay];
    [self loadCurrentImage];
    [self preloadAdjacentImages];
}

- (NSUInteger)imageCount {
    return self.images.count;
}

#pragma mark - Navigation

- (void)showPreviousImage {
    if (self.currentIndex > 0) {
        self.currentIndex--;
        [self updateDisplay];
        [self loadCurrentImage];
        [self preloadAdjacentImages];
    }
}

- (void)showNextImage {
    if (self.currentIndex < self.images.count - 1) {
        self.currentIndex++;
        [self updateDisplay];
        [self loadCurrentImage];
        [self preloadAdjacentImages];
    }
}

- (void)closeLightbox {
    // Clear callbacks first to prevent re-entry
    self.lightboxView.onLeftClick = nil;
    self.lightboxView.onRightClick = nil;
    self.lightboxView.onBackgroundClick = nil;

    [self.window orderOut:self];

    // QUAL-5: Notify owner so they can release us
    if (self.onDismiss) {
        self.onDismiss();
        self.onDismiss = nil;
    }
}

#pragma mark - Display

- (void)updateDisplay {
    self.lightboxView.showLeftArrow = (self.currentIndex > 0);
    self.lightboxView.showRightArrow = (self.currentIndex < self.images.count - 1);
    self.lightboxView.counterText = [NSString stringWithFormat:@"%lu / %lu",
                                     (unsigned long)(self.currentIndex + 1),
                                     (unsigned long)self.images.count];
    [self.lightboxView setNeedsDisplay:YES];
}

- (void)loadCurrentImage {
    if (self.currentIndex >= self.images.count) return;

    ArtistImage *artistImage = self.images[self.currentIndex];
    NSURL *url = artistImage.url;  // Full size for lightbox

    // Check cache first
    NSImage *cached = [[ArtistImageCache shared] cachedImageForURL:url size:ArtistImageCacheSizeFull];
    if (cached) {
        self.lightboxView.image = cached;
        self.lightboxView.isLoading = NO;
        [self.lightboxView setNeedsDisplay:YES];
        return;
    }

    // Show loading state
    self.lightboxView.image = nil;
    self.lightboxView.isLoading = YES;
    [self.lightboxView setNeedsDisplay:YES];

    // Load async
    NSUInteger loadingIndex = self.currentIndex;
    __weak typeof(self) weakSelf = self;

    [[ArtistImageCache shared] loadImageFromURL:url
                                           size:ArtistImageCacheSizeFull
                                     completion:^(NSImage *image) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        // Only update if still showing this index
        if (strongSelf.currentIndex == loadingIndex) {
            strongSelf.lightboxView.image = image;
            strongSelf.lightboxView.isLoading = NO;
            [strongSelf.lightboxView setNeedsDisplay:YES];
        }
    }];
}

- (void)preloadAdjacentImages {
    // Preload 1 image in each direction
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];

    if (self.currentIndex > 0) {
        ArtistImage *prev = self.images[self.currentIndex - 1];
        [urls addObject:prev.url];
    }

    if (self.currentIndex < self.images.count - 1) {
        ArtistImage *next = self.images[self.currentIndex + 1];
        [urls addObject:next.url];
    }

    [[ArtistImageCache shared] prefetchImages:urls size:ArtistImageCacheSizeFull];
}

#pragma mark - Show

- (void)showRelativeToWindow:(NSWindow *)parentWindow {
    // QUAL-8: Use parent window's screen frame, not mainScreen
    NSRect frame;
    if (parentWindow) {
        NSScreen *parentScreen = parentWindow.screen ?: [NSScreen mainScreen];
        frame = parentScreen.frame;
        // SEC-12: Attach as child window instead of floating
        [parentWindow addChildWindow:self.window ordered:NSWindowAbove];
    } else {
        frame = [[NSScreen mainScreen] frame];
    }

    [self.window setFrame:frame display:YES];
    [self.window makeKeyAndOrderFront:nil];
    [self.lightboxView.window makeFirstResponder:self.lightboxView];
}

@end
