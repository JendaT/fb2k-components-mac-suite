//
//  ArtistGalleryView.mm
//  foo_jl_biography_mac
//
//  Horizontal scrolling gallery view for artist images
//

#import "ArtistGalleryView.h"
#import "../Core/ArtistImage.h"
#import "../Core/ArtistImageCache.h"
#import <QuartzCore/QuartzCore.h>

// Layout constants
static const CGFloat kGalleryHeight = 120.0;
static const CGFloat kThumbnailWidth = 120.0;
static const CGFloat kThumbnailHeight = 100.0;
static const CGFloat kThumbnailSpacing = 8.0;
static const CGFloat kPadding = 12.0;
static const NSUInteger kSkeletonCount = 3;

#pragma mark - Gallery Item View

@interface ArtistGalleryItemView : NSView

@property (nonatomic, strong, nullable) NSImage *image;
@property (nonatomic, assign) BOOL isLoading;
@property (nonatomic, assign) NSUInteger index;
@property (nonatomic, copy, nullable) void (^onTap)(NSUInteger index);

@end

@implementation ArtistGalleryItemView {
    CAGradientLayer *_shimmerLayer;
    BOOL _isHovered;
    NSPoint _mouseDownLocation;
    BOOL _isTracking;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 6.0;
        self.layer.masksToBounds = YES;
        self.layer.backgroundColor = [[NSColor quaternaryLabelColor] CGColor];

        // QUAL-12: Accessibility
        [self setAccessibilityRole:NSAccessibilityButtonRole];
        [self setAccessibilityLabel:@"Artist image"];

        // Tracking area for hover
        NSTrackingArea *trackingArea = [[NSTrackingArea alloc]
                                        initWithRect:self.bounds
                                        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                        owner:self
                                        userInfo:nil];
        [self addTrackingArea:trackingArea];
    }
    return self;
}

- (void)setImage:(NSImage *)image {
    _image = image;
    [self setNeedsDisplay:YES];

    if (image) {
        [self stopShimmer];
    }
}

- (void)setIsLoading:(BOOL)isLoading {
    _isLoading = isLoading;
    if (isLoading) {
        [self startShimmer];
    } else {
        [self stopShimmer];
    }
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    NSRect bounds = self.bounds;

    if (self.image) {
        // Draw image with aspect fill
        [self drawImage:self.image inRect:bounds];

        // Hover overlay
        if (_isHovered) {
            [[NSColor colorWithWhite:1.0 alpha:0.1] setFill];
            NSRectFillUsingOperation(bounds, NSCompositingOperationSourceOver);
        }
    } else if (!self.isLoading) {
        // Empty placeholder
        [[NSColor tertiaryLabelColor] setFill];
        NSRectFill(bounds);

        // Draw icon
        NSImage *icon = [NSImage imageWithSystemSymbolName:@"photo" accessibilityDescription:nil];
        if (icon) {
            NSRect iconRect = NSMakeRect((bounds.size.width - 24) / 2,
                                         (bounds.size.height - 24) / 2,
                                         24, 24);
            [icon drawInRect:iconRect];
        }
    }
}

- (void)drawImage:(NSImage *)image inRect:(NSRect)rect {
    NSSize imageSize = image.size;
    if (imageSize.width == 0 || imageSize.height == 0) return;

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
             fraction:1.0];
}

- (void)startShimmer {
    if (_shimmerLayer) return;

    _shimmerLayer = [CAGradientLayer layer];
    _shimmerLayer.frame = self.layer.bounds;
    _shimmerLayer.colors = @[
        (__bridge id)[[NSColor colorWithWhite:0.5 alpha:0.1] CGColor],
        (__bridge id)[[NSColor colorWithWhite:0.5 alpha:0.3] CGColor],
        (__bridge id)[[NSColor colorWithWhite:0.5 alpha:0.1] CGColor]
    ];
    _shimmerLayer.locations = @[@0.0, @0.5, @1.0];
    _shimmerLayer.startPoint = CGPointMake(0, 0.5);
    _shimmerLayer.endPoint = CGPointMake(1, 0.5);
    [self.layer addSublayer:_shimmerLayer];

    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"locations"];
    animation.fromValue = @[@(-1.0), @(-0.5), @0.0];
    animation.toValue   = @[@1.0, @1.5, @2.0];
    animation.duration = 1.5;
    animation.repeatCount = HUGE_VALF;
    [_shimmerLayer addAnimation:animation forKey:@"shimmer"];
}

- (void)stopShimmer {
    [_shimmerLayer removeFromSuperlayer];
    _shimmerLayer = nil;
}

- (void)mouseEntered:(NSEvent *)event {
    _isHovered = YES;
    [self setNeedsDisplay:YES];
}

- (void)mouseExited:(NSEvent *)event {
    _isHovered = NO;
    [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)event {
    _mouseDownLocation = [self convertPoint:event.locationInWindow fromView:nil];
    _isTracking = YES;
    // Don't consume the event - let it propagate for potential drag operations
    [super mouseDown:event];
}

- (void)mouseUp:(NSEvent *)event {
    if (_isTracking) {
        NSPoint mouseUpLocation = [self convertPoint:event.locationInWindow fromView:nil];
        CGFloat dx = mouseUpLocation.x - _mouseDownLocation.x;
        CGFloat dy = mouseUpLocation.y - _mouseDownLocation.y;
        CGFloat distance = sqrt(dx * dx + dy * dy);

        // Only trigger tap if mouse didn't move much (click, not drag)
        if (distance < 5.0) {
            NSLog(@"[Gallery/ItemView] click on item %lu", (unsigned long)self.index);
            if (self.onTap) {
                self.onTap(self.index);
            }
        }
        _isTracking = NO;
    }
    [super mouseUp:event];
}

@end

#pragma mark - ArtistGalleryView

@interface ArtistGalleryView ()

@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSView *galleryContentView;
@property (nonatomic, strong) NSMutableArray<ArtistGalleryItemView *> *itemViews;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSImage *> *loadedImages;

@end

@implementation ArtistGalleryView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _itemViews = [NSMutableArray array];
        _loadedImages = [NSMutableDictionary dictionary];

        [self setupScrollView];
    }
    return self;
}

- (void)setupScrollView {
    // Scroll view
    self.scrollView = [[NSScrollView alloc] initWithFrame:self.bounds];
    self.scrollView.hasHorizontalScroller = NO;
    self.scrollView.hasVerticalScroller = NO;
    self.scrollView.horizontalScrollElasticity = NSScrollElasticityAllowed;
    self.scrollView.verticalScrollElasticity = NSScrollElasticityNone;
    self.scrollView.drawsBackground = NO;
    self.scrollView.backgroundColor = [NSColor clearColor];
    self.scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    // Content view
    self.galleryContentView = [[NSView alloc] initWithFrame:NSZeroRect];
    self.scrollView.documentView = self.galleryContentView;

    [self addSubview:self.scrollView];
}

#pragma mark - Properties

- (CGFloat)galleryHeight {
    if (self.isLoading) {
        return kGalleryHeight;
    }
    return (self.images.count > 0) ? kGalleryHeight : 0;
}

- (void)setImages:(NSArray<ArtistImage *> *)images {
    _images = [images copy];
    _isLoading = NO;
    [self.loadedImages removeAllObjects];
    [self rebuildItemViews];
    [self loadVisibleImages];
}

- (void)setIsLoading:(BOOL)isLoading {
    _isLoading = isLoading;
    if (isLoading) {
        [self showSkeletons];
    } else {
        [self rebuildItemViews];
    }
}

#pragma mark - Layout

- (void)layout {
    [super layout];

    self.scrollView.frame = self.bounds;
    [self layoutItemViews];
}

- (void)layoutItemViews {
    CGFloat x = kPadding;
    CGFloat y = (self.bounds.size.height - kThumbnailHeight) / 2;

    for (ArtistGalleryItemView *itemView in self.itemViews) {
        itemView.frame = NSMakeRect(x, y, kThumbnailWidth, kThumbnailHeight);
        x += kThumbnailWidth + kThumbnailSpacing;
    }

    // Update content size
    CGFloat contentWidth = x - kThumbnailSpacing + kPadding;
    self.galleryContentView.frame = NSMakeRect(0, 0, MAX(contentWidth, self.bounds.size.width), self.bounds.size.height);
}

#pragma mark - Item Views

- (void)rebuildItemViews {
    // Remove old views
    for (ArtistGalleryItemView *itemView in self.itemViews) {
        [itemView removeFromSuperview];
    }
    [self.itemViews removeAllObjects];

    // Weak reference for callbacks
    __weak typeof(self) weakSelf = self;

    // Create new views
    for (NSUInteger i = 0; i < self.images.count; i++) {
        ArtistGalleryItemView *itemView = [[ArtistGalleryItemView alloc] initWithFrame:NSZeroRect];
        itemView.index = i;
        itemView.isLoading = NO;

        // Set tap handler
        itemView.onTap = ^(NSUInteger index) {
            typeof(self) strongSelf = weakSelf;
            if (strongSelf) {
                NSLog(@"[Gallery/View] onTap callback for index %lu", (unsigned long)index);
                if ([strongSelf.delegate respondsToSelector:@selector(galleryView:didSelectImageAtIndex:)]) {
                    [strongSelf.delegate galleryView:strongSelf didSelectImageAtIndex:index];
                }
            }
        };

        // Check if we have a cached image
        NSImage *cached = self.loadedImages[@(i)];
        if (cached) {
            itemView.image = cached;
        }

        [self.galleryContentView addSubview:itemView];
        [self.itemViews addObject:itemView];
    }

    [self layoutItemViews];
    [self setNeedsDisplay:YES];
}

- (void)showSkeletons {
    // Remove old views
    for (ArtistGalleryItemView *itemView in self.itemViews) {
        [itemView removeFromSuperview];
    }
    [self.itemViews removeAllObjects];

    // Create skeleton views
    for (NSUInteger i = 0; i < kSkeletonCount; i++) {
        ArtistGalleryItemView *itemView = [[ArtistGalleryItemView alloc] initWithFrame:NSZeroRect];
        itemView.index = i;
        itemView.isLoading = YES;

        [self.galleryContentView addSubview:itemView];
        [self.itemViews addObject:itemView];
    }

    [self layoutItemViews];
}

#pragma mark - Image Loading

- (void)loadVisibleImages {
    if (!self.images || self.images.count == 0) return;

    // PERF-13: Only load visible images + 2 ahead
    NSRect visibleRect = self.scrollView.documentVisibleRect;
    NSUInteger prefetchAhead = 2;

    for (NSUInteger i = 0; i < self.images.count; i++) {
        // Skip if already loaded
        if (self.loadedImages[@(i)]) continue;

        // Check if this item's frame intersects visible rect (plus prefetch buffer)
        if (i < self.itemViews.count) {
            NSRect itemFrame = self.itemViews[i].frame;
            NSRect expandedVisible = NSInsetRect(visibleRect,
                                                  -(CGFloat)(prefetchAhead * (kThumbnailWidth + kThumbnailSpacing)), 0);
            if (!NSIntersectsRect(itemFrame, expandedVisible)) continue;
        }

        ArtistImage *artistImage = self.images[i];
        NSURL *url = [artistImage bestThumbnailURL];

        __weak typeof(self) weakSelf = self;
        NSUInteger index = i;

        [[ArtistImageCache shared] loadImageFromURL:url
                                               size:ArtistImageCacheSizeThumbnail
                                         completion:^(NSImage *image) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;

            if (image) {
                [strongSelf updateImageAtIndex:index withImage:image];
            }
        }];
    }
}

- (void)updateImageAtIndex:(NSUInteger)index withImage:(NSImage *)image {
    if (index >= self.itemViews.count) return;

    self.loadedImages[@(index)] = image;

    ArtistGalleryItemView *itemView = self.itemViews[index];
    itemView.image = image;
    itemView.isLoading = NO;
}

#pragma mark - Scrolling

- (void)scrollToIndex:(NSUInteger)index animated:(BOOL)animated {
    if (index >= self.itemViews.count) return;

    ArtistGalleryItemView *itemView = self.itemViews[index];
    NSRect visibleRect = itemView.frame;

    if (animated) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.3;
            [self.galleryContentView scrollRectToVisible:visibleRect];
        }];
    } else {
        [self.galleryContentView scrollRectToVisible:visibleRect];
    }
}

#pragma mark - Clear

- (void)clear {
    _images = nil;
    _isLoading = NO;
    [self.loadedImages removeAllObjects];

    for (ArtistGalleryItemView *itemView in self.itemViews) {
        [itemView removeFromSuperview];
    }
    [self.itemViews removeAllObjects];

    [self setNeedsDisplay:YES];
}

@end
