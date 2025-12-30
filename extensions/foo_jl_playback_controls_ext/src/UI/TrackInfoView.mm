//
//  TrackInfoView.mm
//  foo_jl_playback_controls_ext
//
//  Two-row track info display implementation
//

#import "TrackInfoView.h"

@interface TrackInfoView ()

@property (nonatomic, strong) NSTextField *topRowLabel;
@property (nonatomic, strong) NSTextField *bottomRowLabel;
@property (nonatomic, strong) NSTrackingArea *trackingArea;
@property (nonatomic, assign) BOOL isHovering;

@end

@implementation TrackInfoView

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
    _topRowText = @"Not Playing";
    _bottomRowText = @"";
    _topRowFont = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    _bottomRowFont = [NSFont systemFontOfSize:10 weight:NSFontWeightRegular];
    _topRowColor = [NSColor labelColor];
    _bottomRowColor = [NSColor secondaryLabelColor];
    _isHovering = NO;

    [self setupViews];
    [self setupTrackingArea];
}

- (void)setupViews {
    // Top row label (artist - title)
    self.topRowLabel = [NSTextField labelWithString:self.topRowText];
    self.topRowLabel.font = self.topRowFont;
    self.topRowLabel.textColor = self.topRowColor;
    self.topRowLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.topRowLabel.translatesAutoresizingMaskIntoConstraints = NO;

    // Bottom row label (time info)
    self.bottomRowLabel = [NSTextField labelWithString:self.bottomRowText];
    self.bottomRowLabel.font = self.bottomRowFont;
    self.bottomRowLabel.textColor = self.bottomRowColor;
    self.bottomRowLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.bottomRowLabel.translatesAutoresizingMaskIntoConstraints = NO;

    // Stack them vertically
    NSStackView *stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.spacing = 0;
    stack.alignment = NSLayoutAttributeLeading;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    [stack addArrangedSubview:self.topRowLabel];
    [stack addArrangedSubview:self.bottomRowLabel];

    [self addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:4],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-4],
        [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]
    ]];

    // Minimum width
    [NSLayoutConstraint activateConstraints:@[
        [self.widthAnchor constraintGreaterThanOrEqualToConstant:100]
    ]];
}

- (void)setupTrackingArea {
    self.trackingArea = [[NSTrackingArea alloc]
                         initWithRect:self.bounds
                         options:(NSTrackingMouseEnteredAndExited |
                                 NSTrackingActiveInActiveApp |
                                 NSTrackingInVisibleRect)
                         owner:self
                         userInfo:nil];
    [self addTrackingArea:self.trackingArea];
}

#pragma mark - Property Setters

- (void)setTopRowText:(NSString *)topRowText {
    _topRowText = [topRowText copy];
    self.topRowLabel.stringValue = topRowText ?: @"";
}

- (void)setBottomRowText:(NSString *)bottomRowText {
    _bottomRowText = [bottomRowText copy];
    self.bottomRowLabel.stringValue = bottomRowText ?: @"";
}

- (void)setTopRowFont:(NSFont *)topRowFont {
    _topRowFont = topRowFont;
    self.topRowLabel.font = topRowFont;
}

- (void)setBottomRowFont:(NSFont *)bottomRowFont {
    _bottomRowFont = bottomRowFont;
    self.bottomRowLabel.font = bottomRowFont;
}

- (void)setTopRowColor:(NSColor *)topRowColor {
    _topRowColor = topRowColor;
    if (!self.isHovering) {
        self.topRowLabel.textColor = topRowColor;
    }
}

- (void)setBottomRowColor:(NSColor *)bottomRowColor {
    _bottomRowColor = bottomRowColor;
    self.bottomRowLabel.textColor = bottomRowColor;
}

#pragma mark - Mouse Events

- (void)mouseEntered:(NSEvent *)event {
    self.isHovering = YES;
    self.topRowLabel.textColor = [NSColor controlAccentColor];

    // Change cursor to pointing hand
    [[NSCursor pointingHandCursor] push];
}

- (void)mouseExited:(NSEvent *)event {
    self.isHovering = NO;
    self.topRowLabel.textColor = self.topRowColor;

    [NSCursor pop];
}

- (void)mouseDown:(NSEvent *)event {
    // Visual feedback
    self.alphaValue = 0.7;
}

- (void)mouseUp:(NSEvent *)event {
    self.alphaValue = 1.0;

    // Check if mouse is still inside
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(location, self.bounds)) {
        [self.delegate trackInfoViewDidClick:self];
    }
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    // Draw subtle background on hover
    if (self.isHovering) {
        [[NSColor colorWithWhite:0.5 alpha:0.1] setFill];
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:self.bounds
                                                             xRadius:4
                                                             yRadius:4];
        [path fill];
    }
}

- (BOOL)isFlipped {
    return YES;
}

@end
