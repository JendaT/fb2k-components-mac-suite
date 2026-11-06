//
//  BiographyContentView.mm
//  foo_jl_biography_mac
//
//  Main content view displaying biography
//

#import "BiographyContentView.h"
#import "../Core/BiographyData.h"
#import "../Core/ArtistImage.h"
#import "ArtistGalleryView.h"
#import <QuartzCore/QuartzCore.h>

@interface BiographyContentView () <NSTextViewDelegate, ArtistGalleryViewDelegate>

// Artist image gallery (at top)
@property (nonatomic, strong, readwrite) ArtistGalleryView *galleryView;

// Main text view for scrollable biography content
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSTextView *textView;

// Fixed bottom bar
@property (nonatomic, strong) NSView *bottomBar;
@property (nonatomic, strong) NSTextField *sourceLabel;
@property (nonatomic, strong) NSScrollView *tagsScrollView;
@property (nonatomic, strong) NSStackView *tagsStack;

@end

@implementation BiographyContentView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    [self setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    // 1. Create bottom bar FIRST (will be at bottom)
    [self createBottomBar];

    // 2. Create gallery view (at top)
    [self createGalleryView];

    // 3. Create scroll view with text view
    [self createScrollView];

}

- (void)createGalleryView {
    self.galleryView = [[ArtistGalleryView alloc] initWithFrame:NSZeroRect];
    self.galleryView.delegate = self;
    self.galleryView.hidden = YES;  // Hidden until images are loaded
    [self addSubview:self.galleryView];
}

- (void)createBottomBar {
    self.bottomBar = [[NSView alloc] initWithFrame:NSZeroRect];

    self.sourceLabel = [NSTextField labelWithString:@""];
    self.sourceLabel.font = [NSFont systemFontOfSize:10];
    self.sourceLabel.textColor = [NSColor tertiaryLabelColor];
    self.sourceLabel.hidden = YES;

    // Tags stack inside a horizontal scroll view
    self.tagsStack = [[NSStackView alloc] init];
    self.tagsStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    self.tagsStack.spacing = 6;

    self.tagsScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.tagsScrollView.documentView = self.tagsStack;
    self.tagsScrollView.hasHorizontalScroller = NO;  // Hide scroller but allow scrolling
    self.tagsScrollView.hasVerticalScroller = NO;
    self.tagsScrollView.horizontalScrollElasticity = NSScrollElasticityAllowed;
    self.tagsScrollView.drawsBackground = NO;
    self.tagsScrollView.backgroundColor = [NSColor clearColor];
    self.tagsScrollView.hidden = YES;

    [self.bottomBar addSubview:self.sourceLabel];
    [self.bottomBar addSubview:self.tagsScrollView];
    [self addSubview:self.bottomBar];
}

- (void)createScrollView {
    // Create text view
    self.textView = [[NSTextView alloc] initWithFrame:NSZeroRect];
    self.textView.editable = NO;
    self.textView.selectable = YES;
    self.textView.backgroundColor = [NSColor clearColor];
    self.textView.drawsBackground = NO;
    self.textView.textColor = [NSColor secondaryLabelColor];
    self.textView.font = [NSFont systemFontOfSize:13];
    self.textView.textContainerInset = NSMakeSize(12, 12);
    self.textView.autoresizingMask = NSViewWidthSizable;
    [self.textView.textContainer setWidthTracksTextView:YES];
    [self.textView.textContainer setContainerSize:NSMakeSize(FLT_MAX, FLT_MAX)];
    self.textView.horizontallyResizable = NO;
    self.textView.verticallyResizable = YES;

    // Create scroll view
    self.scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.scrollView.documentView = self.textView;
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.hasHorizontalScroller = NO;
    self.scrollView.autohidesScrollers = YES;
    self.scrollView.drawsBackground = NO;
    self.scrollView.backgroundColor = [NSColor clearColor];

    [self addSubview:self.scrollView];
}

#pragma mark - Layout

- (void)layout {
    [super layout];

    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat bottomH = [self bottomBarHeight];

    // Bottom bar at very bottom (y=0 in non-flipped)
    self.bottomBar.frame = NSMakeRect(0, 0, w, bottomH);
    [self layoutBottomBar];

    // Gallery at top (if visible)
    CGFloat galleryH = self.galleryView.hidden ? 0 : self.galleryView.galleryHeight;
    CGFloat galleryY = h - galleryH;
    self.galleryView.frame = NSMakeRect(0, galleryY, w, galleryH);

    // Scroll view between gallery and bottom bar
    CGFloat scrollH = h - bottomH - galleryH;
    self.scrollView.frame = NSMakeRect(0, bottomH, w, scrollH);

    // Update text view width
    NSSize containerSize = self.textView.textContainer.containerSize;
    containerSize.width = w - 24; // Account for insets
    self.textView.textContainer.containerSize = containerSize;
    [self.textView.layoutManager ensureLayoutForTextContainer:self.textView.textContainer];
    [self.textView sizeToFit];
}

- (CGFloat)bottomBarHeight {
    CGFloat h = 8; // top padding
    if (!self.sourceLabel.hidden) {
        h += 14 + 4;
    }
    if (!self.tagsScrollView.hidden) {
        h += 22 + 4;
    }
    h += 8; // bottom padding
    return MAX(h, 8);
}

- (void)layoutBottomBar {
    CGFloat w = self.bottomBar.bounds.size.width;
    CGFloat padding = 12;
    CGFloat y = self.bottomBar.bounds.size.height - 8; // Start from top

    if (!self.sourceLabel.hidden) {
        [self.sourceLabel sizeToFit];
        CGFloat labelH = self.sourceLabel.frame.size.height;
        y -= labelH;
        self.sourceLabel.frame = NSMakeRect(padding, y, w - padding * 2, labelH);
        y -= 4;
    }

    if (!self.tagsScrollView.hidden) {
        y -= 22;
        self.tagsScrollView.frame = NSMakeRect(padding, y, w - padding * 2, 22);

        // Size the tags stack to fit its content
        [self.tagsStack setFrameSize:NSMakeSize(self.tagsStack.fittingSize.width, 22)];
    }
}

#pragma mark - Scroll

- (void)scrollToBeginning {
    // Use NSTextView's built-in method to scroll to beginning
    [self.textView scrollToBeginningOfDocument:nil];
}

#pragma mark - Content

- (void)updateWithBiographyData:(BiographyData *)data {
    // Build attributed string
    NSMutableAttributedString *content = [[NSMutableAttributedString alloc] init];

    // Artist name (bold, larger)
    if (data.artistName.length > 0) {
        NSDictionary *nameAttrs = @{
            NSFontAttributeName: [NSFont boldSystemFontOfSize:16],
            NSForegroundColorAttributeName: [NSColor labelColor]
        };
        NSAttributedString *nameStr = [[NSAttributedString alloc] initWithString:data.artistName attributes:nameAttrs];
        [content appendAttributedString:nameStr];
        [content appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n\n"]];
    }

    // Biography text
    NSString *bio = data.biography ?: data.biographySummary;
    if (bio.length > 0) {
        NSDictionary *bioAttrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:13],
            NSForegroundColorAttributeName: [NSColor secondaryLabelColor]
        };
        NSAttributedString *bioStr = [[NSAttributedString alloc] initWithString:bio attributes:bioAttrs];
        [content appendAttributedString:bioStr];
    } else {
        NSDictionary *emptyAttrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:13],
            NSForegroundColorAttributeName: [NSColor tertiaryLabelColor]
        };
        NSAttributedString *emptyStr = [[NSAttributedString alloc] initWithString:@"No biography available." attributes:emptyAttrs];
        [content appendAttributedString:emptyStr];
    }

    // Set text
    [self.textView.textStorage setAttributedString:content];

    // Update source
    if (data.biographySource != BiographySourceUnknown) {
        self.sourceLabel.stringValue = [NSString stringWithFormat:@"Source: %@", [data biographySourceDisplayName]];
        self.sourceLabel.hidden = NO;
    } else {
        self.sourceLabel.hidden = YES;
    }

    // Update tags
    [self updateTags:data.tags];

    // Force layout
    [self setNeedsLayout:YES];
    [self layoutSubtreeIfNeeded];

    // PERF-11: Force synchronous text layout then scroll once
    [self.textView.layoutManager ensureLayoutForTextContainer:self.textView.textContainer];
    [self scrollToBeginning];
}

- (void)updateTags:(NSArray<NSString *> *)tags {
    // Clear existing
    for (NSView *v in [self.tagsStack.arrangedSubviews copy]) {
        [self.tagsStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    if (tags.count == 0) {
        self.tagsScrollView.hidden = YES;
        return;
    }

    // Show more tags since they're scrollable now
    NSUInteger max = MIN(tags.count, 10);
    for (NSUInteger i = 0; i < max; i++) {
        NSTextField *tag = [NSTextField labelWithString:tags[i]];
        tag.font = [NSFont systemFontOfSize:11];
        tag.textColor = [NSColor secondaryLabelColor];
        tag.backgroundColor = [NSColor quaternaryLabelColor];
        tag.drawsBackground = YES;
        tag.wantsLayer = YES;
        tag.layer.cornerRadius = 4;
        tag.alignment = NSTextAlignmentCenter;
        [self.tagsStack addArrangedSubview:tag];
    }
    self.tagsScrollView.hidden = NO;
}

- (void)clear {
    [self.textView.textStorage setAttributedString:[[NSAttributedString alloc] initWithString:@""]];
    self.sourceLabel.hidden = YES;
    self.tagsScrollView.hidden = YES;
    for (NSView *v in [self.tagsStack.arrangedSubviews copy]) {
        [self.tagsStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    // Clear gallery
    [self.galleryView clear];
    self.galleryView.hidden = YES;
}

#pragma mark - Gallery

- (void)updateGalleryImages:(NSArray<ArtistImage *> *)images {
    if (!images || images.count == 0) {
        self.galleryView.hidden = YES;
        [self.galleryView clear];
    } else {
        self.galleryView.images = images;
        self.galleryView.hidden = NO;
    }

    [self setNeedsLayout:YES];
    [self layoutSubtreeIfNeeded];
}

- (void)setGalleryLoading:(BOOL)loading {
    if (loading) {
        self.galleryView.isLoading = YES;
        self.galleryView.hidden = NO;
    } else {
        self.galleryView.isLoading = NO;
        // Don't hide here - wait for images to arrive
    }

    [self setNeedsLayout:YES];
    [self layoutSubtreeIfNeeded];
}

#pragma mark - ArtistGalleryViewDelegate

- (void)galleryView:(ArtistGalleryView *)view didSelectImageAtIndex:(NSUInteger)index {
    NSLog(@"[Gallery/ContentView] didSelectImageAtIndex:%lu, delegate: %@", (unsigned long)index, self.delegate);
    if ([self.delegate respondsToSelector:@selector(contentView:didSelectGalleryImageAtIndex:)]) {
        [self.delegate contentView:self didSelectGalleryImageAtIndex:index];
    }
}

- (NSSize)intrinsicContentSize {
    return NSMakeSize(-1, -1);
}

@end
