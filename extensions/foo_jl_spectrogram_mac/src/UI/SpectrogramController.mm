//
//  SpectrogramController.mm
//  foo_jl_spectrogram_mac
//

#import "SpectrogramController.h"
#include "../Core/SpectrogramConfig.h"
#include "../Core/SpectrogramClock.h"
#include "../Core/SpectrogramEngine.h"
#include "../Integration/SpectrogramSource.h"
#include <memory>
#include <vector>
#include <mutex>
#include <atomic>
#include <algorithm>
#import <QuartzCore/QuartzCore.h>

namespace {
    // Shortest time between ticks. On fast displays this takes every second (or
    // third) refresh, an even cadence of 60-90 fps instead of drawing at up to 240 Hz.
    const CFTimeInterval kMinTickInterval = 0.0105;
}

@interface SpectrogramController () {
    std::unique_ptr<SpectrogramEngine> _engine;
    std::unique_ptr<SpectrogramSource> _source;
    std::vector<float> _samples;
    std::vector<float> _levels;
    id _displayLink;         // CADisplayLink (macOS 14+); otherwise _timer drives ticks
    NSTimer *_timer;
    CFTimeInterval _lastTick; // time of the previous tick, 0 before the first

    int    _channel;
    int    _scrollSpeed;     // points per second
    bool   _frozen;
    SpectrogramClock _clock;
}
@property (nonatomic, readwrite) SpectrogramView *spectrogramView;
- (void)shutdownForQuit;
- (void)displayLinkFired:(CADisplayLink *)link API_AVAILABLE(macos(14.0));
@end

// CADisplayLink retains its target; this weak trampoline keeps the link from
// holding the controller alive.
API_AVAILABLE(macos(14.0))
@interface SpectrogramDisplayLinkTarget : NSObject
@property (nonatomic, weak) SpectrogramController *controller;
- (void)displayLinkFired:(CADisplayLink *)link;
@end

@implementation SpectrogramDisplayLinkTarget
- (void)displayLinkFired:(CADisplayLink *)link {
    [self.controller displayLinkFired:link];
}
@end

// Registry of live controllers so we can release visualisation streams before
// the core tears down the vis backend at quit. Holding an open stream during
// component shutdown triggers exception_service_not_found.
namespace {
    std::mutex g_controllersMutex;
    std::vector<__weak SpectrogramController*> g_controllers;
    std::atomic<bool> g_shutdown{false};

    void registerController(SpectrogramController* c) {
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        g_controllers.push_back(c);
    }
    void unregisterController(SpectrogramController* c) {
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        g_controllers.erase(std::remove_if(g_controllers.begin(), g_controllers.end(),
            [c](__weak SpectrogramController* w){ return w == nil || w == c; }),
            g_controllers.end());
    }
}

// Release streams and stop timers before the service system shuts down.
class spectrogram_initquit : public initquit {
public:
    void on_quit() override {
        g_shutdown.store(true);
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (__weak SpectrogramController* w : g_controllers) {
            SpectrogramController* c = w;
            if (c) [c shutdownForQuit];
        }
    }
};
FB2K_SERVICE_FACTORY(spectrogram_initquit);

@implementation SpectrogramController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _engine = std::make_unique<SpectrogramEngine>();
        _source = std::make_unique<SpectrogramSource>();
    }
    return self;
}

- (void)loadView {
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 200)];
    container.wantsLayer = YES;
    container.layer.cornerRadius = 6.0;
    container.layer.masksToBounds = YES;

    SpectrogramView *view = [[SpectrogramView alloc] initWithFrame:container.bounds];
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    view.delegate = self;
    self.spectrogramView = view;

    [container addSubview:view];
    self.view = container;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [self.view.widthAnchor constraintGreaterThanOrEqualToConstant:80],
        [self.view.heightAnchor constraintGreaterThanOrEqualToConstant:40]
    ]];

    [self applySettings];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleSettingsChanged:)
                                                 name:spectrogram_config::kSettingsChangedNotification
                                               object:nil];

    registerController(self);

    // Start now as well: appearance callbacks are not guaranteed for a view
    // hosted inside the foobar2000 layout. tick guards on window visibility.
    [self startTimer];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    [self startTimer];
}

- (void)viewDidDisappear {
    [super viewDidDisappear];
    [self stopTimer];
    [self suspendSource];
}

- (void)shutdownForQuit {
    [self stopTimer];
    [self suspendSource];
}

- (void)suspendSource {
    if (_source) _source->suspend();
    _clock.reset();
}

- (void)dealloc {
    [self stopTimer];
    unregisterController(self);
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Settings

- (void)applySettings {
    using namespace spectrogram_config;
    [self.spectrogramView reloadSettings];

    SpectrogramEngine::Settings s;
    s.fftSize  = (int)getConfigInt(kKeyFftSize, kDefaultFftSize);
    s.mode     = (int)getConfigInt(kKeyAnalysisMode, kDefaultAnalysisMode);
    s.window   = (int)getConfigInt(kKeyWindow, kDefaultWindow);
    s.scale    = (int)getConfigInt(kKeyFreqScale, kDefaultFreqScale);
    s.minHz    = (double)getConfigInt(kKeyMinHz, kDefaultMinHz);
    s.maxHz    = (double)getConfigInt(kKeyMaxHz, kDefaultMaxHz);
    s.topDb    = (float)getConfigInt(kKeyTopDb, kDefaultTopDb);
    s.rangeDb  = (float)getConfigInt(kKeyRangeDb, kDefaultRangeDb);
    s.slopeDb  = (float)getConfigInt(kKeySlopeTenths, kDefaultSlopeTenths) / 10.0f;
    _engine->configure(s);

    _channel = (int)getConfigInt(kKeyChannel, kDefaultChannel);
    _scrollSpeed = (int)std::max<int64_t>(10, std::min<int64_t>(getConfigInt(kKeyScrollSpeed, kDefaultScrollSpeed), 480));
}

- (void)handleSettingsChanged:(NSNotification *)note {
    [self applySettings];
}

#pragma mark - Timer

- (void)startTimer {
    [self stopTimer];
    if (g_shutdown.load()) return;
    _lastTick = 0;

    // A display link fires in step with the screen's refresh, so each displayed
    // frame moves the picture by the same amount. A free-running timer drifts
    // against the refresh and shows repeated and skipped frames.
    if (@available(macOS 14.0, *)) {
        // The link belongs to the view's screen; with no window yet,
        // spectrogramViewDidMoveToWindow: starts it later.
        if (!self.spectrogramView.window) return;
        SpectrogramDisplayLinkTarget *target = [[SpectrogramDisplayLinkTarget alloc] init];
        target.controller = self;
        CADisplayLink *link = [self.spectrogramView displayLinkWithTarget:target
                                                                 selector:@selector(displayLinkFired:)];
        link.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 60);
        [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        _displayLink = link;
        return;
    }

    __weak typeof(self) weakSelf = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0
                                             repeats:YES
                                               block:^(NSTimer *t) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { [t invalidate]; return; }
        [self tickAt:CACurrentMediaTime()];
    }];
    [[NSRunLoop currentRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)stopTimer {
    [_displayLink invalidate];
    _displayLink = nil;
    [_timer invalidate];
    _timer = nil;
}

- (void)displayLinkFired:(CADisplayLink *)link {
    const CFTimeInterval now = link.timestamp;
    if (_lastTick > 0 && now - _lastTick < kMinTickInterval) return;
    [self tickAt:now];
}

// Whether the core is playing and not paused. The stream time alone cannot
// tell a pause from a gap in its updates.
static bool playbackRunning() {
    try {
        auto pc = playback_control::get();
        return pc->is_playing() && !pc->is_paused();
    } catch (...) {
        return false;
    }
}

// Columns sit on a fixed time grid (one per device pixel of travel). Each tick
// renders the grid points SpectrogramClock says the display has passed.
- (void)tickAt:(CFTimeInterval)host {
    @autoreleasepool {
        if (g_shutdown.load()) { [self stopTimer]; return; }
        _lastTick = host;

        NSWindow *window = self.view.window;
        if (!window || self.view.isHiddenOrHasHiddenAncestor) return;
        // Skip fully covered windows, e.g. the panel while full screen is up.
        if (!(window.occlusionState & NSWindowOcclusionStateVisible)) {
            _clock.reset();
            return;
        }

        SpectrogramView *view = self.spectrogramView;
        const NSInteger rows = [view plotRows];
        if (_frozen || rows <= 0 || !playbackRunning()) {
            _clock.reset();
            return;
        }

        double streamTime = 0;
        const bool haveStreamTime = _source->now(streamTime);
        const double hop = 1.0 / (_scrollSpeed * [view columnsPerPoint]);
        const int due = _clock.due(host, haveStreamTime, streamTime, hop);

        _engine->setRows((int)rows);
        _levels.resize((size_t)rows);

        int produced = 0;
        bool retried = false;
        while (produced < due) {
            const double time = _clock.next(hop);
            _engine->setSampleRate(_source->sampleRate());
            if (!_source->read(time, _engine->windowLength(), _channel, _samples)) {
                // A new sample rate changes the window length: read again.
                // Otherwise the audio is not there yet; pick up next tick.
                if (!retried && _source->sampleRate() != _engine->sampleRate()) {
                    retried = true;
                    continue;
                }
                break;
            }
            _engine->renderColumn(_samples.data(), _levels.data());
            [view appendColumn:_levels.data() rows:rows];
            _clock.advance(hop);
            produced++;
        }
        // Every frame, so the sub-column phase keeps the picture moving evenly.
        [view flushWithPhase:_clock.phase(hop)];
    }
}

#pragma mark - SpectrogramViewDelegate

- (void)spectrogramViewDidMoveToWindow:(SpectrogramView *)view {
    // A display link is tied to its window's screen: make a new one.
    if (view.window) [self startTimer];
    else [self stopTimer];
}

- (void)spectrogramViewRequestsContextMenu:(SpectrogramView *)view atPoint:(NSPoint)point {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Spectrogram"];

    NSMenuItem *freeze = [[NSMenuItem alloc] initWithTitle:@"Freeze"
                                                    action:@selector(menuToggleFreeze:)
                                             keyEquivalent:@""];
    freeze.target = self;
    freeze.state = _frozen ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:freeze];

    NSMenuItem *clear = [[NSMenuItem alloc] initWithTitle:@"Clear"
                                                   action:@selector(menuClear:)
                                            keyEquivalent:@""];
    clear.target = self;
    [menu addItem:clear];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *prefs = [[NSMenuItem alloc] initWithTitle:@"Preferences..."
                                                   action:@selector(menuShowPreferences:)
                                            keyEquivalent:@""];
    prefs.target = self;
    [menu addItem:prefs];
    [menu popUpMenuPositioningItem:nil atLocation:point inView:view];
}

- (void)menuToggleFreeze:(NSMenuItem *)sender {
    _frozen = !_frozen;
}

- (void)menuClear:(NSMenuItem *)sender {
    [self.spectrogramView clear];
}

- (void)menuShowPreferences:(NSMenuItem *)sender {
    @try {
        auto uiControl = ui_control::get();
        if (uiControl.is_valid()) {
            uiControl->show_preferences(spectrogram_config::guid_preferences_page);
        }
    } @catch (...) {
        console::error("[Spectrogram] Failed to open preferences");
    }
}

@end
