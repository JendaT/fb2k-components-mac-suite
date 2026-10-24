//
//  LevelMeterController.mm
//  foo_jl_levelmeter_mac
//

#import "LevelMeterController.h"
#include "../Core/LevelMeterConfig.h"
#include "../Core/MeterEngine.h"
#include "../Integration/MeterSource.h"
#include <memory>
#include <vector>
#include <mutex>
#include <atomic>
#include <algorithm>

namespace {
    // Posted on the main thread when playback moves to a new track.
    NSString *const kNewTrackNotification = @"LevelMeterNewTrack";
    // Keep redrawing this long after the audio stops, while bars fall.
    const double kSettleSeconds = 4.0;
}

@interface LevelMeterController () {
    std::unique_ptr<MeterSource> _source;
    std::unique_ptr<meter::MeterEngine> _engine;
    std::vector<float> _lr;
    CFTimeInterval _lastTick;
    double _quietTime;
    NSTimer *_timer;
    NSVisualEffectView *_glassEffectView;
}
@property (nonatomic, readwrite) LevelMeterView *meterView;
- (void)shutdownForQuit;
@end

// Registry of live controllers so we can release visualisation streams before
// the core tears down the vis backend at quit. Holding an open stream during
// component shutdown triggers exception_service_not_found.
namespace {
    std::mutex g_controllersMutex;
    std::vector<__weak LevelMeterController*> g_controllers;
    std::atomic<bool> g_shutdown{false};

    void registerController(LevelMeterController* c) {
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        g_controllers.push_back(c);
    }
    void unregisterController(LevelMeterController* c) {
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        g_controllers.erase(std::remove_if(g_controllers.begin(), g_controllers.end(),
            [c](__weak LevelMeterController* w){ return w == nil || w == c; }),
            g_controllers.end());
    }
}

// Release streams and stop timers before the service system shuts down.
class levelmeter_initquit : public initquit {
public:
    void on_quit() override {
        g_shutdown.store(true);
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (__weak LevelMeterController* w : g_controllers) {
            LevelMeterController* c = w;
            if (c) [c shutdownForQuit];
        }
    }
};
FB2K_SERVICE_FACTORY(levelmeter_initquit);

// Track changes start a new loudness measurement (when enabled).
class levelmeter_play_callback : public play_callback_static {
public:
    unsigned get_flags() override { return flag_on_playback_new_track; }
    void on_playback_new_track(metadb_handle_ptr) override {
        [[NSNotificationCenter defaultCenter] postNotificationName:kNewTrackNotification object:nil];
    }
    void on_playback_starting(play_control::t_track_command, bool) override {}
    void on_playback_stop(play_control::t_stop_reason) override {}
    void on_playback_seek(double) override {}
    void on_playback_pause(bool) override {}
    void on_playback_edited(metadb_handle_ptr) override {}
    void on_playback_dynamic_info(const file_info&) override {}
    void on_playback_dynamic_info_track(const file_info&) override {}
    void on_playback_time(double) override {}
    void on_volume_change(float) override {}
};
FB2K_SERVICE_FACTORY(levelmeter_play_callback);

@implementation LevelMeterController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _source = std::make_unique<MeterSource>();
        _engine = std::make_unique<meter::MeterEngine>();
        _quietTime = kSettleSeconds;
    }
    return self;
}

- (void)loadView {
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 320)];
    container.wantsLayer = YES;
    container.layer.cornerRadius = 6.0;
    container.layer.masksToBounds = YES;

    LevelMeterView *view = [[LevelMeterView alloc] initWithFrame:container.bounds];
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    view.delegate = self;
    self.meterView = view;

    [container addSubview:view];
    self.view = container;

    [self updateGlassBackground];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [self.view.widthAnchor constraintGreaterThanOrEqualToConstant:40],
        [self.view.heightAnchor constraintGreaterThanOrEqualToConstant:30]
    ]];

    [self applySettings];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(handleSettingsChanged:)
               name:levelmeter_config::kSettingsChangedNotification object:nil];
    [nc addObserver:self selector:@selector(handleNewTrack:) name:kNewTrackNotification object:nil];

    registerController(self);

    // Start now as well: appearance callbacks are not guaranteed for a view
    // hosted inside the foobar2000 layout. tick guards on the window.
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
    _engine->configure(levelmeter_config::loadEngineSettings());
    [self.meterView reloadSettings];
    [self updateGlassBackground];
    [self.meterView showSnapshot:_engine->snapshot()];
}

- (void)handleSettingsChanged:(NSNotification *)note {
    [self applySettings];
}

- (void)handleNewTrack:(NSNotification *)note {
    using namespace levelmeter_config;
    if (getConfigBool(kKeyResetOnTrack, kDefaultResetOnTrack)) _engine->resetLoudness();
}

- (void)updateGlassBackground {
    using namespace levelmeter_config;
    BOOL glass = getConfigBool(kKeyGlass, kDefaultGlass);
    if (glass == (_glassEffectView != nil)) return;

    if (glass) {
        _glassEffectView = [[NSVisualEffectView alloc] initWithFrame:self.view.bounds];
        _glassEffectView.material = NSVisualEffectMaterialSidebar;
        _glassEffectView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        _glassEffectView.state = NSVisualEffectStateActive;
        _glassEffectView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self.view addSubview:_glassEffectView positioned:NSWindowBelow relativeTo:self.meterView];
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
        // Measure whenever the view is in a window, even one that is
        // covered or minimised, so the integrated loudness misses nothing.
        if (!self.view.window) return;

        const CFTimeInterval now = CACurrentMediaTime();
        const double dt = std::min(std::max(now - _lastTick, 0.0), 0.25);
        _lastTick = now;

        double sampleRate = 0;
        int channels = 2;
        const bool live = _source->pull(_lr, sampleRate, channels);
        const size_t frames = live ? _lr.size() / 2 : 0;
        if (frames > 0) {
            _engine->process(_lr.data(), frames, sampleRate, channels);
            _quietTime = 0.0;
        } else {
            _engine->idle(dt);
            _quietTime += dt;
        }
        _engine->advance(dt);

        // Once everything has fallen back there is nothing left to animate.
        if (_quietTime > kSettleSeconds) return;
        if (self.view.isHiddenOrHasHiddenAncestor) return;
        if (!(self.view.window.occlusionState & NSWindowOcclusionStateVisible)) return;
        [self.meterView showSnapshot:_engine->snapshot()];
    }
}

#pragma mark - LevelMeterViewDelegate

- (void)levelMeterViewResetPeaks:(LevelMeterView *)view {
    _engine->resetPeaks();
    [self.meterView showSnapshot:_engine->snapshot()];
}

- (void)levelMeterViewResetLoudness:(LevelMeterView *)view {
    _engine->resetLoudness();
    [self.meterView showSnapshot:_engine->snapshot()];
}

- (void)levelMeterViewRequestsContextMenu:(LevelMeterView *)view atPoint:(NSPoint)point {
    using namespace levelmeter_config;
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Level Meter"];

    auto add = [&](NSString *title, SEL action, NSInteger tag, BOOL checked) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
        item.target = self;
        item.tag = tag;
        item.state = checked ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:item];
        return item;
    };

    add(@"Reset Peaks", @selector(menuResetPeaks:), 0, NO);
    add(@"Reset Loudness", @selector(menuResetLoudness:), 0, NO);
    [menu addItem:[NSMenuItem separatorItem]];
    const int style = getConfigIntClamped(kKeyStyle, kDefaultStyle, 0, 1);
    add(@"Digital", @selector(menuSetStyle:), (NSInteger)meter::MeterStyle::Digital, style == (int)meter::MeterStyle::Digital);
    add(@"Analog VU", @selector(menuSetStyle:), (NSInteger)meter::MeterStyle::Analog, style == (int)meter::MeterStyle::Analog);
    [menu addItem:[NSMenuItem separatorItem]];
    add(@"Preferences...", @selector(menuShowPreferences:), 0, NO);
    [menu popUpMenuPositioningItem:nil atLocation:point inView:view];
}

- (void)menuResetPeaks:(NSMenuItem *)sender {
    [self levelMeterViewResetPeaks:self.meterView];
}

- (void)menuResetLoudness:(NSMenuItem *)sender {
    [self levelMeterViewResetLoudness:self.meterView];
}

- (void)menuSetStyle:(NSMenuItem *)sender {
    levelmeter_config::setConfigInt(levelmeter_config::kKeyStyle, sender.tag);
    [[NSNotificationCenter defaultCenter] postNotificationName:levelmeter_config::kSettingsChangedNotification object:nil];
}

- (void)menuShowPreferences:(NSMenuItem *)sender {
    @try {
        auto uiControl = ui_control::get();
        if (uiControl.is_valid()) {
            uiControl->show_preferences(levelmeter_config::guid_preferences_page);
        }
    } @catch (...) {
        console::error("[Level Meter] Failed to open preferences");
    }
}

@end
