//
//  VectorscopeController.mm
//  foo_jl_vectorscope_mac
//

#import "VectorscopeController.h"
#include "../Core/StereoAnalysis.h"
#include "../Core/VectorscopeConfig.h"
#include "../Integration/ScopeSource.h"
#include <memory>
#include <vector>
#include <mutex>
#include <atomic>
#include <algorithm>
#include <cmath>

@interface VectorscopeController () {
    std::unique_ptr<ScopeSource> _source;
    std::unique_ptr<stereo::StereoAnalyzer> _analyzer;
    std::vector<float> _lr;   // interleaved L/R pulled this frame
    std::vector<float> _xy;   // its goniometer points
    CFTimeInterval _lastTick;
    NSTimer *_timer;
    NSVisualEffectView *_glassEffectView;
}
@property (nonatomic, readwrite) VectorscopeView *scopeView;
- (void)shutdownForQuit;
@end

// Registry of live controllers so we can release visualisation streams before
// the core tears down the vis backend at quit. Holding an open stream during
// component shutdown triggers exception_service_not_found.
namespace {
    std::mutex g_controllersMutex;
    std::vector<__weak VectorscopeController*> g_controllers;
    std::atomic<bool> g_shutdown{false};

    void registerController(VectorscopeController* c) {
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        g_controllers.push_back(c);
    }
    void unregisterController(VectorscopeController* c) {
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        g_controllers.erase(std::remove_if(g_controllers.begin(), g_controllers.end(),
            [c](__weak VectorscopeController* w){ return w == nil || w == c; }),
            g_controllers.end());
    }
}

// Release streams and stop timers before the service system shuts down.
class vectorscope_initquit : public initquit {
public:
    void on_quit() override {
        g_shutdown.store(true);
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (__weak VectorscopeController* w : g_controllers) {
            VectorscopeController* c = w;
            if (c) [c shutdownForQuit];
        }
    }
};
FB2K_SERVICE_FACTORY(vectorscope_initquit);

@implementation VectorscopeController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _source = std::make_unique<ScopeSource>();
        _analyzer = std::make_unique<stereo::StereoAnalyzer>();
    }
    return self;
}

- (void)loadView {
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 260)];
    container.wantsLayer = YES;
    container.layer.cornerRadius = 6.0;
    container.layer.masksToBounds = YES;

    VectorscopeView *view = [[VectorscopeView alloc] initWithFrame:container.bounds];
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    view.delegate = self;
    self.scopeView = view;

    [container addSubview:view];
    self.view = container;

    [self updateGlassBackground];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [self.view.widthAnchor constraintGreaterThanOrEqualToConstant:60],
        [self.view.heightAnchor constraintGreaterThanOrEqualToConstant:60]
    ]];

    [self applySettings];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleSettingsChanged:)
                                                 name:vectorscope_config::kSettingsChangedNotification
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
    _source->suspend();
    [self.scopeView clearTrace];
}

- (void)shutdownForQuit {
    [self stopTimer];
    if (_source) _source->suspend();
}

- (void)dealloc {
    [self stopTimer];
    unregisterController(self);
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Settings

- (void)applySettings {
    using namespace vectorscope_config;
    [self.scopeView reloadSettings];

    stereo::StereoAnalyzer::Settings s;
    s.integrationSeconds = getConfigIntClamped(kKeyIntegrationMs, kDefaultIntegrationMs,
                                               kMinIntegrationMs, kMaxIntegrationMs) / 1000.0;
    // The band meters only run while their bars are on screen.
    s.multiband  = getConfigBool(kKeyShowCorrelation, kDefaultShowCorrelation) &&
                   getConfigInt(kKeyCorrelationMode, kDefaultCorrelationMode) == CorrelationBands;
    s.lowHz      = getConfigIntClamped(kKeyLowHz, kDefaultLowHz, kMinLowHz, kMaxLowHz);
    s.highHz     = getConfigIntClamped(kKeyHighHz, kDefaultHighHz, kMinHighHz, kMaxHighHz);
    s.autoGain   = getConfigBool(kKeyAutoGain, kDefaultAutoGain);
    s.manualGain = (float)std::pow(10.0, getConfigIntClamped(kKeyGainDb, kDefaultGainDb, 0, kMaxGainDb) / 20.0);
    _analyzer->configure(s);

    [self updateGlassBackground];
}

- (void)handleSettingsChanged:(NSNotification *)note {
    [self applySettings];
}

- (void)updateGlassBackground {
    using namespace vectorscope_config;
    BOOL glass = getConfigBool(kKeyGlassBackground, kDefaultGlassBackground);
    if (glass == (_glassEffectView != nil)) return;

    if (glass) {
        _glassEffectView = [[NSVisualEffectView alloc] initWithFrame:self.view.bounds];
        _glassEffectView.material = NSVisualEffectMaterialSidebar;
        _glassEffectView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        _glassEffectView.state = NSVisualEffectStateActive;
        _glassEffectView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self.view addSubview:_glassEffectView positioned:NSWindowBelow relativeTo:self.scopeView];
    } else {
        [_glassEffectView removeFromSuperview];
        _glassEffectView = nil;
    }
}

#pragma mark - Timer

- (void)startTimer {
    [self stopTimer];
    if (g_shutdown.load()) return;
    _lastTick = CACurrentMediaTime();
    __weak typeof(self) weakSelf = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0
                                             repeats:YES
                                               block:^(NSTimer *t) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { [t invalidate]; return; }
        [self tick];
    }];
    [[NSRunLoop currentRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)stopTimer {
    [_timer invalidate];
    _timer = nil;
}

- (void)tick {
    @autoreleasepool {
        if (g_shutdown.load()) { [self stopTimer]; return; }
        if (!self.view.window || self.view.isHiddenOrHasHiddenAncestor) return;

        // Real elapsed time drives the afterglow and meter decay, so a late
        // timer fire does not slow the fade. Capped so the first frame after
        // the window was hidden does not wipe everything at once.
        const CFTimeInterval now = CACurrentMediaTime();
        const double dt = std::min(std::max(now - _lastTick, 0.0), 0.1);
        _lastTick = now;

        double sampleRate = 0;
        const bool live = _source->pull(_lr, sampleRate);
        const size_t frames = live ? _lr.size() / 2 : 0;
        if (frames > 0) {
            _xy.resize(frames * 2);
            _analyzer->process(_lr.data(), frames, sampleRate, _xy.data());
        } else {
            _analyzer->idle(dt);
        }

        float bands[stereo::StereoAnalyzer::BandCount];
        BOOL bandsSilent[stereo::StereoAnalyzer::BandCount];
        for (int b = 0; b < stereo::StereoAnalyzer::BandCount; ++b) {
            bands[b] = _analyzer->bandCorrelation(b);
            bandsSilent[b] = _analyzer->bandSilent(b);
        }
        [self.scopeView setCorrelation:_analyzer->correlation()
                                silent:_analyzer->silent()
                                 bands:bands
                           bandsSilent:bandsSilent];
        [self.scopeView advanceTrace:(frames > 0 ? _xy.data() : NULL)
                               count:(NSInteger)frames
                          sampleRate:sampleRate
                           deltaTime:dt];
    }
}

#pragma mark - VectorscopeViewDelegate

- (void)vectorscopeViewRequestsContextMenu:(VectorscopeView *)view atPoint:(NSPoint)point {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Vectorscope"];
    NSMenuItem *prefs = [[NSMenuItem alloc] initWithTitle:@"Preferences..."
                                                   action:@selector(menuShowPreferences:)
                                            keyEquivalent:@""];
    prefs.target = self;
    [menu addItem:prefs];
    [menu popUpMenuPositioningItem:nil atLocation:point inView:view];
}

- (void)menuShowPreferences:(NSMenuItem *)sender {
    @try {
        auto uiControl = ui_control::get();
        if (uiControl.is_valid()) {
            uiControl->show_preferences(vectorscope_config::guid_preferences_page);
        }
    } @catch (...) {
        console::error("[Vectorscope] Failed to open preferences");
    }
}

@end
