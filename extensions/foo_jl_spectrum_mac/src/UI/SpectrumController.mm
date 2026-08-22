//
//  SpectrumController.mm
//  foo_jl_spectrum_mac
//

#import "SpectrumController.h"
#include "../Core/SpectrumAnalyzer.h"
#include "../Core/SpectrumConfig.h"
#include <memory>

@interface SpectrumController () {
    std::unique_ptr<SpectrumAnalyzer> _analyzer;
    NSTimer *_timer;
    NSVisualEffectView *_glassEffectView;
}
@property (nonatomic, readwrite) SpectrumView *spectrumView;
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

- (void)dealloc {
    [self stopTimer];
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
        if (!self.view.window || self.view.isHiddenOrHasHiddenAncestor) return;

        bool live = _analyzer->tick();
        self.spectrumView.playing = live;

        // Redraw while there is live audio or bars/peaks are still settling.
        if (live || _analyzer->isActive()) {
            const auto &bars = _analyzer->bars();
            const auto &peaks = _analyzer->peaks();
            [self.spectrumView setBarsData:bars.data()
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
