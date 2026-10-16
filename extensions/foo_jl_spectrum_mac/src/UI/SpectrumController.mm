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
#include <Carbon/Carbon.h>  // kVK_Escape
#import <QuartzCore/QuartzCore.h>

@interface SpectrumController () {
    std::unique_ptr<SpectrumAnalyzer> _analyzer;
    SpectrumAnalyzer::Settings _settings;  // last applied, for "Auto" bar count updates
    bool _autoBars;
    id _displayLink;            // CADisplayLink (macOS 14+); otherwise _timer drives ticks
    NSTimer *_timer;
    CFTimeInterval _lastTick;   // time of the previous tick, 0 before the first
    NSVisualEffectView *_glassEffectView;
}
@property (nonatomic, readwrite) SpectrumView *spectrumView;
- (void)shutdownForQuit;
- (void)displayLinkFired:(CADisplayLink *)link API_AVAILABLE(macos(14.0));
@end

// CADisplayLink retains its target; this weak trampoline keeps the link from
// holding the controller alive.
API_AVAILABLE(macos(14.0))
@interface SpectrumDisplayLinkTarget : NSObject
@property (nonatomic, weak) SpectrumController *controller;
- (void)displayLinkFired:(CADisplayLink *)link;
@end

@implementation SpectrumDisplayLinkTarget
- (void)displayLinkFired:(CADisplayLink *)link {
    [self.controller displayLinkFired:link];
}
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

#pragma mark - Full-screen window

// Hosts its own SpectrumController in a native full-screen Space, so the panel
// stays in the foobar2000 layout. Closes itself once full screen is exited.
@interface SpectrumFullScreenWindow : NSWindow <NSWindowDelegate>
@property (nonatomic, strong) SpectrumController *spectrumController;
- (void)exitFullScreen;
@end

namespace {
    // At most one full-screen spectrum; main thread only.
    SpectrumFullScreenWindow *g_fullScreenWindow = nil;
}

@implementation SpectrumFullScreenWindow

- (void)exitFullScreen {
    if (self.styleMask & NSWindowStyleMaskFullScreen) [self toggleFullScreen:nil];
    else [self close];
}

- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == kVK_Escape) { [self exitFullScreen]; return; }
    [super keyDown:event];
}

- (void)windowDidExitFullScreen:(NSNotification *)note {
    [self close];
}

- (void)windowDidFailToEnterFullScreen:(NSWindow *)window {
    [self close];
}

- (void)windowWillClose:(NSNotification *)note {
    if (g_fullScreenWindow == self) g_fullScreenWindow = nil;
}

@end

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
    // hosted inside the foobar2000 layout. Ticks guard on window visibility.
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
    // The view caches orientation and margins that the "Auto" bar count
    // depends on, so it reloads first.
    [self.spectrumView reloadSettings];

    SpectrumAnalyzer::Settings s;
    s.barCount  = (int)getConfigInt(kKeyBarCount, kDefaultBarCount);
    _autoBars   = s.barCount == kBarCountAuto;
    if (_autoBars) s.barCount = (int)[self.spectrumView autoBarCount];
    s.fftSize   = (int)getConfigInt(kKeyFftSize, kDefaultFftSize);
    s.minHz     = (int)getConfigInt(kKeyMinHz, kDefaultMinHz);
    s.maxHz     = (int)getConfigInt(kKeyMaxHz, kDefaultMaxHz);
    s.smoothing = (int)getConfigInt(kKeySmoothing, kDefaultSmoothing);
    s.smoothingMode = (int)getConfigInt(kKeySmoothingMode, kDefaultSmoothingMode);
    s.rmsMs     = getRmsMs();
    s.slopeDbPerOct = getConfigInt(kKeySlopeTenths, kDefaultSlopeTenths) / 10.0f;
    s.freqScale = (int)getConfigInt(kKeyFreqScale, kDefaultFreqScale);
    s.peakHold  = getConfigBool(kKeyPeakHold, kDefaultPeakHold);

    // Map friendly 0-100 sliders / ms to concrete per-frame rates (60fps timer).
    double shadowSpeed = getConfigInt(kKeyShadowFallSpeed, kDefaultShadowFallSpeed) / 100.0;
    int    peakHoldMs  = (int)getConfigInt(kKeyPeakHoldMs, kDefaultPeakHoldMs);
    s.shadowFall     = (float)(0.001 + shadowSpeed * 0.0275);   // ~0.001 (slow) .. 0.0285 (fast)
    if (s.smoothingMode == SmoothingRms && s.rmsMs > 0) {
        // An RMS curve falls at most 10*log10(e)/tau dB/s (power decaying with
        // nothing coming in), slow enough that most fixed shadow rates would
        // fall faster and stay hidden under it. Scale the slider to 15-90% of
        // that rate so the shadow always trails the curve.
        const double curveFallDbPerSec = 10.0 * std::log10(std::exp(1.0)) / (s.rmsMs / 1000.0);
        const double curveFall = curveFallDbPerSec / 60.0 / (kDisplayCeilDb - kDisplayFloorDb);
        s.shadowFall = (float)(curveFall * (0.15 + 0.75 * shadowSpeed));
    }
    s.peakFall       = (float)(getPeakFallDbPerSec() / 60.0 / (kDisplayCeilDb - kDisplayFloorDb));
    s.peakHoldFrames = (int)std::lround(peakHoldMs * 60.0 / 1000.0);

    _settings = s;
    _analyzer->configure(s);

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

// Shortest time between ticks. On fast displays this takes every second (or
// third) refresh, an even cadence of 60-90 fps instead of drawing at up to 240 Hz.
static const CFTimeInterval kMinTickInterval = 0.0105;

- (void)startTimer {
    [self stopTimer];
    if (g_shutdown.load()) return;
    _lastTick = 0;

    // A display link fires in step with the screen's refresh, so each displayed
    // frame carries exactly one update. A free-running timer drifts against the
    // refresh and shows repeated and skipped frames.
    if (@available(macOS 14.0, *)) {
        // The link belongs to the view's screen; with no window yet,
        // spectrumViewDidMoveToWindow: starts it later.
        if (!self.spectrumView.window) return;
        SpectrumDisplayLinkTarget *target = [[SpectrumDisplayLinkTarget alloc] init];
        target.controller = self;
        CADisplayLink *link = [self.spectrumView displayLinkWithTarget:target
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

- (void)tickAt:(CFTimeInterval)now {
    @autoreleasepool {
        if (g_shutdown.load()) { [self stopTimer]; return; }
        const double dt = _lastTick > 0 ? now - _lastTick : 1.0 / 60.0;
        _lastTick = now;

        NSWindow *window = self.view.window;
        if (!window || self.view.isHiddenOrHasHiddenAncestor) return;
        // Skip fully covered windows, e.g. the panel while full screen is up.
        if (!(window.occlusionState & NSWindowOcclusionStateVisible)) return;

        bool live = _analyzer->tick(dt);
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

- (void)spectrumView:(SpectrumView *)view autoBarCountChanged:(NSInteger)count {
    if (!_autoBars || count == _settings.barCount) return;
    _settings.barCount = (int)count;
    _analyzer->configure(_settings);
}

- (void)spectrumViewRequestsContextMenu:(SpectrumView *)view atPoint:(NSPoint)point {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Spectrum Analyzer"];
    NSMenuItem *fullScreen = [[NSMenuItem alloc] initWithTitle:g_fullScreenWindow ? @"Exit Full Screen" : @"Full Screen"
                                                        action:@selector(menuToggleFullScreen:)
                                                 keyEquivalent:@""];
    fullScreen.target = self;
    [menu addItem:fullScreen];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *prefs = [[NSMenuItem alloc] initWithTitle:@"Preferences..."
                                                   action:@selector(menuShowPreferences:)
                                            keyEquivalent:@""];
    prefs.target = self;
    [menu addItem:prefs];
    [menu popUpMenuPositioningItem:nil atLocation:point inView:view];
}

- (void)spectrumViewDidMoveToWindow:(SpectrumView *)view {
    if (view.window) [self startTimer];
    else [self stopTimer];
}

- (void)spectrumViewRequestsFullScreenToggle:(SpectrumView *)view {
    [self toggleFullScreen];
}

- (void)menuToggleFullScreen:(NSMenuItem *)sender {
    [self toggleFullScreen];
}

// From the panel this opens the full-screen window; from inside it (or while
// one is already open) it exits.
- (void)toggleFullScreen {
    if (g_fullScreenWindow) { [g_fullScreenWindow exitFullScreen]; return; }
    if (g_shutdown.load()) return;

    NSScreen *screen = self.view.window.screen ?: NSScreen.mainScreen;
    const NSRect frame = screen.visibleFrame;

    SpectrumFullScreenWindow *w = [[SpectrumFullScreenWindow alloc]
        initWithContentRect:frame
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                            NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView
                    backing:NSBackingStoreBuffered
                      defer:NO];
    w.releasedWhenClosed = NO;
    w.title = @"Spectrum Analyzer";
    w.titleVisibility = NSWindowTitleHidden;
    w.titlebarAppearsTransparent = YES;
    w.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    w.delegate = w;

    // The controller's view opts out of autoresizing masks, so pin it inside
    // a plain content view rather than making it the window's content view.
    SpectrumController *controller = [[SpectrumController alloc] init];
    NSView *spectrum = controller.view;
    spectrum.layer.cornerRadius = 0;
    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
    [content addSubview:spectrum];
    [NSLayoutConstraint activateConstraints:@[
        [spectrum.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [spectrum.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [spectrum.topAnchor constraintEqualToAnchor:content.topAnchor],
        [spectrum.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
    ]];
    w.contentView = content;
    w.spectrumController = controller;

    g_fullScreenWindow = w;
    [w makeKeyAndOrderFront:nil];
    [w toggleFullScreen:nil];
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
