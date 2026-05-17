//
//  LibVancedCellView.mm
//  foo_jl_libvanced
//

#import "LibVancedCellView.h"
#import "../Core/LibraryTreeNode.h"
#import "../Core/LibraryAlbumArtCache.h"
#import "../../../../shared/UIStyles.h"

@implementation LibVancedCellView {
    NSImageView *_artView;
    NSTextField *_nameLabel;
    NSTextField *_countLabel;
    NSLayoutConstraint *_artWidthConstraint;
    NSLayoutConstraint *_artLeadingConstraint;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupViews];
    }
    return self;
}

- (void)setupViews {
    _artView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _artView.translatesAutoresizingMaskIntoConstraints = NO;
    _artView.imageScaling = NSImageScaleProportionallyUpOrDown;
    _artView.wantsLayer = YES;
    _artView.layer.cornerRadius = 3.0;
    _artView.layer.masksToBounds = YES;
    [self addSubview:_artView];

    _nameLabel = [NSTextField labelWithString:@""];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _nameLabel.cell.truncatesLastVisibleLine = YES;
    [self addSubview:_nameLabel];

    _countLabel = [NSTextField labelWithString:@""];
    _countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _countLabel.textColor = fb2k_ui::secondaryTextColor();
    _countLabel.font = [NSFont systemFontOfSize:10];
    _countLabel.alignment = NSTextAlignmentRight;
    [_countLabel setContentHuggingPriority:NSLayoutPriorityRequired
                            forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_countLabel setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                         forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self addSubview:_countLabel];

    _artWidthConstraint = [_artView.widthAnchor constraintEqualToConstant:0];
    _artLeadingConstraint = [_artView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:2];

    [NSLayoutConstraint activateConstraints:@[
        _artLeadingConstraint,
        [_artView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_artView.heightAnchor constraintEqualToAnchor:_artView.widthAnchor],
        _artWidthConstraint,

        [_nameLabel.leadingAnchor constraintEqualToAnchor:_artView.trailingAnchor constant:4],
        [_nameLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],

        [_countLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_nameLabel.trailingAnchor constant:4],
        [_countLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-4],
        [_countLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
}

- (void)configureWithNode:(LibraryTreeNode *)node
             showAlbumArt:(BOOL)showArt
           showTrackCount:(BOOL)showCount {
    _nameLabel.stringValue = node.displayName ?: @"";

    BOOL isTrack = (node.nodeType == LibraryNodeTypeTrack);
    BOOL isGroup = (node.nodeType == LibraryNodeTypeGroup);

    // Font styling
    if (isTrack) {
        _nameLabel.font = [NSFont systemFontOfSize:12];
        _nameLabel.textColor = fb2k_ui::textColor();
    } else {
        _nameLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        _nameLabel.textColor = fb2k_ui::textColor();
    }

    // Album art
    if (showArt && isGroup && node.albumArtPath) {
        CGFloat artSize = 26.0;
        _artWidthConstraint.constant = artSize;

        NSImage *cached = [[LibraryAlbumArtCache sharedCache]
            imageForPath:node.albumArtPath
              completion:^(NSImage *image) {
                  self->_artView.image = image;
              }];

        _artView.image = cached;
        _artView.hidden = NO;
    } else {
        _artWidthConstraint.constant = 0;
        _artView.image = nil;
        _artView.hidden = YES;
    }

    // Track count badge
    if (showCount && isGroup) {
        NSInteger count = node.trackCount;
        _countLabel.stringValue = [NSString stringWithFormat:@"(%ld)", (long)count];
        _countLabel.hidden = NO;
    } else {
        _countLabel.stringValue = @"";
        _countLabel.hidden = YES;
    }
}

@end
