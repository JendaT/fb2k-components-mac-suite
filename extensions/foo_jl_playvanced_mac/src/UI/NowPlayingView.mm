#import "NowPlayingView.h"
#import "../Core/TrackInfo.h"
#import "../Core/ArtworkFetcher.h"
#import "../../../../shared/UIStyles.h"

static const CGFloat kBarHeight       = 52.0;
static const CGFloat kArtSize         = 40.0;
static const CGFloat kPadding         = 6.0;
static const CGFloat kButtonSize      = 28.0;
static const CGFloat kSmallButtonSize = 22.0;
static const CGFloat kButtonSpacing   = 2.0;
static const CGFloat kProgressHeight  = 4.0;
static const CGFloat kVolumeWidth     = 70.0;
static const CGFloat kRatingWidth     = 78.0;

static NSPasteboardType const kSimPlaylistPBType = @"com.foobar2000.simplaylist.rows";

@interface NowPlayingView ()
@property (nonatomic, strong) NSImageView *artworkView;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *artistLabel;
@property (nonatomic, strong) NSTextField *ratingLabel;
@property (nonatomic, strong) NSButton *prevButton;
@property (nonatomic, strong) NSButton *playPauseButton;
@property (nonatomic, strong) NSButton *nextButton;
@property (nonatomic, strong) NSButton *stopButton;
@property (nonatomic, strong) NSButton *shuffleButton;
@property (nonatomic, strong) NSButton *repeatButton;
@property (nonatomic, strong) NSButton *muteButton;
@property (nonatomic, strong) NSSlider *progressSlider;
@property (nonatomic, strong) NSTextField *elapsedLabel;
@property (nonatomic, strong) NSTextField *remainingLabel;
@property (nonatomic, strong) NSSlider *volumeSlider;
@property (nonatomic, strong) NSTextField *idleLabel;
@property (nonatomic, assign) BOOL isSeeking;
@property (nonatomic, assign) BOOL isDragTarget;
@property (nonatomic, strong) NSTrackingArea *trackInfoTrackingArea;
@property (nonatomic, strong) NSTrackingArea *ratingTrackingArea;
@property (nonatomic, assign) BOOL isTrackInfoHovering;
@property (nonatomic, assign) NSInteger hoveredRatingValue;
@end

@implementation NowPlayingView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _playbackPosition = 0;
        _trackDuration = 0;
        _isPlaying = NO;
        _isPaused = NO;
        _volume = 1.0;
        _playbackOrder = 0;
        _isSeeking = NO;
        _hoveredRatingValue = 0;
        [self setupSubviews];
    }
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

#pragma mark - Track Info Hit Area

- (NSRect)trackInfoRect {
    if (_titleLabel.isHidden) return NSZeroRect;
    return NSUnionRect(_titleLabel.frame, _artistLabel.frame);
}

- (void)updateTrackInfoTrackingArea {
    if (_trackInfoTrackingArea) {
        [self removeTrackingArea:_trackInfoTrackingArea];
    }
    NSRect rect = [self trackInfoRect];
    if (NSIsEmptyRect(rect)) return;

    _trackInfoTrackingArea = [[NSTrackingArea alloc]
        initWithRect:rect
        options:(NSTrackingMouseEnteredAndExited |
                 NSTrackingActiveInActiveApp)
        owner:self
        userInfo:@{@"trackInfo": @YES}];
    [self addTrackingArea:_trackInfoTrackingArea];
}

- (NSRect)ratingRect {
    if (_ratingLabel.isHidden) return NSZeroRect;
    return _ratingLabel.frame;
}

- (void)updateRatingTrackingArea {
    if (_ratingTrackingArea) {
        [self removeTrackingArea:_ratingTrackingArea];
    }
    NSRect rect = [self ratingRect];
    if (NSIsEmptyRect(rect)) return;

    _ratingTrackingArea = [[NSTrackingArea alloc]
        initWithRect:rect
        options:(NSTrackingMouseEnteredAndExited |
                 NSTrackingMouseMoved |
                 NSTrackingActiveInActiveApp)
        owner:self
        userInfo:@{@"rating": @YES}];
    [self addTrackingArea:_ratingTrackingArea];
}

#pragma mark - Setup

- (void)setupSubviews {
    // Album art
    _artworkView = [[NSImageView alloc] init];
    _artworkView.imageScaling = NSImageScaleProportionallyUpOrDown;
    _artworkView.translatesAutoresizingMaskIntoConstraints = NO;
    _artworkView.wantsLayer = YES;
    _artworkView.layer.cornerRadius = 4.0;
    _artworkView.layer.masksToBounds = YES;
    [self addSubview:_artworkView];

    // Title
    _titleLabel = [self makeLabel];
    _titleLabel.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightSemibold];
    _titleLabel.textColor = fb2k_ui::textColor();
    [self addSubview:_titleLabel];

    // Artist
    _artistLabel = [self makeLabel];
    _artistLabel.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
    _artistLabel.textColor = fb2k_ui::secondaryTextColor();
    [self addSubview:_artistLabel];

    _ratingLabel = [self makeLabel];
    _ratingLabel.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightRegular];
    _ratingLabel.alignment = NSTextAlignmentCenter;
    _ratingLabel.lineBreakMode = NSLineBreakByClipping;
    _ratingLabel.cell.truncatesLastVisibleLine = NO;
    [self addSubview:_ratingLabel];

    // Transport buttons
    _prevButton = [self makeTransportButton:@"backward.fill" size:kSmallButtonSize action:@selector(prevPressed:)];
    [self addSubview:_prevButton];

    _playPauseButton = [self makeTransportButton:@"play.fill" size:kButtonSize action:@selector(playPausePressed:)];
    [self addSubview:_playPauseButton];

    _nextButton = [self makeTransportButton:@"forward.fill" size:kSmallButtonSize action:@selector(nextPressed:)];
    [self addSubview:_nextButton];

    _stopButton = [self makeTransportButton:@"stop.fill" size:kSmallButtonSize action:@selector(stopPressed:)];
    [self addSubview:_stopButton];

    _shuffleButton = [self makeTransportButton:@"shuffle" size:kSmallButtonSize action:@selector(shufflePressed:)];
    [self addSubview:_shuffleButton];

    _repeatButton = [self makeTransportButton:@"repeat" size:kSmallButtonSize action:@selector(repeatPressed:)];
    [self addSubview:_repeatButton];

    _muteButton = [self makeTransportButton:@"speaker.wave.2.fill" size:kSmallButtonSize action:@selector(mutePressed:)];
    [self addSubview:_muteButton];

    // Progress slider
    _progressSlider = [[NSSlider alloc] init];
    _progressSlider.translatesAutoresizingMaskIntoConstraints = NO;
    _progressSlider.minValue = 0.0;
    _progressSlider.maxValue = 1.0;
    _progressSlider.doubleValue = 0.0;
    _progressSlider.target = self;
    _progressSlider.action = @selector(progressChanged:);
    _progressSlider.continuous = YES;
    [self addSubview:_progressSlider];

    // Elapsed time
    _elapsedLabel = [self makeTimeLabel];
    [self addSubview:_elapsedLabel];

    // Remaining time
    _remainingLabel = [self makeTimeLabel];
    _remainingLabel.alignment = NSTextAlignmentRight;
    [self addSubview:_remainingLabel];

    // Volume slider
    _volumeSlider = [[NSSlider alloc] init];
    _volumeSlider.translatesAutoresizingMaskIntoConstraints = NO;
    _volumeSlider.minValue = 0.0;
    _volumeSlider.maxValue = 1.0;
    _volumeSlider.doubleValue = 1.0;
    _volumeSlider.target = self;
    _volumeSlider.action = @selector(volumeChanged:);
    _volumeSlider.continuous = YES;
    [self addSubview:_volumeSlider];

    // Idle label
    _idleLabel = [self makeLabel];
    _idleLabel.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightLight];
    _idleLabel.textColor = [fb2k_ui::secondaryTextColor() colorWithAlphaComponent:0.5];
    _idleLabel.stringValue = @"Not playing";
    _idleLabel.alignment = NSTextAlignmentCenter;
    [self addSubview:_idleLabel];

    [self registerForDraggedTypes:@[kSimPlaylistPBType, NSPasteboardTypeFileURL]];

    [self updateMuteIcon];
    [self updateShuffleRepeatButtons];
}

- (NSTextField *)makeLabel {
    NSTextField *label = [[NSTextField alloc] init];
    label.bordered = NO;
    label.editable = NO;
    label.selectable = NO;
    label.drawsBackground = NO;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.cell.truncatesLastVisibleLine = YES;
    return label;
}

- (NSTextField *)makeTimeLabel {
    NSTextField *label = [self makeLabel];
    label.font = [NSFont monospacedDigitSystemFontOfSize:10.0 weight:NSFontWeightRegular];
    label.textColor = fb2k_ui::secondaryTextColor();
    label.stringValue = @"0:00";
    return label;
}

- (NSButton *)makeTransportButton:(NSString *)symbolName size:(CGFloat)size action:(SEL)action {
    NSButton *button = [[NSButton alloc] init];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.bordered = NO;
    button.bezelStyle = NSBezelStyleRegularSquare;
    button.target = self;
    button.action = action;

    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration
        configurationWithPointSize:(size == kButtonSize ? 16 : 12)
        weight:NSFontWeightMedium
        scale:NSImageSymbolScaleMedium];

    NSImage *img = [[NSImage imageWithSystemSymbolName:symbolName
                                      accessibilityDescription:symbolName]
                    imageWithSymbolConfiguration:config];
    button.image = img;
    button.imagePosition = NSImageOnly;
    button.contentTintColor = fb2k_ui::textColor();

    [NSLayoutConstraint activateConstraints:@[
        [button.widthAnchor constraintEqualToConstant:size],
        [button.heightAnchor constraintEqualToConstant:size],
    ]];

    return button;
}

#pragma mark - Layout

- (void)layout {
    [super layout];

    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat midY = h / 2.0;

    BOOL hasTrack = self.isPlaying || self.isPaused || self.trackInfo != nil;

    BOOL showSecondary = (w >= 500);

    _idleLabel.hidden = hasTrack;
    _artworkView.hidden = !hasTrack;
    _titleLabel.hidden = !hasTrack;
    _artistLabel.hidden = !hasTrack;
    _ratingLabel.hidden = !hasTrack;
    _prevButton.hidden = !hasTrack;
    _playPauseButton.hidden = !hasTrack;
    _nextButton.hidden = !hasTrack;
    _stopButton.hidden = !hasTrack;
    _shuffleButton.hidden = !hasTrack || !showSecondary;
    _repeatButton.hidden = !hasTrack || !showSecondary;
    _muteButton.hidden = !hasTrack;
    _progressSlider.hidden = !hasTrack;
    _elapsedLabel.hidden = !hasTrack;
    _remainingLabel.hidden = !hasTrack;
    _volumeSlider.hidden = !hasTrack;

    if (!hasTrack) {
        _idleLabel.frame = NSMakeRect(0, midY - 8, w, 16);
        return;
    }

    CGFloat x = kPadding;

    // Album art
    CGFloat artY = (h - kArtSize) / 2.0;
    _artworkView.frame = NSMakeRect(x, artY, kArtSize, kArtSize);
    x += kArtSize + kPadding;

    // Text info section (artist / title) — fixed width
    CGFloat textWidth = 140.0;
    if (w < 700) textWidth = 100.0;
    if (w < 500) textWidth = 80.0;

    _titleLabel.frame = NSMakeRect(x, midY - 18, textWidth, 16);
    _artistLabel.frame = NSMakeRect(x, midY + 2, textWidth, 14);
    x += textWidth + kPadding;

    // Transport buttons: [Prev][Play/Pause][Next][Stop]
    CGFloat btnY = midY - kButtonSize / 2.0;
    CGFloat smallBtnY = midY - kSmallButtonSize / 2.0;
    CGFloat btnX = x;

    _prevButton.frame = NSMakeRect(btnX, smallBtnY, kSmallButtonSize, kSmallButtonSize);
    btnX += kSmallButtonSize + kButtonSpacing;
    _playPauseButton.frame = NSMakeRect(btnX, btnY, kButtonSize, kButtonSize);
    btnX += kButtonSize + kButtonSpacing;
    _nextButton.frame = NSMakeRect(btnX, smallBtnY, kSmallButtonSize, kSmallButtonSize);
    btnX += kSmallButtonSize + kButtonSpacing;
    _stopButton.frame = NSMakeRect(btnX, smallBtnY, kSmallButtonSize, kSmallButtonSize);
    btnX += kSmallButtonSize;
    x = btnX + kPadding * 2;

    // Right-side controls: [Shuffle][Repeat][Mute][===volume===]
    CGFloat rightX = w - kPadding;
    rightX -= kVolumeWidth;
    _volumeSlider.frame = NSMakeRect(rightX, midY - 10, kVolumeWidth, 20);
    rightX -= kButtonSpacing + kSmallButtonSize;
    _muteButton.frame = NSMakeRect(rightX, smallBtnY, kSmallButtonSize, kSmallButtonSize);
    if (showSecondary) {
        rightX -= kButtonSpacing * 3 + kSmallButtonSize;
        _repeatButton.frame = NSMakeRect(rightX, smallBtnY, kSmallButtonSize, kSmallButtonSize);
        rightX -= kButtonSpacing + kSmallButtonSize;
        _shuffleButton.frame = NSMakeRect(rightX, smallBtnY, kSmallButtonSize, kSmallButtonSize);
        rightX -= kPadding;
    }
    CGFloat controlsX = rightX;

    // Rating sits after the track bar and before shuffle/repeat/mute/volume controls.
    CGFloat ratingX = controlsX - kPadding - kRatingWidth;
    BOOL showRating = (ratingX - x) >= 120.0;
    _ratingLabel.hidden = !showRating;
    _ratingLabel.frame = NSMakeRect(ratingX, midY - 8, kRatingWidth, 16);

    // Progress area fills the remaining space between transport and right controls
    CGFloat timeWidth = 38.0;
    CGFloat progressRight = (showRating ? ratingX : controlsX) - kPadding;
    CGFloat progressLeft = x;

    _elapsedLabel.frame = NSMakeRect(progressLeft, midY - 16, timeWidth, 14);
    _remainingLabel.frame = NSMakeRect(progressRight - timeWidth, midY - 16, timeWidth, 14);

    CGFloat sliderLeft = progressLeft + timeWidth + 4;
    CGFloat sliderRight = progressRight - timeWidth - 4;
    CGFloat sliderWidth = sliderRight - sliderLeft;
    if (sliderWidth < 40) sliderWidth = 40;
    _progressSlider.frame = NSMakeRect(sliderLeft, midY - 10, sliderWidth, 20);

    // Elapsed/remaining below slider for narrow widths? No, keep inline.
    // Update time labels position to be below the slider for cleaner look
    _elapsedLabel.frame = NSMakeRect(sliderLeft, midY + 6, timeWidth + 10, 14);
    _remainingLabel.frame = NSMakeRect(sliderLeft + sliderWidth - timeWidth - 10, midY + 6, timeWidth + 10, 14);

    [self updateTrackInfoTrackingArea];
    [self updateRatingTrackingArea];
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    if (_isDragTarget) {
        [[NSColor controlAccentColor] setStroke];
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 2, 2)
                                                            xRadius:4 yRadius:4];
        path.lineWidth = 3.0;
        [path stroke];
    }
}

#pragma mark - Drag Destination

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NSPasteboard *pb = [sender draggingPasteboard];
    if ([pb.types containsObject:kSimPlaylistPBType] ||
        [pb.types containsObject:NSPasteboardTypeFileURL]) {
        self.isDragTarget = YES;
        [self setNeedsDisplay:YES];
        return NSDragOperationCopy;
    }
    return NSDragOperationNone;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    return _isDragTarget ? NSDragOperationCopy : NSDragOperationNone;
}

- (void)draggingExited:(nullable id<NSDraggingInfo>)sender {
    self.isDragTarget = NO;
    [self setNeedsDisplay:YES];
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender {
    return YES;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    self.isDragTarget = NO;
    [self setNeedsDisplay:YES];

    NSPasteboard *pb = [sender draggingPasteboard];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];

    // Prefer SimPlaylist internal type (carries foobar2000 paths)
    if ([pb.types containsObject:kSimPlaylistPBType]) {
        NSData *data = [pb dataForType:kSimPlaylistPBType];
        if (data) {
            NSDictionary *dragData = [NSKeyedUnarchiver
                unarchivedObjectOfClasses:[NSSet setWithObjects:
                    [NSDictionary class], [NSArray class],
                    [NSNumber class], [NSString class], nil]
                fromData:data error:nil];
            NSArray<NSString *> *dragPaths = dragData[@"paths"];
            if (dragPaths) [paths addObjectsFromArray:dragPaths];
        }
    }

    // Fallback to standard file URLs
    if (paths.count == 0 && [pb.types containsObject:NSPasteboardTypeFileURL]) {
        NSArray *urls = [pb readObjectsForClasses:@[[NSURL class]]
                                          options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
        for (NSURL *url in urls) {
            if (url.path) [paths addObject:url.path];
        }
    }

    if (paths.count > 0 && [self.delegate respondsToSelector:@selector(nowPlayingViewDidReceiveDroppedPaths:)]) {
        [self.delegate nowPlayingViewDidReceiveDroppedPaths:paths];
        return YES;
    }
    return NO;
}

- (void)concludeDragOperation:(nullable id<NSDraggingInfo>)sender {
    self.isDragTarget = NO;
    [self setNeedsDisplay:YES];
}

#pragma mark - Actions

- (void)prevPressed:(id)sender {
    [self.delegate nowPlayingViewDidPressPrevious];
}

- (void)playPausePressed:(id)sender {
    [self.delegate nowPlayingViewDidPressPlayPause];
}

- (void)nextPressed:(id)sender {
    [self.delegate nowPlayingViewDidPressNext];
}

- (void)stopPressed:(id)sender {
    [self.delegate nowPlayingViewDidPressStop];
}

- (void)shufflePressed:(id)sender {
    [self.delegate nowPlayingViewDidToggleShuffle];
}

- (void)repeatPressed:(id)sender {
    [self.delegate nowPlayingViewDidCycleRepeat];
}

- (void)mutePressed:(id)sender {
    [self.delegate nowPlayingViewDidToggleMute];
}

- (void)progressChanged:(id)sender {
    double fraction = _progressSlider.doubleValue;
    [self.delegate nowPlayingViewDidSeekToPosition:fraction];
}

- (void)volumeChanged:(id)sender {
    float vol = (float)_volumeSlider.doubleValue;
    [self.delegate nowPlayingViewDidChangeVolume:vol];
}

#pragma mark - Property Setters

- (void)setArtworkImage:(NSImage *)artworkImage {
    _artworkImage = artworkImage;
    _artworkView.image = artworkImage ?: [ArtworkFetcher placeholderImageOfSize:kArtSize];
}

- (void)setTrackInfo:(TrackInfo *)trackInfo {
    _trackInfo = trackInfo;
    if (trackInfo) {
        _titleLabel.stringValue = trackInfo.title ?: @"";
        _artistLabel.stringValue = trackInfo.artist ?: @"";
        [self updateRatingDisplayWithRating:[self ratingFromString:trackInfo.rating]];
    } else {
        _titleLabel.stringValue = @"";
        _artistLabel.stringValue = @"";
        [self updateRatingDisplayWithRating:0];
    }
    [self setNeedsLayout:YES];
}

- (void)setPlaybackPosition:(double)playbackPosition {
    _playbackPosition = playbackPosition;
    if (!_isSeeking && _trackDuration > 0) {
        _progressSlider.doubleValue = playbackPosition / _trackDuration;
    }
    _elapsedLabel.stringValue = [self formatTime:playbackPosition];
    _remainingLabel.stringValue = [self formatTime:_trackDuration];
}

- (void)setIsPlaying:(BOOL)isPlaying {
    _isPlaying = isPlaying;
    [self updatePlayPauseIcon];
    [self setNeedsLayout:YES];
}

- (void)setIsPaused:(BOOL)isPaused {
    _isPaused = isPaused;
    [self updatePlayPauseIcon];
}

- (void)setVolume:(float)volume {
    _volume = volume;
    _volumeSlider.doubleValue = volume;
    [self updateMuteIcon];
}

- (void)setPlaybackOrder:(NSInteger)playbackOrder {
    _playbackOrder = playbackOrder;
    [self updateShuffleRepeatButtons];
}

- (void)updateMuteIcon {
    BOOL muted = (_volume <= 0.001f);
    NSString *symbol = muted ? @"speaker.slash.fill" : @"speaker.wave.2.fill";
    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration
        configurationWithPointSize:12 weight:NSFontWeightMedium scale:NSImageSymbolScaleMedium];
    _muteButton.image = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:symbol]
                         imageWithSymbolConfiguration:config];
    _muteButton.contentTintColor = muted ? [NSColor controlAccentColor] : fb2k_ui::textColor();
}

- (void)updateShuffleRepeatButtons {
    // Shuffle: active when order is 3 (Random), 4 (Shuffle tracks), 5 (Shuffle albums), 6 (Shuffle folders)
    BOOL shuffleActive = (_playbackOrder >= 3);
    _shuffleButton.contentTintColor = shuffleActive ? [NSColor controlAccentColor] : fb2k_ui::textColor();

    // Repeat: active when order is 1 (Repeat playlist) or 2 (Repeat track)
    BOOL repeatActive = (_playbackOrder == 1 || _playbackOrder == 2);
    BOOL repeatOne   = (_playbackOrder == 2);
    NSString *repeatSymbol = repeatOne ? @"repeat.1" : @"repeat";
    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration
        configurationWithPointSize:12 weight:NSFontWeightMedium scale:NSImageSymbolScaleMedium];
    _repeatButton.image = [[NSImage imageWithSystemSymbolName:repeatSymbol accessibilityDescription:repeatSymbol]
                           imageWithSymbolConfiguration:config];
    _repeatButton.contentTintColor = repeatActive ? [NSColor controlAccentColor] : fb2k_ui::textColor();
}

- (void)updatePlayPauseIcon {
    NSString *symbol = (_isPlaying && !_isPaused) ? @"pause.fill" : @"play.fill";
    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration
        configurationWithPointSize:16
        weight:NSFontWeightMedium
        scale:NSImageSymbolScaleMedium];
    _playPauseButton.image = [[NSImage imageWithSystemSymbolName:symbol
                                                accessibilityDescription:symbol]
                              imageWithSymbolConfiguration:config];
}

- (void)clearDisplay {
    _artworkImage = nil;
    _trackInfo = nil;
    _playbackPosition = 0;
    _trackDuration = 0;
    _isPlaying = NO;
    _isPaused = NO;
    _artworkView.image = nil;
    _titleLabel.stringValue = @"";
    _artistLabel.stringValue = @"";
    _ratingLabel.stringValue = @"";
    _progressSlider.doubleValue = 0;
    _elapsedLabel.stringValue = @"0:00";
    _remainingLabel.stringValue = @"0:00";
    [self updatePlayPauseIcon];
    [self setNeedsLayout:YES];
}

#pragma mark - Time Formatting

- (NSString *)formatTime:(double)seconds {
    if (seconds < 0 || !isfinite(seconds)) return @"0:00";
    int totalSeconds = (int)seconds;
    int minutes = totalSeconds / 60;
    int secs = totalSeconds % 60;
    return [NSString stringWithFormat:@"%d:%02d", minutes, secs];
}

#pragma mark - Rating

- (NSInteger)ratingFromString:(NSString *)value {
    NSInteger rating = value.integerValue;
    if (rating < 0) rating = 0;
    if (rating > 5) rating = 5;
    return rating;
}

- (void)updateRatingDisplayWithRating:(NSInteger)rating {
    NSInteger displayRating = (_hoveredRatingValue > 0) ? _hoveredRatingValue : rating;
    NSMutableAttributedString *stars = [[NSMutableAttributedString alloc] init];
    NSFont *font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    for (NSInteger i = 1; i <= 5; i++) {
        BOOL filled = i <= displayRating;
        NSColor *color = filled ? [[NSColor controlAccentColor] colorWithAlphaComponent:(_hoveredRatingValue > 0 ? 0.75 : 1.0)]
                                : [fb2k_ui::secondaryTextColor() colorWithAlphaComponent:0.55];
        [stars appendAttributedString:[[NSAttributedString alloc] initWithString:(filled ? @"★" : @"☆")
                                                                      attributes:@{NSFontAttributeName: font,
                                                                                   NSForegroundColorAttributeName: color}]];
    }
    _ratingLabel.attributedStringValue = stars;
}

- (NSInteger)ratingValueAtPoint:(NSPoint)point {
    NSRect rect = [self ratingRect];
    if (NSIsEmptyRect(rect) || !NSPointInRect(point, rect)) return 0;
    CGFloat localX = point.x - rect.origin.x;
    NSInteger rating = (NSInteger)floor((localX / MAX(rect.size.width, 1.0)) * 5.0) + 1;
    return MAX(1, MIN(5, rating));
}

#pragma mark - Track Info Hover & Click

- (NSView *)hitTest:(NSPoint)point {
    NSPoint local = [self convertPoint:point fromView:self.superview];
    if (!_ratingLabel.isHidden && NSPointInRect(local, [self ratingRect])) {
        return self;
    }
    if (!_titleLabel.isHidden && NSPointInRect(local, [self trackInfoRect])) {
        return self;
    }
    return [super hitTest:point];
}

- (void)mouseEntered:(NSEvent *)event {
    if ([event.trackingArea.userInfo[@"trackInfo"] boolValue]) {
        _isTrackInfoHovering = YES;
        _titleLabel.textColor = [NSColor controlAccentColor];
        _artistLabel.textColor = [NSColor controlAccentColor];
        [[NSCursor pointingHandCursor] push];
    } else if ([event.trackingArea.userInfo[@"rating"] boolValue]) {
        [[NSCursor pointingHandCursor] push];
    }
}

- (void)mouseExited:(NSEvent *)event {
    if ([event.trackingArea.userInfo[@"trackInfo"] boolValue]) {
        _isTrackInfoHovering = NO;
        _titleLabel.textColor = fb2k_ui::textColor();
        _artistLabel.textColor = fb2k_ui::secondaryTextColor();
        [NSCursor pop];
    } else if ([event.trackingArea.userInfo[@"rating"] boolValue]) {
        _hoveredRatingValue = 0;
        [self updateRatingDisplayWithRating:[self ratingFromString:self.trackInfo.rating]];
        [NSCursor pop];
    }
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger hoverRating = [self ratingValueAtPoint:location];
    if (hoverRating != _hoveredRatingValue) {
        _hoveredRatingValue = hoverRating;
        [self updateRatingDisplayWithRating:[self ratingFromString:self.trackInfo.rating]];
    }
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger clickedRating = [self ratingValueAtPoint:location];
    if (clickedRating > 0) {
        NSInteger currentRating = [self ratingFromString:self.trackInfo.rating];
        NSInteger newRating = (currentRating == clickedRating) ? 0 : clickedRating;
        [self.delegate nowPlayingViewDidRequestSetRating:newRating];
        self.trackInfo.rating = [NSString stringWithFormat:@"%ld", (long)newRating];
        [self updateRatingDisplayWithRating:newRating];
        return;
    }
    if (NSPointInRect(location, [self trackInfoRect]) && !_titleLabel.isHidden) {
        _isTrackInfoHovering = YES;
        _titleLabel.alphaValue = 0.7;
        _artistLabel.alphaValue = 0.7;
        return;
    }
    [super mouseDown:event];
}

- (void)mouseUp:(NSEvent *)event {
    if (_titleLabel.alphaValue < 1.0) {
        _titleLabel.alphaValue = 1.0;
        _artistLabel.alphaValue = 1.0;

        NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];
        if (NSPointInRect(location, [self trackInfoRect])) {
            [self.delegate nowPlayingViewDidTapTrackInfo];
        }
        _isTrackInfoHovering = NO;
        _titleLabel.textColor = fb2k_ui::textColor();
        _artistLabel.textColor = fb2k_ui::secondaryTextColor();
        return;
    }
    [super mouseUp:event];
}

#pragma mark - Keyboard

- (BOOL)acceptsFirstResponder { return YES; }

- (void)keyDown:(NSEvent *)event {
    NSString *chars = event.charactersIgnoringModifiers;
    if (chars.length > 0 && [chars characterAtIndex:0] == ' ') {
        playback_control::get()->toggle_pause();
        return;
    }
    [super keyDown:event];
}

@end
