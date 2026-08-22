//
//  SpectrumController.mm
//  foo_jl_spectrum_mac
//

#import "SpectrumController.h"
#include "../Core/SpectrumAnalyzer.h"
#include "../Core/SpectrumConfig.h"
#include <memory>
#include <vector>
#include <mutex>
#include <atomic>
#include <algorithm>

@interface SpectrumController () {
    std::unique_ptr<SpectrumAnalyzer> _analyzer;
    NSTimer *_timer;
    NSVisualEffectView *_glassEffectView;
}
@property (nonatomic, readwrite) SpectrumView *spectrumView;
- (void)shutdownForQuit;
@end

// Registry of live controllers so we can release visualisation streams before
// the core tears down the vis backend at quit. Holding an open stream during
// component shutdown triggers exception_service_not_found.
namespace {
    std::mutex g_controllersMutex;
    std::vector<__weak SpectrumController*> g_controllers;
    std::atomic<bool> g_shutdown{false};

    void registerController(SpectrumController* c) {
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        g_controllers.push_back(c);
    }
    void unregisterController(SpectrumController* c) {
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        g_controllers.erase(std::remove_if(g_controllers.begin(), g_controllers.end(),
            [c](__weak SpectrumController* w){ return w == nil || w == c; }),
            g_controllers.end());
    }
}

// Release streams and stop timers before the service system shuts down.
class spectrum_initquit : public initquit {
public:
    void on_quit() override {
        g_shutdown.store(true);
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (__weak SpectrumController* w : g_controllers) {
            SpectrumController* c = w;
            if (c) [c shutdownForQuit];
        }
    }
};
FB2K_SERVICE_FACTORY(spectrum_initquit);

@implementation SpectrumController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _analyzer = std::make_unique<SpectrumAnalyzer>();
    }
    return self;
}

- (void)loadView {
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 120)];
    container.wantsLayer = YES;
    container.layer.cornerRadius = 6.0;
    container.layer.masksToBounds = YES;

    SpectrumView *view = [[SpectrumView alloc] initWithFrame:container.bounds];
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    view.delegate = self;
    self.spectrumView = view;

    [container addSubview:view];
    self.view = container;

    [self updateGlassBackground];
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
                                                 name:spectrum_config::kSettingsChangedNotification
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
    _analyzer->suspend();
}

- (void)shutdownForQuit {
    [self stopTimer];
    if (_analyzer) _analyzer->suspend();
}

- (void)dealloc {
    [self stopTimer];
    unregisterController(self);
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Settings

- (void)applySettings {
    using namespace spectrum_config;
    SpectrumAnalyzer::Settings s;
    s.barCount  = (int)getConfigInt(kKeyBarCount, kDefaultBarCount);
    s.fftSize   = (int)getConfigInt(kKeyFftSize, kDefaultFftSize);
    s.minHz     = (int)getConfigInt(kKeyMinHz, kDefaultMinHz);
    s.maxHz     = (int)getConfigInt(kKeyMaxHz, kDefaultMaxHz);
    s.smoothing = (int)getConfigInt(kKeySmoothing, kDefaultSmoothing);
    s.logScale  = getConfigInt(kKeyFreqScale, kDefaultFreqScale) == FreqScaleLog;
    s.peakHold  = getConfigBool(kKeyPeakHold, kDefaultPeakHold);

    // Map friendly 0-100 sliders / ms to concrete per-frame rates (60fps timer).
    double shadowSpeed = getConfigInt(kKeyShadowFallSpeed, kDefaultShadowFallSpeed) / 100.0;
    double peakSpeed   = getConfigInt(kKeyPeakFallSpeed, kDefaultPeakFallSpeed) / 100.0;
    int    peakHoldMs  = (int)getConfigInt(kKeyPeakHoldMs, kDefaultPeakHoldMs);
    s.shadowFall     = (float)(0.001 + shadowSpeed * 0.0275);   // ~0.001 (slow) .. 0.0285 (fast)
    s.peakGravity    = (float)(0.0001 + peakSpeed * 0.0027);    // ~0.0001 .. 0.0028
    s.peakHoldFrames = (int)std::lround(peakHoldMs * 60.0 / 1000.0);

    _analyzer->configure(s);

    [self.spectrumView reloadSettings];
    [self updateGlassBackground];
}

- (void)handleSettingsChanged:(NSNotification *)note {
    [self applySettings];
}

- (void)updateGlassBackground {
    using namespace spectrum_config;
    BOOL glass = getConfigBool(kKeyGlassBackground, kDefaultGlassBackground);
    if (glass == (_glassEffectView != nil)) return;

    if (glass) {
        _glassEffectView = [[NSVisualEffectView alloc] initWithFrame:self.view.bounds];
        _glassEffectView.material = NSVisualEffectMaterialSidebar;
        _glassEffectView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        _glassEffectView.state = NSVisualEffectStateActive;
        _glassEffectView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self.view addSubview:_glassEffectView positioned:NSWindowBelow relativeTo:self.spectrumView];
    } else {
        [_glassEffectView removeFromSuperview];
        _glassEffectView = nil;
    }
}

#pragma mark - Timer

- (void)startTimer {
    [self stopTimer];
    if (g_shutdown.load()) return;
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

        bool live = _analyzer->tick();
        self.spectrumView.playing = live;

        // Redraw while there is live audio or bars/peaks are still settling.
        if (live || _analyzer->isActive()) {
            const auto &bars = _analyzer->bars();
            const auto &shadow = _analyzer->shadow();
            const auto &peaks = _analyzer->peaks();
            [self.spectrumView setBarsData:bars.data()
                                    shadow:shadow.data()
                                     peaks:peaks.data()
                                     count:(NSInteger)bars.size()];
        }
    }
}

#pragma mark - SpectrumViewDelegate

- (void)spectrumViewRequestsContextMenu:(SpectrumView *)view atPoint:(NSPoint)point {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Spectrum Analyzer"];
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
            uiControl->show_preferences(spectrum_config::guid_preferences_page);
        }
    } @catch (...) {
        console::error("[Spectrum] Failed to open preferences");
    }
}

@end
