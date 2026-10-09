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

@interface SpectrumController () {
    std::unique_ptr<SpectrumAnalyzer> _analyzer;
    SpectrumAnalyzer::Settings _settings;  // last applied, for "Auto" bar count updates
    bool _autoBars;
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
    s.logScale  = getConfigInt(kKeyFreqScale, kDefaultFreqScale) == FreqScaleLog;
    s.peakHold  = getConfigBool(kKeyPeakHold, kDefaultPeakHold);

    // Map friendly 0-100 sliders / ms to concrete per-frame rates (60fps timer).
    double shadowSpeed = getConfigInt(kKeyShadowFallSpeed, kDefaultShadowFallSpeed) / 100.0;
    double peakSpeed   = getConfigInt(kKeyPeakFallSpeed, kDefaultPeakFallSpeed) / 100.0;
    int    peakHoldMs  = (int)getConfigInt(kKeyPeakHoldMs, kDefaultPeakHoldMs);
    s.shadowFall     = (float)(0.001 + shadowSpeed * 0.0275);   // ~0.001 (slow) .. 0.0285 (fast)
    s.peakGravity    = (float)(0.0001 + peakSpeed * 0.0027);    // ~0.0001 .. 0.0028
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
        NSWindow *window = self.view.window;
        if (!window || self.view.isHiddenOrHasHiddenAncestor) return;
        // Skip fully covered windows, e.g. the panel while full screen is up.
        if (!(window.occlusionState & NSWindowOcclusionStateVisible)) return;

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
