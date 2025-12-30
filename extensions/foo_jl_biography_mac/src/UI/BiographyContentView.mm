//
//  BiographyContentView.mm
//  foo_jl_biography_mac
//
//  Main content view displaying biography
//

#import "BiographyContentView.h"
#import "../Core/BiographyData.h"
#import <QuartzCore/QuartzCore.h>

@interface BiographyContentView () <NSTextViewDelegate>

// Main text view for scrollable biography content
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSTextView *textView;

// Fixed bottom bar
@property (nonatomic, strong) NSView *bottomBar;
@property (nonatomic, strong) NSTextField *sourceLabel;
@property (nonatomic, strong) NSScrollView *tagsScrollView;
@property (nonatomic, strong) NSStackView *tagsStack;

// Gradient overlay
@property (nonatomic, strong) NSView *gradientView;
@property (nonatomic, strong) CAGradientLayer *gradientLayer;

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

    // 2. Create scroll view with text view
    [self createScrollView];

    // 3. Create gradient overlay
    [self createGradientOverlay];
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

    // Observe scroll position
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(scrollDidChange:)
                                                 name:NSViewBoundsDidChangeNotification
                                               object:self.scrollView.contentView];
    self.scrollView.contentView.postsBoundsChangedNotifications = YES;
}

- (void)createGradientOverlay {
    // Gradient disabled for now - was causing visual issues
    self.gradientView = nil;
    self.gradientLayer = nil;
}

#pragma mark - Layout

- (void)layout {
    [super layout];

    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat bottomH = [self bottomBarHeight];
    CGFloat gradientH = 24;

    // Bottom bar at very bottom (y=0 in non-flipped)
    self.bottomBar.frame = NSMakeRect(0, 0, w, bottomH);
    [self layoutBottomBar];

    // Scroll view above bottom bar
    CGFloat scrollH = h - bottomH;
    self.scrollView.frame = NSMakeRect(0, bottomH, w, scrollH);

    // Update text view width
    NSSize containerSize = self.textView.textContainer.containerSize;
    containerSize.width = w - 24; // Account for insets
    self.textView.textContainer.containerSize = containerSize;
    [self.textView.layoutManager ensureLayoutForTextContainer:self.textView.textContainer];
    [self.textView sizeToFit];

    // Gradient just above bottom bar
    self.gradientView.frame = NSMakeRect(0, bottomH, w, gradientH);
    self.gradientLayer.frame = self.gradientView.bounds;

    [self updateGradientOpacity];
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

- (void)scrollDidChange:(NSNotification *)note {
    [self updateGradientOpacity];
}

- (void)updateGradientOpacity {
    NSRect docRect = self.textView.frame;
    NSRect visibleRect = self.scrollView.documentVisibleRect;

    CGFloat distanceFromBottom = NSMaxY(docRect) - NSMaxY(visibleRect);
    CGFloat opacity = (distanceFromBottom < 5) ? 0 : MIN(distanceFromBottom / 40.0, 1.0);
    self.gradientView.alphaValue = opacity;
}

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

    // Scroll to beginning - multiple attempts with delays to ensure it works
    [self scrollToBeginning];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self scrollToBeginning];
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self scrollToBeginning];
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self scrollToBeginning];
    });
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
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSSize)intrinsicContentSize {
    return NSMakeSize(-1, -1);
}

@end
