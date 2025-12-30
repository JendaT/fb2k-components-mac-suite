//
//  BiographyLoadingView.mm
//  foo_jl_biography_mac
//
//  Loading state view with spinner
//  Uses manual layout to avoid Auto Layout interfering with parent sizing
//

#import "BiographyLoadingView.h"

@interface BiographyLoadingView ()

@property (nonatomic, strong) NSProgressIndicator *spinner;
@property (nonatomic, strong) NSTextField *messageLabel;

@end

@implementation BiographyLoadingView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self setupViews];
    }
    return self;
}

- (void)setupViews {
    // Create spinner
    self.spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(0, 0, 32, 32)];
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    self.spinner.controlSize = NSControlSizeRegular;
    self.spinner.displayedWhenStopped = NO;

    // Create message label
    self.messageLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.messageLabel.stringValue = @"Loading biography...";
    self.messageLabel.font = [NSFont systemFontOfSize:13];
    self.messageLabel.textColor = [NSColor secondaryLabelColor];
    self.messageLabel.alignment = NSTextAlignmentCenter;
    self.messageLabel.bordered = NO;
    self.messageLabel.editable = NO;
    self.messageLabel.selectable = NO;
    self.messageLabel.backgroundColor = [NSColor clearColor];

    [self addSubview:self.spinner];
    [self addSubview:self.messageLabel];
}

- (void)layout {
    [super layout];

    NSRect bounds = self.bounds;
    CGFloat spacing = 12;
    CGFloat spinnerSize = 32;

    // Size the label to fit
    [self.messageLabel sizeToFit];
    NSSize labelSize = self.messageLabel.frame.size;

    // Calculate total content height
    CGFloat totalHeight = spinnerSize + spacing + labelSize.height;
    CGFloat startY = (bounds.size.height - totalHeight) / 2;

    // Position spinner centered horizontally
    CGFloat spinnerX = (bounds.size.width - spinnerSize) / 2;
    self.spinner.frame = NSMakeRect(spinnerX, bounds.size.height - startY - spinnerSize, spinnerSize, spinnerSize);

    // Position label centered horizontally, below spinner
    CGFloat labelX = (bounds.size.width - labelSize.width) / 2;
    self.messageLabel.frame = NSMakeRect(labelX, bounds.size.height - startY - spinnerSize - spacing - labelSize.height,
                                          labelSize.width, labelSize.height);
}

- (void)setArtistName:(NSString *)name {
    if (name.length > 0) {
        self.messageLabel.stringValue = [NSString stringWithFormat:@"Loading biography for %@...", name];
    } else {
        self.messageLabel.stringValue = @"Loading biography...";
    }
    [self setNeedsLayout:YES];
}

- (void)startAnimating {
    [self.spinner startAnimation:nil];
}

- (void)stopAnimating {
    [self.spinner stopAnimation:nil];
}

- (NSSize)intrinsicContentSize {
    return NSMakeSize(-1, -1);
}

@end
