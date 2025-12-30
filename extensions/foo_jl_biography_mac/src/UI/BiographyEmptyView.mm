//
//  BiographyEmptyView.mm
//  foo_jl_biography_mac
//
//  Empty state view when no track is playing
//  Uses manual layout to avoid Auto Layout interfering with parent sizing
//

#import "BiographyEmptyView.h"

@interface BiographyEmptyView ()

@property (nonatomic, strong) NSImageView *iconView;
@property (nonatomic, strong) NSTextField *messageLabel;

@end

@implementation BiographyEmptyView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self setupViews];
    }
    return self;
}

- (void)setupViews {
    // Create icon - will be positioned in layout
    NSImage *musicIcon = [NSImage imageWithSystemSymbolName:@"music.note"
                                   accessibilityDescription:@"No music"];
    self.iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 48, 48)];
    self.iconView.image = musicIcon;
    self.iconView.contentTintColor = [NSColor tertiaryLabelColor];
    self.iconView.imageScaling = NSImageScaleProportionallyUpOrDown;

    // Create message label
    self.messageLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.messageLabel.stringValue = @"No track playing";
    self.messageLabel.font = [NSFont systemFontOfSize:13];
    self.messageLabel.textColor = [NSColor secondaryLabelColor];
    self.messageLabel.alignment = NSTextAlignmentCenter;
    self.messageLabel.bordered = NO;
    self.messageLabel.editable = NO;
    self.messageLabel.selectable = NO;
    self.messageLabel.backgroundColor = [NSColor clearColor];

    [self addSubview:self.iconView];
    [self addSubview:self.messageLabel];
}

- (void)layout {
    [super layout];

    NSRect bounds = self.bounds;
    CGFloat spacing = 12;
    CGFloat iconSize = 48;

    // Size the label to fit
    [self.messageLabel sizeToFit];
    NSSize labelSize = self.messageLabel.frame.size;

    // Calculate total content height
    CGFloat totalHeight = iconSize + spacing + labelSize.height;
    CGFloat startY = (bounds.size.height - totalHeight) / 2;

    // Position icon centered horizontally, at top of content area
    CGFloat iconX = (bounds.size.width - iconSize) / 2;
    self.iconView.frame = NSMakeRect(iconX, bounds.size.height - startY - iconSize, iconSize, iconSize);

    // Position label centered horizontally, below icon
    CGFloat labelX = (bounds.size.width - labelSize.width) / 2;
    self.messageLabel.frame = NSMakeRect(labelX, bounds.size.height - startY - iconSize - spacing - labelSize.height,
                                          labelSize.width, labelSize.height);
}

- (void)setMessage:(NSString *)message {
    self.messageLabel.stringValue = message ?: @"No track playing";
    [self setNeedsLayout:YES];
}

- (NSSize)intrinsicContentSize {
    return NSMakeSize(-1, -1);
}

@end
