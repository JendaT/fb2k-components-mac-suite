//
//  WaveformSeekbarController.mm
//  foo_wave_seekbar_mac
//
//  View controller for the waveform seekbar UI element
//

#import "WaveformSeekbarController.h"
#import "WaveformSeekbarView.h"
#import "../Integration/PlaybackCallback.h"
#import "../Core/WaveformService.h"
#import "../Core/WaveformData.h"
#import "../Core/ConfigHelper.h"
#import "../Core/WaveformConfig.h"
#include <memory>

@interface WaveformSeekbarController () {
    metadb_handle_ptr _currentTrack;
    NSTimer *_positionTimer;
    BOOL _isPaused;
    std::unique_ptr<WaveformData> _storedWaveform;  // We own this copy
    NSLayoutConstraint *_widthConstraint;           // Current width constraint
    NSLayoutConstraint *_heightConstraint;          // Current height constraint
    BOOL _widthLocked;                              // Track if width is locked
    BOOL _heightLocked;                             // Track if height is locked
    ListenerId _waveformListenerId;                 // For safe listener removal
    NSVisualEffectView *_glassEffectView;           // Blur background when glass mode is on
}

@property (nonatomic, readwrite) WaveformSeekbarView *waveformView;

@end

@implementation WaveformSeekbarController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _isPaused = NO;
    }
    return self;
}

- (void)loadView {
    // Container hosts an optional blur view behind the waveform (glass mode)
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 80)];
    container.wantsLayer = YES;
    container.layer.cornerRadius = 6.0;
    container.layer.masksToBounds = YES;

    // Create the waveform view programmatically
    WaveformSeekbarView *view = [[WaveformSeekbarView alloc] initWithFrame:container.bounds];
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    view.delegate = self;  // Set delegate for context menu events
    self.waveformView = view;

    [container addSubview:view];
    self.view = container;

    [self updateGlassBackground];
}

- (void)updateGlassBackground {
    using namespace waveform_config;
    BOOL glass = getConfigBool(kKeyGlassBackground, kDefaultGlassBackground);
    if (glass == (_glassEffectView != nil)) return;

    if (glass) {
        _glassEffectView = [[NSVisualEffectView alloc] initWithFrame:self.view.bounds];
        _glassEffectView.material = NSVisualEffectMaterialSidebar;
        _glassEffectView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        _glassEffectView.state = NSVisualEffectStateActive;
        _glassEffectView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self.view addSubview:_glassEffectView positioned:NSWindowBelow relativeTo:self.waveformView];
    } else {
        [_glassEffectView removeFromSuperview];
        _glassEffectView = nil;
    }
}

- (void)handleSettingsChanged:(NSNotification *)notification {
    [self updateGlassBackground];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // Minimum size for the UI element
    self.view.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [self.view.widthAnchor constraintGreaterThanOrEqualToConstant:100],
        [self.view.heightAnchor constraintGreaterThanOrEqualToConstant:40]
    ]];

    // Restore locked width if previously set
    using namespace waveform_config;
    if (getConfigBool(kKeyLockWidth, false)) {
        int64_t lockedWidth = getConfigInt(kKeyLockedWidth, 400);
        if (lockedWidth >= 100) {
            _widthLocked = YES;
            _widthConstraint = [self.view.widthAnchor constraintEqualToConstant:static_cast<CGFloat>(lockedWidth)];
            _widthConstraint.priority = NSLayoutPriorityRequired;
            _widthConstraint.active = YES;
            FB2K_console_formatter() << "[WaveSeek] Restored locked width: " << lockedWidth << " pixels";
        }
    }

    // Restore locked height if previously set
    if (getConfigBool(kKeyLockHeight, false)) {
        int64_t lockedHeight = getConfigInt(kKeyLockedHeight, 80);
        if (lockedHeight >= 40) {
            _heightLocked = YES;
            _heightConstraint = [self.view.heightAnchor constraintEqualToConstant:static_cast<CGFloat>(lockedHeight)];
            _heightConstraint.priority = NSLayoutPriorityRequired;
            _heightConstraint.active = YES;
            FB2K_console_formatter() << "[WaveSeek] Restored locked height: " << lockedHeight << " pixels";
        }
    }

    // Register for playback callbacks
    PlaybackCallbackManager::instance().registerController(self);

    // Observe settings changes for glass background toggle without restart
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleSettingsChanged:)
                                                 name:@"WaveformSeekbarSettingsChanged"
                                               object:nil];

    // Register for waveform ready notifications (store ID for safe removal)
    __weak typeof(self) weakSelf = self;
    _waveformListenerId = getWaveformService().addListener([weakSelf](const metadb_handle_ptr& track, const WaveformData* waveform) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // Check if this is the current track
        if (strongSelf->_currentTrack.is_valid() && track.is_valid() &&
            strongSelf->_currentTrack->get_location() == track->get_location()) {
            [strongSelf updateWaveformData:waveform];
        }
    });

    // Check if something is already playing
    [self syncWithCurrentPlayback];
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    [self stopPositionTimer];
}

- (void)dealloc {
    [self stopPositionTimer];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    PlaybackCallbackManager::instance().unregisterController(self);
    // Remove only our listener from the waveform service
    getWaveformService().removeListener(_waveformListenerId);
}

#pragma mark - Playback State Sync

- (void)syncWithCurrentPlayback {
    try {
        auto pc = playback_control::get();
        if (!pc.is_valid()) return;

        if (pc->is_playing()) {
            metadb_handle_ptr track;
            if (pc->get_now_playing(track) && track.is_valid()) {
                file_info_impl info;
                double duration = 0;
                double bpm = 0;
                if (track->get_info_async(info)) {
                    duration = info.get_length();
                    bpm = extractBpmFromInfo(info);
                }
                [self handleNewTrack:track duration:duration bpm:bpm];

                // Sync position
                double position = pc->playback_get_position();
                [self handlePlaybackTime:position];

                // Check if paused
                _isPaused = pc->is_paused();
                if (!_isPaused) {
                    [self startPositionTimer];
                }
            }
        }
    } catch (...) {
        // Ignore errors during sync
    }
}

#pragma mark - Playback Event Handlers

- (void)handleNewTrack:(metadb_handle_ptr)track duration:(double)duration bpm:(double)bpm {
    _currentTrack = track;
    _isPaused = NO;
    _storedWaveform.reset();  // Clear previous waveform

    self.waveformView.trackDuration = duration;
    self.waveformView.trackBpm = bpm;  // Set BPM for animation sync
    self.waveformView.playbackPosition = 0.0;
    self.waveformView.playing = YES;
    self.waveformView.waveformData = nil;
    self.waveformView.analyzing = YES;  // Show "Analyzing..." message

    [self.waveformView refreshDisplay];

    // Request waveform
    if (track.is_valid()) {
        getWaveformService().requestWaveform(track, nullptr);
    }

    // Start timer for smooth position updates
    [self startPositionTimer];
}

- (void)handlePlaybackStop {
    _currentTrack.release();
    _isPaused = NO;
    _storedWaveform.reset();  // Release stored waveform

    [self stopPositionTimer];

    self.waveformView.trackDuration = 0.0;
    self.waveformView.playbackPosition = 0.0;
    self.waveformView.playing = NO;
    self.waveformView.waveformData = nil;

    [self.waveformView refreshDisplay];
}

- (void)handleSeekToTime:(double)time {
    if (self.waveformView.trackDuration > 0) {
        self.waveformView.playbackPosition = time / self.waveformView.trackDuration;
        [self.waveformView refreshDisplay];
    }
}

- (void)handlePlaybackTime:(double)time {
    if (self.waveformView.trackDuration > 0) {
        self.waveformView.playbackPosition = time / self.waveformView.trackDuration;
        [self.waveformView refreshDisplay];
    }
}

- (void)handlePlaybackPause:(BOOL)paused {
    _isPaused = paused;
    self.waveformView.playing = !paused;

    if (paused) {
        [self stopPositionTimer];
    } else {
        [self startPositionTimer];
    }
}

#pragma mark - Waveform Data

- (void)updateWaveformData:(const WaveformData *)waveform {
    self.waveformView.analyzing = NO;  // Analysis complete

    if (!waveform || !waveform->isValid()) {
        _storedWaveform.reset();
        self.waveformView.waveformData = nil;
    } else {
        // Make a copy of the waveform data so it persists (we own this copy)
        _storedWaveform = std::make_unique<WaveformData>(*waveform);
        // Point view to our owned copy
        self.waveformView.waveformData = _storedWaveform.get();
    }

    [self.waveformView refreshDisplay];
}

#pragma mark - Position Timer

- (void)startPositionTimer {
    [self stopPositionTimer];

    // 60 FPS for smooth animation
    // Use block-based timer with weak self to avoid retain cycle
    __weak typeof(self) weakSelf = self;
    _positionTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/60.0
                                                     repeats:YES
                                                       block:^(NSTimer * _Nonnull timer) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            [timer invalidate];
            return;
        }
        [strongSelf updatePosition:timer];
    }];

    // Add to common run loop modes for smooth updates during UI interaction
    [[NSRunLoop currentRunLoop] addTimer:_positionTimer forMode:NSRunLoopCommonModes];
}

- (void)stopPositionTimer {
    [_positionTimer invalidate];
    _positionTimer = nil;
}

- (void)updatePosition:(NSTimer *)timer {
    @autoreleasepool {
        if (_isPaused) return;
        if (!self.view.window || self.view.isHiddenOrHasHiddenAncestor) return;

        try {
            auto pc = playback_control::get();
            if (pc.is_valid() && pc->is_playing() && !pc->is_paused()) {
                double position = pc->playback_get_position();
                if (self.waveformView.trackDuration > 0) {
                    double newPos = position / self.waveformView.trackDuration;

                    // Redraw once the cursor moves at least a quarter pixel
                    CGFloat viewWidth = self.waveformView.bounds.size.width;
                    double threshold = (viewWidth > 1.0) ? (0.25 / viewWidth) : 0.001;

                    // Animated cursor effects need continuous redraw to stay smooth
                    BOOL animatedEffect = NO;
                    if (self.waveformView.shadePlayedPortion && self.waveformView.playedDimming > 0) {
                        switch (self.waveformView.cursorEffect) {
                            case WaveformCursorEffectGlow:
                            case WaveformCursorEffectScanline:
                            case WaveformCursorEffectPulse:
                            case WaveformCursorEffectShimmer:
                                animatedEffect = YES;
                                break;
                            default:
                                break;
                        }
                    }

                    if (animatedEffect || fabs(newPos - self.waveformView.playbackPosition) > threshold) {
                        self.waveformView.playbackPosition = newPos;
                        [self.waveformView refreshDisplay];
                    }
                }
            }
        } catch (...) {
            // Ignore errors during timer update
        }
    }
}

#pragma mark - WaveformSeekbarViewDelegate

- (void)waveformSeekbarView:(WaveformSeekbarView *)view requestsSeekToTime:(double)time {
    try {
        auto pc = playback_control::get();
        if (pc.is_valid()) {
            pc->playback_seek(time);
        }
    } catch (const std::exception& e) {
        pfc::string_formatter msg;
        msg << "[WaveSeek] Seek error: " << e.what();
        console::error(msg.c_str());
    } catch (...) {
        console::error("[WaveSeek] Unknown seek error");
    }
}

- (void)waveformSeekbarViewRequestsContextMenu:(WaveformSeekbarView *)view atPoint:(NSPoint)point {
    FB2K_console_formatter() << "[WaveSeek] Context menu requested";

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Waveform Seekbar"];

    // Lock Width menu item
    NSMenuItem *lockWidthItem = [[NSMenuItem alloc]
        initWithTitle:@"Lock Width"
        action:@selector(menuToggleLockWidth:)
        keyEquivalent:@""];
    lockWidthItem.target = self;
    lockWidthItem.state = _widthLocked ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:lockWidthItem];

    // Lock Height menu item
    NSMenuItem *lockHeightItem = [[NSMenuItem alloc]
        initWithTitle:@"Lock Height"
        action:@selector(menuToggleLockHeight:)
        keyEquivalent:@""];
    lockHeightItem.target = self;
    lockHeightItem.state = _heightLocked ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:lockHeightItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // Preferences menu item
    NSMenuItem *preferencesItem = [[NSMenuItem alloc]
        initWithTitle:@"Preferences..."
        action:@selector(menuShowPreferences:)
        keyEquivalent:@""];
    preferencesItem.target = self;
    [menu addItem:preferencesItem];

    [menu popUpMenuPositioningItem:nil atLocation:point inView:view];
}

- (void)menuShowPreferences:(NSMenuItem *)sender {
    @try {
        auto uiControl = ui_control::get();
        if (uiControl.is_valid()) {
            uiControl->show_preferences(waveform_config::guid_preferences_page);
        }
    } @catch (...) {
        console::error("[WaveSeek] Failed to open preferences");
    }
}

- (void)menuToggleLockWidth:(NSMenuItem *)sender {
    using namespace waveform_config;

    _widthLocked = !_widthLocked;

    if (_widthLocked) {
        // Lock to current width
        CGFloat currentWidth = self.view.frame.size.width;

        // Remove existing width constraint if any
        if (_widthConstraint) {
            [self.view removeConstraint:_widthConstraint];
        }

        // Create exact width constraint
        _widthConstraint = [self.view.widthAnchor constraintEqualToConstant:currentWidth];
        _widthConstraint.priority = NSLayoutPriorityRequired;
        _widthConstraint.active = YES;

        // Save to config
        setConfigBool(kKeyLockWidth, YES);
        setConfigInt(kKeyLockedWidth, static_cast<int64_t>(currentWidth));

        FB2K_console_formatter() << "[WaveSeek] Width locked to " << static_cast<int>(currentWidth) << " pixels";
    } else {
        // Unlock - remove constraint
        if (_widthConstraint) {
            [self.view removeConstraint:_widthConstraint];
            _widthConstraint = nil;
        }

        // Save to config
        setConfigBool(kKeyLockWidth, NO);

        FB2K_console_formatter() << "[WaveSeek] Width unlocked";
    }
}

- (void)menuToggleLockHeight:(NSMenuItem *)sender {
    using namespace waveform_config;

    _heightLocked = !_heightLocked;

    if (_heightLocked) {
        // Lock to current height
        CGFloat currentHeight = self.view.frame.size.height;

        // Remove existing height constraint if any
        if (_heightConstraint) {
            [self.view removeConstraint:_heightConstraint];
        }

        // Create exact height constraint
        _heightConstraint = [self.view.heightAnchor constraintEqualToConstant:currentHeight];
        _heightConstraint.priority = NSLayoutPriorityRequired;
        _heightConstraint.active = YES;

        // Save to config
        setConfigBool(kKeyLockHeight, YES);
        setConfigInt(kKeyLockedHeight, static_cast<int64_t>(currentHeight));

        FB2K_console_formatter() << "[WaveSeek] Height locked to " << static_cast<int>(currentHeight) << " pixels";
    } else {
        // Unlock - remove constraint
        if (_heightConstraint) {
            [self.view removeConstraint:_heightConstraint];
            _heightConstraint = nil;
        }

        // Save to config
        setConfigBool(kKeyLockHeight, NO);

        FB2K_console_formatter() << "[WaveSeek] Height unlocked";
    }
}

@end
