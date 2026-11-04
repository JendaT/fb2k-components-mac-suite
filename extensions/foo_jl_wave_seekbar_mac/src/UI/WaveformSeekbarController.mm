//
//  WaveformSeekbarController.mm
//  foo_wave_seekbar_mac
//
//  View controller for the waveform seekbar UI element
//

#import "WaveformSeekbarController.h"
#include "../../../../shared/PixelSnap.h"
#import "WaveformSeekbarView.h"
#import "../Integration/PlaybackCallback.h"
#import "../Core/WaveformService.h"
#import "../Core/WaveformData.h"
#import "../Core/ConfigHelper.h"
#import "../Core/WaveformConfig.h"
#include "../Core/WaveformGeometry.h"
#include "../Core/PhraseMarkers.h"
#include "../../../../shared/jl_beatgrid_api.h"
#include <cmath>
#include <memory>

@class WaveformSeekbarController;

// BPM Analyzer stored a grid: forwarded to the controller on the main thread
class SeekbarGridNotify : public jl_beatgrid_notify {
public:
    __weak WaveformSeekbarController *owner = nil;
    void on_ready(const metadb_handle_ptr &item) override;
};

@interface WaveformSeekbarController () {
    metadb_handle_ptr _currentTrack;
    NSTimer *_positionTimer;
    BOOL _isPaused;
    std::unique_ptr<WaveformData> _storedWaveform;  // We own this copy
    std::shared_ptr<const WaveformDetail> _detail;  // Its fine detail for deep zoom, when there is one
    ListenerId _detailListenerId;
    jl_beatgrid::ptr _grids;                        // BPM Analyzer's beat grids; null when not installed
    service_ptr_t<SeekbarGridNotify> _gridNotify;
    std::shared_ptr<waveseek::PhraseGrid> _phraseGrid;   // the current track's, for phrase markers
    NSLayoutConstraint *_widthConstraint;           // Current width constraint
    NSLayoutConstraint *_heightConstraint;          // Current height constraint
    BOOL _widthLocked;                              // Track if width is locked
    BOOL _heightLocked;                             // Track if height is locked
    ListenerId _waveformListenerId;                 // For safe listener removal
    NSVisualEffectView *_glassEffectView;           // Blur background when glass mode is on
    __weak NSWindow *_observedWindow;               // whose screen changes resize a locked width or height
    NSTimer *_analysisWatchdog;                     // Breaks a stuck "Analyzing..." state
    int _analysisRetries;                           // Re-requests already spent on this track
}

@property (nonatomic, readwrite) WaveformSeekbarView *waveformView;
- (void)beatgridReady:(const metadb_handle_ptr &)item;

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
    [self applyLockedSize];   // following the screen switched on or off
    // Phrase markers or beat-synced animation switched on or off
    if (![self wantsBeatGrid]) [self dropPhraseGrid];
    else if (!_phraseGrid) [self fetchPhraseGrid];
    // The fine detail switched on or off
    if (!WaveformService::detailEnabled()) {
        [self dropDetail];
    } else if (!_detail && _storedWaveform && _currentTrack.is_valid()) {
        getWaveformService().requestDetail(_currentTrack);
    }
}

#pragma mark - Beat Grid

// The grid is wanted for phrase markers, beat jumps and loops, and for
// animated cursor effects synced to the beat
- (BOOL)wantsBeatGrid {
    using namespace waveform_config;
    if (getConfigBool(kKeyPhraseMarkers, kDefaultPhraseMarkers)) return YES;
    if (getConfigInt(kKeyControlsMode, kDefaultControlsMode) == ControlsMixer) return YES;
    if (!getConfigBool(kKeyBpmSync, kDefaultBpmSync) || !getConfigBool(kKeyShadePlayedPortion, kDefaultShadePlayedPortion)) {
        return NO;
    }
    const int64_t effect = getConfigInt(kKeyCursorEffect, kDefaultCursorEffect);
    return effect == CursorEffectGlow || effect == CursorEffectScanline || effect == CursorEffectPulse ||
           effect == CursorEffectShimmer;
}

// The current track's grid from BPM Analyzer when it is wanted:
// fetched when stored, else asked for (urgent: it is playing). Called once
// the seekbar's own scan of the track is done, so the decodes don't compete.
- (void)fetchPhraseGrid {
    if (!_grids.is_valid() || !_currentTrack.is_valid() || !_storedWaveform || ![self wantsBeatGrid]) return;
    switch (_grids->get_status(_currentTrack)) {
        case jl_beatgrid::ready: {
            auto grid = std::make_shared<waveseek::PhraseGrid>();
            pfc::array_t<jl_beat_region> regions;
            pfc::array_t<jl_bar_stat> bars;
            if (!_grids->get(_currentTrack, grid->summary, regions, bars)) return;
            grid->regions.assign(regions.get_ptr(), regions.get_ptr() + regions.get_size());
            grid->bars.assign(bars.get_ptr(), bars.get_ptr() + bars.get_size());
            // Section by section, for markers that follow a new grid
            pfc::array_t<jl_grid_section> sections;
            pfc::array_t<jl_bar_stat> sectionBars;
            if (_grids->get_sections(_currentTrack, sections, sectionBars)) {
                grid->sections.assign(sections.get_ptr(), sections.get_ptr() + sections.get_size());
                grid->sectionBars.assign(sectionBars.get_ptr(), sectionBars.get_ptr() + sectionBars.get_size());
            }
            // The view takes the new grid before the old one is released
            self.waveformView.phraseGrid = grid.get();
            _phraseGrid = grid;
            break;
        }
        case jl_beatgrid::not_analysed:
            _grids->request(_currentTrack, true);
            break;
        default:   // queued or analysing: on_ready follows; unavailable: no markers
            break;
    }
}

- (void)beatgridReady:(const metadb_handle_ptr &)item {
    if (_currentTrack.is_valid() && item.is_valid() && _currentTrack->get_location() == item->get_location()) {
        [self fetchPhraseGrid];
    }
}

- (void)dropPhraseGrid {
    self.waveformView.phraseGrid = nullptr;
    _phraseGrid.reset();
}

// The view stops pointing at the detail before it is released
- (void)dropDetail {
    if (!_detail) return;
    self.waveformView.waveformDetail = nullptr;
    _detail.reset();
    [self.waveformView refreshDisplay];
}

// The host may place the panel between pixels; keep the drawing on whole ones.
- (void)viewDidLayout {
    [super viewDidLayout];
    JLPixelSnapContent(self.view, self.waveformView);
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // Minimum size for the UI element
    self.view.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [self.view.widthAnchor constraintGreaterThanOrEqualToConstant:100],
        [self.view.heightAnchor constraintGreaterThanOrEqualToConstant:40]
    ]];

    // Restore a locked width and height (sized for the screen once the view
    // is in a window)
    using namespace waveform_config;
    if (getConfigBool(kKeyLockWidth, false) && getConfigInt(kKeyLockedWidth, 400) >= kMinLockedWidth) {
        _widthLocked = YES;
        _widthConstraint = [self.view.widthAnchor constraintEqualToConstant:[self lockedLength:YES]];
        _widthConstraint.priority = NSLayoutPriorityRequired;
        _widthConstraint.active = YES;
    }
    if (getConfigBool(kKeyLockHeight, false) && getConfigInt(kKeyLockedHeight, 80) >= kMinLockedHeight) {
        _heightLocked = YES;
        _heightConstraint = [self.view.heightAnchor constraintEqualToConstant:[self lockedLength:NO]];
        _heightConstraint.priority = NSLayoutPriorityRequired;
        _heightConstraint.active = YES;
    }
    // Another display, or its resolution changed
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(screenChanged:)
                                                 name:NSApplicationDidChangeScreenParametersNotification object:nil];

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

    // BPM Analyzer's beat grids, when it is installed
    if (fb2k::std_api_try_get(_grids)) {
        _gridNotify = fb2k::service_new<SeekbarGridNotify>();
        _gridNotify->owner = self;
        _grids->add_notify(_gridNotify);
    }

    // Fine detail for deep zoom, which may come before or after the waveform
    _detailListenerId = getWaveformService().addDetailListener(
        [weakSelf](const metadb_handle_ptr& track, std::shared_ptr<const WaveformDetail> detail) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !detail || !WaveformService::detailEnabled()) return;
            if (strongSelf->_currentTrack.is_valid() && track.is_valid() &&
                strongSelf->_currentTrack->get_location() == track->get_location()) {
                // The view takes the new detail before the old one is released
                strongSelf.waveformView.waveformDetail = detail.get();
                strongSelf->_detail = detail;
                [strongSelf.waveformView refreshDisplay];
            }
        });

    // Check if something is already playing
    [self syncWithCurrentPlayback];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    // The window's screen sizes a locked width or height
    if (self.view.window != _observedWindow) {
        if (_observedWindow) {
            [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidChangeScreenNotification
                                                          object:_observedWindow];
        }
        _observedWindow = self.view.window;
        if (_observedWindow) {
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(screenChanged:)
                                                         name:NSWindowDidChangeScreenNotification object:_observedWindow];
        }
    }
    [self applyLockedSize];

    // A layout change tears this element down and builds a fresh one. If the
    // scan for the current track was already in flight, its result went to the
    // controller that requested it, so this instance would sit on "Analyzing..."
    // until the next track. Re-request whenever we appear without a waveform.
    if (!_storedWaveform && !_currentTrack.is_valid()) {
        [self syncWithCurrentPlayback];
    } else if (!_storedWaveform && _currentTrack.is_valid()) {
        getWaveformService().requestWaveform(_currentTrack, nullptr);
        [self startAnalysisWatchdog];
    }
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    [self stopPositionTimer];
}

- (void)dealloc {
    [self stopPositionTimer];
    [self stopAnalysisWatchdog];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    PlaybackCallbackManager::instance().unregisterController(self);
    // Remove only our listeners from the waveform service
    getWaveformService().removeListener(_waveformListenerId);
    getWaveformService().removeDetailListener(_detailListenerId);
    if (_grids.is_valid() && _gridNotify.is_valid()) _grids->remove_notify(_gridNotify);
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
    [self dropDetail];
    [self dropPhraseGrid];
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
        _analysisRetries = 0;
        getWaveformService().requestWaveform(track, nullptr);
        [self startAnalysisWatchdog];
    }

    // Start timer for smooth position updates
    [self startPositionTimer];
}

- (void)handlePlaybackStop {
    [self dropDetail];
    [self dropPhraseGrid];
    _currentTrack.release();
    _isPaused = NO;
    _storedWaveform.reset();  // Release stored waveform

    [self stopPositionTimer];
    [self stopAnalysisWatchdog];

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
    [self stopAnalysisWatchdog];

    if (!waveform || !waveform->isValid()) {
        _storedWaveform.reset();
        self.waveformView.waveformData = nil;
    } else {
        // Make a copy of the waveform data so it persists (we own this copy)
        _storedWaveform = std::make_unique<WaveformData>(*waveform);
        // Point view to our owned copy
        self.waveformView.waveformData = _storedWaveform.get();
        if (!_detail && _currentTrack.is_valid() && WaveformService::detailEnabled()) {
            getWaveformService().requestDetail(_currentTrack);
        }
        if (!_phraseGrid) [self fetchPhraseGrid];
    }

    [self.waveformView refreshDisplay];
}

#pragma mark - Analysis Watchdog

// How long to wait for a result before checking whether it was lost (no scan
// running for the track). A scan still running is waited for: a long stream
// downloads as it decodes and can take minutes.
static const NSTimeInterval kAnalysisTimeout = 30.0;
static const int kAnalysisMaxRetries = 1;

- (void)startAnalysisWatchdog {
    [self stopAnalysisWatchdog];

    __weak typeof(self) weakSelf = self;
    _analysisWatchdog = [NSTimer scheduledTimerWithTimeInterval:kAnalysisTimeout
                                                        repeats:NO
                                                          block:^(NSTimer * _Nonnull timer) {
        [weakSelf handleAnalysisTimeout];
    }];
}

- (void)stopAnalysisWatchdog {
    [_analysisWatchdog invalidate];
    _analysisWatchdog = nil;
}

- (void)handleAnalysisTimeout {
    _analysisWatchdog = nil;

    if (!self.waveformView.analyzing) return;

    if (_currentTrack.is_valid() && getWaveformService().isScanning(_currentTrack)) {
        [self startAnalysisWatchdog];
        return;
    }

    if (_currentTrack.is_valid() && _analysisRetries < kAnalysisMaxRetries) {
        _analysisRetries++;
        FB2K_console_formatter() << "[WaveSeek] Analysis timed out, re-requesting waveform";
        getWaveformService().requestWaveform(_currentTrack, nullptr);
        [self startAnalysisWatchdog];
        return;
    }

    // Give up rather than latch on "Analyzing..." indefinitely
    FB2K_console_formatter() << "[WaveSeek] Analysis timed out, giving up on this track";
    [self updateWaveformData:nullptr];
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
        // On whole device pixels while in sight (a beat loop below runs either way)
        if (self.view.window && !self.view.isHiddenOrHasHiddenAncestor) {
            JLPixelSnapContent(self.view, self.waveformView);
        }

        try {
            auto pc = playback_control::get();
            if (pc.is_valid() && pc->is_playing() && !pc->is_paused()) {
                double position = pc->playback_get_position();
                // A beat loop keeps going while the view is out of sight
                [self.waveformView followLoopAt:position];
                if (!self.view.window || self.view.isHiddenOrHasHiddenAncestor) return;
                if (self.waveformView.trackDuration > 0) {
                    double newPos = position / self.waveformView.trackDuration;

                    // Redraw once the cursor moves at least a quarter pixel (of
                    // the zoomed waveform), or the time chip reaches the next second
                    CGFloat viewWidth = self.waveformView.bounds.size.width;
                    double threshold = waveseek::positionRedrawThreshold(viewWidth) / self.waveformView.zoomFactor;
                    const double oldTime = self.waveformView.playbackPosition * self.waveformView.trackDuration;
                    const bool nextSecond = self.waveformView.showCursorTime &&
                                            std::floor(position) != std::floor(oldTime);

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

                    if (animatedEffect || nextSecond || fabs(newPos - self.waveformView.playbackPosition) > threshold) {
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

- (double)waveformSeekbarViewPlaybackTime:(WaveformSeekbarView *)view {
    try {
        auto pc = playback_control::get();
        if (pc.is_valid() && pc->is_playing()) return pc->playback_get_position();
    } catch (...) {
    }
    return NAN;
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

#pragma mark - Locked Size

// A locked width or height: the points stored when it was locked, or while
// it follows the screen, the same share of the window's screen as then
- (CGFloat)lockedLength:(BOOL)width {
    using namespace waveform_config;
    const CGFloat minimum = width ? kMinLockedWidth : kMinLockedHeight;
    const int64_t points = getConfigInt(width ? kKeyLockedWidth : kKeyLockedHeight, width ? 400 : 80);
    NSScreen *screen = self.view.window.screen ?: NSScreen.mainScreen;
    if (!getConfigBool(kKeyLockRelative, kDefaultLockRelative) || !screen) return std::max<CGFloat>(minimum, points);
    const CGFloat screenLength = width ? screen.frame.size.width : screen.frame.size.height;
    if (!(screenLength > 0)) return std::max<CGFloat>(minimum, points);
    const char *shareKey = width ? kKeyLockedWidthShare : kKeyLockedHeightShare;
    int64_t share = getConfigInt(shareKey, 0);
    if (share <= 0) {   // locked before shares were kept: its share of this screen
        share = std::llround(points / screenLength * 1e6);
        setConfigInt(shareKey, share);
    }
    return std::max<CGFloat>(minimum, std::round(share / 1e6 * screenLength));
}

- (void)applyLockedSize {
    if (_widthLocked && _widthConstraint) _widthConstraint.constant = [self lockedLength:YES];
    if (_heightLocked && _heightConstraint) _heightConstraint.constant = [self lockedLength:NO];
}

- (void)screenChanged:(NSNotification *)notification {
    [self applyLockedSize];
}

// Locks to the current length, kept in points and as a share of the screen
- (void)lockLength:(BOOL)width {
    using namespace waveform_config;
    const CGFloat length = width ? self.view.frame.size.width : self.view.frame.size.height;
    NSLayoutConstraint *__strong &constraint = width ? _widthConstraint : _heightConstraint;
    if (constraint) constraint.active = NO;
    constraint = [width ? self.view.widthAnchor : self.view.heightAnchor constraintEqualToConstant:length];
    constraint.priority = NSLayoutPriorityRequired;
    constraint.active = YES;
    setConfigBool(width ? kKeyLockWidth : kKeyLockHeight, true);
    setConfigInt(width ? kKeyLockedWidth : kKeyLockedHeight, static_cast<int64_t>(length));
    NSScreen *screen = self.view.window.screen ?: NSScreen.mainScreen;
    const CGFloat screenLength = screen ? (width ? screen.frame.size.width : screen.frame.size.height) : 0;
    setConfigInt(width ? kKeyLockedWidthShare : kKeyLockedHeightShare,
                 screenLength > 0 ? std::llround(length / screenLength * 1e6) : 0);
}

- (void)unlockLength:(BOOL)width {
    using namespace waveform_config;
    NSLayoutConstraint *__strong &constraint = width ? _widthConstraint : _heightConstraint;
    if (constraint) constraint.active = NO;
    constraint = nil;
    setConfigBool(width ? kKeyLockWidth : kKeyLockHeight, false);
}

- (void)menuToggleLockWidth:(NSMenuItem *)sender {
    _widthLocked = !_widthLocked;
    if (_widthLocked) [self lockLength:YES];
    else [self unlockLength:YES];
}

- (void)menuToggleLockHeight:(NSMenuItem *)sender {
    _heightLocked = !_heightLocked;
    if (_heightLocked) [self lockLength:NO];
    else [self unlockLength:NO];
}

@end

void SeekbarGridNotify::on_ready(const metadb_handle_ptr &item) {
    WaveformSeekbarController *controller = owner;
    [controller beatgridReady:item];
}
