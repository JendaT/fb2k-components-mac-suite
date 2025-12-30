//
//  VolumeSliderView.mm
//  foo_jl_playback_controls_ext
//
//  Volume slider implementation
//

#import "VolumeSliderView.h"

@interface VolumeSliderView ()

@property (nonatomic, strong) NSSlider *slider;
@property (nonatomic, strong) NSButton *muteButton;
@property (nonatomic, assign, readwrite) float volumeDB;
@property (nonatomic, assign) float previousVolumeDB;
@property (nonatomic, assign) BOOL isMuted;

@end

@implementation VolumeSliderView

- (instancetype)initWithOrientation:(VolumeSliderOrientation)orientation {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        _orientation = orientation;
        _volumeDB = 0.0f;
        _previousVolumeDB = 0.0f;
        _isMuted = NO;

        [self setupViews];
    }
    return self;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    return [self initWithOrientation:VolumeSliderOrientationHorizontal];
}

- (void)setupViews {
    // Create mute button
    self.muteButton = [NSButton buttonWithImage:[self volumeIconForDB:self.volumeDB]
                                         target:self
                                         action:@selector(muteButtonClicked:)];
    self.muteButton.bezelStyle = NSBezelStyleTexturedRounded;
    self.muteButton.bordered = NO;
    self.muteButton.translatesAutoresizingMaskIntoConstraints = NO;

    // Create slider
    self.slider = [[NSSlider alloc] init];
    self.slider.minValue = 0;
    self.slider.maxValue = 100;
    self.slider.doubleValue = [self sliderValueFromDB:self.volumeDB];
    self.slider.target = self;
    self.slider.action = @selector(sliderChanged:);
    self.slider.continuous = YES;
    self.slider.translatesAutoresizingMaskIntoConstraints = NO;

    if (self.orientation == VolumeSliderOrientationVertical) {
        self.slider.sliderType = NSSliderTypeLinear;
        self.slider.vertical = YES;
    }

    [self addSubview:self.muteButton];
    [self addSubview:self.slider];

    [self setupConstraints];
}

- (void)setupConstraints {
    if (self.orientation == VolumeSliderOrientationHorizontal) {
        [NSLayoutConstraint activateConstraints:@[
            // Mute button on the left
            [self.muteButton.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [self.muteButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [self.muteButton.widthAnchor constraintEqualToConstant:20],
            [self.muteButton.heightAnchor constraintEqualToConstant:20],

            // Slider fills the rest
            [self.slider.leadingAnchor constraintEqualToAnchor:self.muteButton.trailingAnchor constant:4],
            [self.slider.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [self.slider.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]
        ]];
    } else {
        [NSLayoutConstraint activateConstraints:@[
            // Mute button at the bottom
            [self.muteButton.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [self.muteButton.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [self.muteButton.widthAnchor constraintEqualToConstant:20],
            [self.muteButton.heightAnchor constraintEqualToConstant:20],

            // Slider fills the rest above
            [self.slider.topAnchor constraintEqualToAnchor:self.topAnchor],
            [self.slider.bottomAnchor constraintEqualToAnchor:self.muteButton.topAnchor constant:-4],
            [self.slider.centerXAnchor constraintEqualToAnchor:self.centerXAnchor]
        ]];
    }
}

#pragma mark - Volume Conversion

// Convert dB to slider value (0-100)
// foobar2000 uses 0 dB = max, -100 dB = mute
// We use a logarithmic-ish scale for better UX
- (double)sliderValueFromDB:(float)db {
    if (db <= -100) return 0;
    if (db >= 0) return 100;

    // Linear mapping for simplicity
    // -100 dB -> 0, 0 dB -> 100
    return 100.0 + db;
}

// Convert slider value (0-100) to dB
- (float)dbFromSliderValue:(double)value {
    if (value <= 0) return -100.0f;
    if (value >= 100) return 0.0f;

    // Linear mapping
    return (float)(value - 100.0);
}

#pragma mark - Icon Selection

- (NSImage *)volumeIconForDB:(float)db {
    NSString *symbolName;

    if (db <= -100 || self.isMuted) {
        symbolName = @"speaker.slash.fill";
    } else if (db < -50) {
        symbolName = @"speaker.fill";
    } else if (db < -20) {
        symbolName = @"speaker.wave.1.fill";
    } else if (db < -5) {
        symbolName = @"speaker.wave.2.fill";
    } else {
        symbolName = @"speaker.wave.3.fill";
    }

    return [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil];
}

#pragma mark - Actions

- (void)sliderChanged:(id)sender {
    float newDB = [self dbFromSliderValue:self.slider.doubleValue];
    self.volumeDB = newDB;
    self.isMuted = (newDB <= -100);

    [self updateMuteButtonIcon];
    [self.delegate volumeSliderView:self didChangeVolume:newDB];
}

- (void)muteButtonClicked:(id)sender {
    if (self.isMuted) {
        // Unmute - restore previous volume
        self.isMuted = NO;
        self.volumeDB = self.previousVolumeDB;
        self.slider.doubleValue = [self sliderValueFromDB:self.volumeDB];
        [self.delegate volumeSliderView:self didChangeVolume:self.volumeDB];
    } else {
        // Mute - save current volume and set to -100
        self.previousVolumeDB = self.volumeDB;
        self.isMuted = YES;
        self.volumeDB = -100.0f;
        self.slider.doubleValue = 0;
        [self.delegate volumeSliderView:self didChangeVolume:-100.0f];
    }

    [self updateMuteButtonIcon];
}

- (void)updateMuteButtonIcon {
    self.muteButton.image = [self volumeIconForDB:self.isMuted ? -100 : self.volumeDB];
}

#pragma mark - External Update

- (void)setVolumeDB:(float)volumeDB {
    _volumeDB = volumeDB;
    _isMuted = (volumeDB <= -100);

    self.slider.doubleValue = [self sliderValueFromDB:volumeDB];
    [self updateMuteButtonIcon];
}

- (void)setOrientation:(VolumeSliderOrientation)orientation {
    if (_orientation != orientation) {
        _orientation = orientation;

        // Remove old constraints and re-setup
        for (NSLayoutConstraint *constraint in self.constraints.copy) {
            [self removeConstraint:constraint];
        }

        self.slider.vertical = (orientation == VolumeSliderOrientationVertical);
        [self setupConstraints];
        [self setNeedsLayout:YES];
    }
}

#pragma mark - Tooltip

- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag
             point:(NSPoint)point userData:(void *)userData {
    if (self.isMuted) {
        return @"Muted";
    }
    return [NSString stringWithFormat:@"%.1f dB", self.volumeDB];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];

    // Add tooltip to slider
    if (self.window) {
        [self.slider setToolTip:[NSString stringWithFormat:@"%.1f dB", self.volumeDB]];
    }
}

@end
