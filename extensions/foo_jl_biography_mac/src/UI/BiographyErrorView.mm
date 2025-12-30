//
//  BiographyErrorView.mm
//  foo_jl_biography_mac
//
//  Simple error/not found state view with retry option
//

#import "BiographyErrorView.h"

@interface BiographyErrorView ()

@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *detailLabel;
@property (nonatomic, strong) NSButton *retryButton;

@end

@implementation BiographyErrorView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self setupViews];
    }
    return self;
}

- (void)setupViews {
    // Title label
    self.titleLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.titleLabel.stringValue = @"No biography available";
    self.titleLabel.font = [NSFont systemFontOfSize:13];
    self.titleLabel.textColor = [NSColor secondaryLabelColor];
    self.titleLabel.alignment = NSTextAlignmentCenter;
    self.titleLabel.bordered = NO;
    self.titleLabel.editable = NO;
    self.titleLabel.selectable = NO;
    self.titleLabel.backgroundColor = [NSColor clearColor];

    // Detail label
    self.detailLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.detailLabel.stringValue = @"";
    self.detailLabel.font = [NSFont systemFontOfSize:11];
    self.detailLabel.textColor = [NSColor tertiaryLabelColor];
    self.detailLabel.alignment = NSTextAlignmentCenter;
    self.detailLabel.bordered = NO;
    self.detailLabel.editable = NO;
    self.detailLabel.selectable = NO;
    self.detailLabel.backgroundColor = [NSColor clearColor];
    self.detailLabel.lineBreakMode = NSLineBreakByWordWrapping;

    // Retry button
    self.retryButton = [NSButton buttonWithTitle:@"Retry" target:self action:@selector(retryTapped:)];
    self.retryButton.bezelStyle = NSBezelStyleRounded;

    [self addSubview:self.titleLabel];
    [self addSubview:self.detailLabel];
    [self addSubview:self.retryButton];
}

- (void)layout {
    [super layout];

    NSRect bounds = self.bounds;
    CGFloat spacing = 8;
    CGFloat maxWidth = bounds.size.width * 0.85;

    // Size labels
    self.titleLabel.preferredMaxLayoutWidth = maxWidth;
    self.detailLabel.preferredMaxLayoutWidth = maxWidth;
    [self.titleLabel sizeToFit];
    [self.detailLabel sizeToFit];
    [self.retryButton sizeToFit];

    NSSize titleSize = self.titleLabel.frame.size;
    NSSize detailSize = self.detailLabel.frame.size;
    NSSize buttonSize = self.retryButton.frame.size;

    BOOL hasDetail = self.detailLabel.stringValue.length > 0;

    // Calculate total height
    CGFloat totalHeight = titleSize.height;
    if (hasDetail) {
        totalHeight += spacing + detailSize.height;
    }
    totalHeight += spacing + buttonSize.height;

    CGFloat startY = (bounds.size.height - totalHeight) / 2;
    CGFloat currentY = bounds.size.height - startY;

    // Position title
    currentY -= titleSize.height;
    self.titleLabel.frame = NSMakeRect((bounds.size.width - titleSize.width) / 2, currentY, titleSize.width, titleSize.height);

    // Position detail (if present)
    if (hasDetail) {
        currentY -= spacing + detailSize.height;
        self.detailLabel.frame = NSMakeRect((bounds.size.width - detailSize.width) / 2, currentY, detailSize.width, detailSize.height);
        self.detailLabel.hidden = NO;
    } else {
        self.detailLabel.hidden = YES;
    }

    // Position button
    currentY -= spacing + buttonSize.height;
    self.retryButton.frame = NSMakeRect((bounds.size.width - buttonSize.width) / 2, currentY, buttonSize.width, buttonSize.height);
}

- (void)setErrorMessage:(NSString *)message {
    self.titleLabel.stringValue = message ?: @"No biography available";
    [self setNeedsLayout:YES];
}

- (void)setErrorDetail:(NSString *)detail {
    self.detailLabel.stringValue = detail ?: @"";
    [self setNeedsLayout:YES];
}

- (void)retryTapped:(id)sender {
    if ([self.delegate respondsToSelector:@selector(errorViewDidTapRetry:)]) {
        [self.delegate errorViewDidTapRetry:self];
    }
}

- (NSSize)intrinsicContentSize {
    return NSMakeSize(-1, -1);
}

@end
