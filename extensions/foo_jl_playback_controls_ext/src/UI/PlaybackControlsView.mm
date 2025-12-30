//
//  PlaybackControlsView.mm
//  foo_jl_playback_controls_ext
//
//  Main container view implementation
//

#import "PlaybackControlsView.h"
#import <QuartzCore/QuartzCore.h>
#import "TrackInfoView.h"
#import "VolumeSliderView.h"

static NSPasteboardType const PlaybackButtonPasteboardType = @"com.foobar2000.playbackcontrols.button";

@interface PlaybackControlsView () <TrackInfoViewDelegate, VolumeSliderViewDelegate>

@property (nonatomic, strong) NSStackView *stackView;
@property (nonatomic, strong) NSMutableArray<NSView *> *buttonViews;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *currentOrder;

// Transport buttons
@property (nonatomic, strong) NSButton *previousButton;
@property (nonatomic, strong) NSButton *stopButton;
@property (nonatomic, strong) NSButton *playPauseButton;
@property (nonatomic, strong) NSButton *nextButton;

// Volume and track info
@property (nonatomic, strong) VolumeSliderView *volumeSlider;
@property (nonatomic, strong) TrackInfoView *trackInfoView;

// Editing mode state
@property (nonatomic, assign, readwrite) BOOL isEditingMode;
@property (nonatomic, assign, readwrite) BOOL isCompactMode;
@property (nonatomic, strong, nullable) NSView *draggedView;
@property (nonatomic, assign) NSInteger dropTargetIndex;

// Long press
@property (nonatomic, strong) NSPressGestureRecognizer *longPressRecognizer;

@end

@implementation PlaybackControlsView

- (instancetype)initWithCompactMode:(BOOL)compact {
    self = [super initWithFrame:NSMakeRect(0, 0, 400, compact ? 32 : 50)];
    if (self) {
        _isCompactMode = compact;
        _isEditingMode = NO;
        _dropTargetIndex = -1;
        _buttonViews = [NSMutableArray array];
        _currentOrder = [NSMutableArray arrayWithArray:@[@0, @1, @2, @3, @4, @5]];

        [self setupViews];
        [self setupGestureRecognizers];
        [self registerForDraggedTypes:@[PlaybackButtonPasteboardType]];
    }
    return self;
}

- (void)setupViews {
    // Create stack view
    self.stackView = [[NSStackView alloc] init];
    self.stackView.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    self.stackView.spacing = 4;
    self.stackView.alignment = NSLayoutAttributeCenterY;
    self.stackView.distribution = NSStackViewDistributionFill;
    self.stackView.translatesAutoresizingMaskIntoConstraints = NO;

    [self addSubview:self.stackView];
    [NSLayoutConstraint activateConstraints:@[
        [self.stackView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
        [self.stackView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
        [self.stackView.topAnchor constraintEqualToAnchor:self.topAnchor constant:4],
        [self.stackView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-4]
    ]];

    // Create buttons
    [self createTransportButtons];

    // Create volume slider
    [self createVolumeSlider];

    // Create track info view
    [self createTrackInfoView];

    // Add views in default order
    [self arrangeViewsInOrder];
}

- (void)createTransportButtons {
    // Previous button
    self.previousButton = [self createButtonWithSymbol:@"backward.fill"
                                                action:@selector(previousTapped:)
                                                   tag:PlaybackButtonTypePrevious];

    // Stop button (hidden in compact mode)
    self.stopButton = [self createButtonWithSymbol:@"stop.fill"
                                            action:@selector(stopTapped:)
                                               tag:PlaybackButtonTypeStop];
    self.stopButton.hidden = self.isCompactMode;

    // Play/Pause button
    self.playPauseButton = [self createButtonWithSymbol:@"play.fill"
                                                 action:@selector(playPauseTapped:)
                                                    tag:PlaybackButtonTypePlayPause];

    // Next button
    self.nextButton = [self createButtonWithSymbol:@"forward.fill"
                                            action:@selector(nextTapped:)
                                               tag:PlaybackButtonTypeNext];

    // Store button views
    [self.buttonViews addObject:self.previousButton];
    [self.buttonViews addObject:self.stopButton];
    [self.buttonViews addObject:self.playPauseButton];
    [self.buttonViews addObject:self.nextButton];
}

- (NSButton *)createButtonWithSymbol:(NSString *)symbolName
                              action:(SEL)action
                                 tag:(NSInteger)tag {
    NSButton *button = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:symbolName
                                                           accessibilityDescription:nil]
                                          target:self
                                          action:action];
    button.bezelStyle = NSBezelStyleTexturedRounded;
    button.bordered = NO;
    button.tag = tag;
    button.translatesAutoresizingMaskIntoConstraints = NO;

    [NSLayoutConstraint activateConstraints:@[
        [button.widthAnchor constraintEqualToConstant:28],
        [button.heightAnchor constraintEqualToConstant:28]
    ]];

    return button;
}

- (void)createVolumeSlider {
    self.volumeSlider = [[VolumeSliderView alloc] initWithOrientation:VolumeSliderOrientationHorizontal];
    self.volumeSlider.delegate = self;
    self.volumeSlider.translatesAutoresizingMaskIntoConstraints = NO;

    CGFloat width = self.isCompactMode ? 60 : 100;
    [NSLayoutConstraint activateConstraints:@[
        [self.volumeSlider.widthAnchor constraintEqualToConstant:width],
        [self.volumeSlider.heightAnchor constraintEqualToConstant:24]
    ]];

    [self.buttonViews addObject:self.volumeSlider];
}

- (void)createTrackInfoView {
    self.trackInfoView = [[TrackInfoView alloc] init];
    self.trackInfoView.delegate = self;
    self.trackInfoView.translatesAutoresizingMaskIntoConstraints = NO;
    self.trackInfoView.hidden = self.isCompactMode;

    // Track info should expand to fill available space
    [self.trackInfoView setContentHuggingPriority:NSLayoutPriorityDefaultLow
                                   forOrientation:NSLayoutConstraintOrientationHorizontal];

    [self.buttonViews addObject:self.trackInfoView];
}

- (void)arrangeViewsInOrder {
    // Remove all arranged subviews
    for (NSView *view in self.stackView.arrangedSubviews.copy) {
        [self.stackView removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    // Add views in current order
    for (NSNumber *index in self.currentOrder) {
        NSInteger idx = index.integerValue;
        if (idx >= 0 && idx < (NSInteger)self.buttonViews.count) {
            NSView *view = self.buttonViews[idx];

            // Skip hidden items in compact mode
            if (self.isCompactMode) {
                if (idx == PlaybackButtonTypeStop || idx == PlaybackButtonTypeTrackInfo) {
                    continue;
                }
            }

            [self.stackView addArrangedSubview:view];
        }
    }
}

#pragma mark - Gesture Recognizers

- (void)setupGestureRecognizers {
    self.longPressRecognizer = [[NSPressGestureRecognizer alloc]
                                initWithTarget:self
                                action:@selector(handleLongPress:)];
    self.longPressRecognizer.minimumPressDuration = 0.5;
    [self addGestureRecognizer:self.longPressRecognizer];
}

- (void)handleLongPress:(NSPressGestureRecognizer *)recognizer {
    if (recognizer.state == NSGestureRecognizerStateBegan) {
        [self.delegate controlsViewDidRequestEditMode:self];
    }
}

#pragma mark - Button Actions

- (void)previousTapped:(id)sender {
    [self.delegate controlsViewDidTapPrevious:self];
}

- (void)stopTapped:(id)sender {
    [self.delegate controlsViewDidTapStop:self];
}

- (void)playPauseTapped:(id)sender {
    [self.delegate controlsViewDidTapPlayPause:self];
}

- (void)nextTapped:(id)sender {
    [self.delegate controlsViewDidTapNext:self];
}

#pragma mark - Context Menu

- (void)rightMouseDown:(NSEvent *)event {
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];
    [self.delegate controlsViewDidRequestContextMenu:self atPoint:location];
}

#pragma mark - State Updates

- (void)updatePlayPauseState:(BOOL)isPlaying isPaused:(BOOL)isPaused {
    NSString *symbolName;
    if (!isPlaying) {
        symbolName = @"play.fill";
    } else if (isPaused) {
        symbolName = @"play.fill";
    } else {
        symbolName = @"pause.fill";
    }

    self.playPauseButton.image = [NSImage imageWithSystemSymbolName:symbolName
                                           accessibilityDescription:nil];
}

- (void)updateVolume:(float)volumeDB {
    [self.volumeSlider setVolumeDB:volumeDB];
}

- (void)updateTrackInfoWithTopRow:(NSString *)topRow bottomRow:(NSString *)bottomRow {
    self.trackInfoView.topRowText = topRow;
    self.trackInfoView.bottomRowText = bottomRow;
}

#pragma mark - Button Order

- (NSArray<NSNumber *> *)buttonOrder {
    return [self.currentOrder copy];
}

- (void)setButtonOrder:(NSArray<NSNumber *> *)order {
    self.currentOrder = [order mutableCopy];
    [self arrangeViewsInOrder];
}

#pragma mark - Editing Mode

- (void)enterEditingMode {
    self.isEditingMode = YES;
    [self startJiggleAnimation];
}

- (void)exitEditingMode {
    self.isEditingMode = NO;
    [self stopJiggleAnimation];
}

- (void)startJiggleAnimation {
    for (NSView *view in self.stackView.arrangedSubviews) {
        view.wantsLayer = YES;

        CABasicAnimation *rotation = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        rotation.fromValue = @(-0.03);
        rotation.toValue = @(0.03);
        rotation.duration = 0.1;
        rotation.repeatCount = HUGE_VALF;
        rotation.autoreverses = YES;
        [view.layer addAnimation:rotation forKey:@"jiggle"];
    }
}

- (void)stopJiggleAnimation {
    for (NSView *view in self.stackView.arrangedSubviews) {
        [view.layer removeAnimationForKey:@"jiggle"];
    }
}

#pragma mark - Drag and Drop Source

- (void)mouseDown:(NSEvent *)event {
    if (!self.isEditingMode) {
        [super mouseDown:event];
        return;
    }

    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];

    // Find which view was clicked
    for (NSView *view in self.stackView.arrangedSubviews) {
        if (NSPointInRect(location, view.frame)) {
            self.draggedView = view;
            break;
        }
    }
}

- (void)mouseDragged:(NSEvent *)event {
    if (!self.isEditingMode || !self.draggedView) {
        [super mouseDragged:event];
        return;
    }

    // Calculate drag distance
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];
    NSPoint viewCenter = NSMakePoint(NSMidX(self.draggedView.frame), NSMidY(self.draggedView.frame));
    CGFloat distance = hypot(location.x - viewCenter.x, location.y - viewCenter.y);

    // Start drag if moved enough
    if (distance > 5) {
        NSInteger idx = [self.stackView.arrangedSubviews indexOfObject:self.draggedView];
        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:@(idx)
                                             requiringSecureCoding:NO
                                                             error:nil];

        NSDraggingItem *draggingItem = [[NSDraggingItem alloc]
                                        initWithPasteboardWriter:[[NSPasteboardItem alloc] init]];

        NSPasteboardItem *pbItem = [[NSPasteboardItem alloc] init];
        [pbItem setData:data forType:PlaybackButtonPasteboardType];
        draggingItem = [[NSDraggingItem alloc] initWithPasteboardWriter:pbItem];

        // Create drag image
        NSImage *dragImage = [self imageOfView:self.draggedView];
        draggingItem.draggingFrame = self.draggedView.frame;
        draggingItem.imageComponentsProvider = ^NSArray<NSDraggingImageComponent *> *{
            NSDraggingImageComponent *component =
                [NSDraggingImageComponent draggingImageComponentWithKey:NSDraggingImageComponentIconKey];
            component.contents = dragImage;
            component.frame = NSMakeRect(0, 0, dragImage.size.width, dragImage.size.height);
            return @[component];
        };

        [self beginDraggingSessionWithItems:@[draggingItem]
                                      event:event
                                     source:self];

        self.draggedView.alphaValue = 0.3;
    }
}

- (NSImage *)imageOfView:(NSView *)view {
    NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];

    NSImage *image = [[NSImage alloc] initWithSize:view.bounds.size];
    [image addRepresentation:rep];
    return image;
}

- (NSDragOperation)draggingSession:(NSDraggingSession *)session
    sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    return self.isEditingMode ? NSDragOperationMove : NSDragOperationNone;
}

- (void)draggingSession:(NSDraggingSession *)session
           endedAtPoint:(NSPoint)screenPoint
              operation:(NSDragOperation)operation {
    self.draggedView.alphaValue = 1.0;
    self.draggedView = nil;
}

#pragma mark - Drag and Drop Destination

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    if (!self.isEditingMode) return NSDragOperationNone;
    return NSDragOperationMove;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    if (!self.isEditingMode) return NSDragOperationNone;

    NSPoint location = [self convertPoint:[sender draggingLocation] fromView:nil];

    // Find target index based on position
    NSInteger targetIndex = 0;
    for (NSView *view in self.stackView.arrangedSubviews) {
        if (location.x > NSMidX(view.frame)) {
            targetIndex++;
        } else {
            break;
        }
    }

    self.dropTargetIndex = targetIndex;
    [self setNeedsDisplay:YES];

    return NSDragOperationMove;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
    self.dropTargetIndex = -1;
    [self setNeedsDisplay:YES];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    if (!self.isEditingMode) return NO;

    NSPasteboard *pb = [sender draggingPasteboard];
    NSData *data = [pb dataForType:PlaybackButtonPasteboardType];

    if (!data) return NO;

    NSNumber *sourceIndex = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSNumber class]
                                                              fromData:data
                                                                 error:nil];
    if (!sourceIndex) return NO;

    NSInteger srcIdx = sourceIndex.integerValue;
    NSInteger dstIdx = self.dropTargetIndex;

    if (srcIdx < 0 || srcIdx >= (NSInteger)self.stackView.arrangedSubviews.count) return NO;
    if (dstIdx < 0) dstIdx = 0;
    if (dstIdx > (NSInteger)self.stackView.arrangedSubviews.count) {
        dstIdx = self.stackView.arrangedSubviews.count;
    }

    // Reorder in stack view
    NSView *view = self.stackView.arrangedSubviews[srcIdx];
    [self.stackView removeArrangedSubview:view];

    if (dstIdx > srcIdx) dstIdx--;
    if (dstIdx < 0) dstIdx = 0;

    [self.stackView insertArrangedSubview:view atIndex:dstIdx];

    // Update current order
    [self updateOrderFromStackView];

    self.dropTargetIndex = -1;
    [self setNeedsDisplay:YES];

    [self.delegate controlsViewDidChangeButtonOrder:self];

    return YES;
}

- (void)updateOrderFromStackView {
    [self.currentOrder removeAllObjects];
    for (NSView *view in self.stackView.arrangedSubviews) {
        NSInteger idx = [self.buttonViews indexOfObject:view];
        if (idx != NSNotFound) {
            [self.currentOrder addObject:@(idx)];
        }
    }
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    // Draw drop indicator in editing mode
    if (self.isEditingMode && self.dropTargetIndex >= 0) {
        [[NSColor controlAccentColor] setFill];

        CGFloat x = 8;
        if (self.dropTargetIndex < (NSInteger)self.stackView.arrangedSubviews.count) {
            NSView *targetView = self.stackView.arrangedSubviews[self.dropTargetIndex];
            x = NSMinX(targetView.frame) - 2;
        } else if (self.stackView.arrangedSubviews.count > 0) {
            NSView *lastView = self.stackView.arrangedSubviews.lastObject;
            x = NSMaxX(lastView.frame) + 2;
        }

        NSRect indicator = NSMakeRect(x, 4, 3, self.bounds.size.height - 8);
        [[NSBezierPath bezierPathWithRoundedRect:indicator xRadius:1.5 yRadius:1.5] fill];
    }
}

#pragma mark - TrackInfoViewDelegate

- (void)trackInfoViewDidClick:(TrackInfoView *)view {
    [self.delegate controlsViewDidTapTrackInfo:self];
}

#pragma mark - VolumeSliderViewDelegate

- (void)volumeSliderView:(VolumeSliderView *)view didChangeVolume:(float)volumeDB {
    [self.delegate controlsView:self didChangeVolume:volumeDB];
}

@end
