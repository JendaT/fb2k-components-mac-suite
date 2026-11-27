//
//  SVArtistHeaderView.mm
//  foo_jl_shellvanced_mac
//

#import "SVArtistHeaderView.h"
#import "SVArtistImageProvider.h"
#import "SVArtistLibrary.h"
#import "../../../../shared/UIStyles.h"

static const CGFloat kPhotoSize = 128.0;
static const CGFloat kPad = 24.0;

@implementation SVArtistHeaderView {
    NSImageView *_photo;
    NSTextField *_nameLabel;
    NSTextField *_countLabel;
    NSButton *_playButton;
    NSButton *_shuffleButton;
    NSUInteger _loadToken;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;

        _photo = [[NSImageView alloc] initWithFrame:NSZeroRect];
        _photo.imageScaling = NSImageScaleProportionallyUpOrDown;
        _photo.translatesAutoresizingMaskIntoConstraints = NO;

        _nameLabel = [NSTextField labelWithString:@""];
        _nameLabel.font = [NSFont systemFontOfSize:40 weight:NSFontWeightBold];
        _nameLabel.textColor = fb2k_ui::textColor();
        _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [_nameLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                             forOrientation:NSLayoutConstraintOrientationHorizontal];

        _countLabel = [NSTextField labelWithString:@""];
        _countLabel.font = [NSFont systemFontOfSize:13];
        _countLabel.textColor = fb2k_ui::secondaryTextColor();
        _countLabel.translatesAutoresizingMaskIntoConstraints = NO;

        _playButton = [NSButton buttonWithTitle:@"Play" target:self action:@selector(playClicked:)];
        _playButton.bezelStyle = NSBezelStyleRounded;
        _playButton.bezelColor = [NSColor controlAccentColor];
        _playButton.keyEquivalent = @"";
        _playButton.translatesAutoresizingMaskIntoConstraints = NO;

        _shuffleButton = [NSButton buttonWithTitle:@"Shuffle" target:self action:@selector(shuffleClicked:)];
        _shuffleButton.bezelStyle = NSBezelStyleRounded;
        _shuffleButton.translatesAutoresizingMaskIntoConstraints = NO;

        for (NSView *v in @[_photo, _nameLabel, _countLabel, _playButton, _shuffleButton]) [self addSubview:v];

        [NSLayoutConstraint activateConstraints:@[
            [_photo.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:kPad],
            [_photo.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_photo.widthAnchor constraintEqualToConstant:kPhotoSize],
            [_photo.heightAnchor constraintEqualToConstant:kPhotoSize],

            [_nameLabel.leadingAnchor constraintEqualToAnchor:_photo.trailingAnchor constant:kPad],
            [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-kPad],
            [_nameLabel.bottomAnchor constraintEqualToAnchor:_countLabel.topAnchor constant:-4],

            [_countLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_countLabel.bottomAnchor constraintEqualToAnchor:_playButton.topAnchor constant:-14],

            [_playButton.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_playButton.bottomAnchor constraintEqualToAnchor:_photo.bottomAnchor],
            [_playButton.widthAnchor constraintEqualToConstant:90],

            [_shuffleButton.leadingAnchor constraintEqualToAnchor:_playButton.trailingAnchor constant:10],
            [_shuffleButton.centerYAnchor constraintEqualToAnchor:_playButton.centerYAnchor],
            [_shuffleButton.widthAnchor constraintEqualToConstant:90],
        ]];
    }
    return self;
}

- (NSSize)intrinsicContentSize {
    return NSMakeSize(NSViewNoIntrinsicMetric, kPhotoSize + 2 * kPad);
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc removeObserver:self name:SVArtistLibraryDidChangeNotification object:nil];  // never double-register
    [nc removeObserver:self name:SVArtistImagesDidChangeNotification object:nil];
    if (self.window) {
        [nc addObserver:self selector:@selector(imagesChanged:)
                   name:SVArtistImagesDidChangeNotification object:nil];
        [nc addObserver:self selector:@selector(libraryChanged:)
                   name:SVArtistLibraryDidChangeNotification object:nil];
        [self updateCounts];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)libraryChanged:(NSNotification *)note {
    [self updateCounts];
}

// A Spotify photo arrived / credentials changed: re-request just the photo.
- (void)imagesChanged:(NSNotification *)note {
    if (_artistName.length == 0) return;
    const NSUInteger token = ++_loadToken;
    [[SVArtistImageProvider shared] imageForArtist:_artistName size:kPhotoSize priority:YES
                                        completion:^(NSImage *image) {
        if (token == self->_loadToken) self->_photo.image = image;
    }];
}

- (void)setArtistName:(NSString *)artistName {
    _artistName = [artistName copy];
    _nameLabel.stringValue = artistName ?: @"";
    [self updateCounts];

    const NSUInteger token = ++_loadToken;
    if (artistName.length == 0) { _photo.image = nil; return; }
    _photo.image = nil;
    [[SVArtistImageProvider shared] imageForArtist:artistName size:kPhotoSize priority:YES
                                        completion:^(NSImage *image) {
        if (token == self->_loadToken) self->_photo.image = image;  // ignore stale loads
    }];
}

- (void)refreshCounts { [self updateCounts]; }

- (void)updateCounts {
    if (_artistName.length == 0) { _countLabel.stringValue = @""; return; }
    SVArtistLibrary *lib = [SVArtistLibrary shared];
    NSUInteger albums = [lib albumCountForArtist:_artistName];
    NSUInteger tracks = [lib trackCountForArtist:_artistName];
    _countLabel.stringValue = [NSString stringWithFormat:@"%lu %@ · %lu %@",
                               (unsigned long)albums, albums == 1 ? @"album" : @"albums",
                               (unsigned long)tracks, tracks == 1 ? @"track" : @"tracks"];
}

- (void)playClicked:(id)sender { if (self.onPlay) self.onPlay(); }
- (void)shuffleClicked:(id)sender { if (self.onShuffle) self.onShuffle(); }

@end
