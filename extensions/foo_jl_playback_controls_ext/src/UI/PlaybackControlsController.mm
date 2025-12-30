//
//  PlaybackControlsController.mm
//  foo_jl_playback_controls_ext
//
//  Main controller implementation
//

#import "PlaybackControlsController.h"
#import "PlaybackControlsView.h"
#import "../Core/PlaybackControlsConfig.h"

NSNotificationName const PlaybackControlsStateDidChangeNotification = @"PlaybackControlsStateDidChangeNotification";

// Weak reference to active controller for callbacks
static __weak PlaybackControlsController *s_activeController = nil;

@interface PlaybackControlsController () <PlaybackControlsViewDelegate>

@property (nonatomic, strong) PlaybackControlsView *controlsView;
@property (nonatomic, copy, nullable) NSString *instanceId;

// Writeable versions of readonly properties
@property (nonatomic, assign, readwrite) BOOL isPlaying;
@property (nonatomic, assign, readwrite) BOOL isPaused;
@property (nonatomic, assign, readwrite) float currentVolume;
@property (nonatomic, assign, readwrite) double playbackTime;
@property (nonatomic, assign, readwrite) double trackLength;
@property (nonatomic, copy, readwrite) NSString *topRowText;
@property (nonatomic, copy, readwrite) NSString *bottomRowText;
@property (nonatomic, assign, readwrite) BOOL isEditingMode;

// Compiled titleformat scripts
@property (nonatomic, assign) titleformat_object::ptr topRowScript;
@property (nonatomic, assign) titleformat_object::ptr bottomRowScript;

@end

@implementation PlaybackControlsController

+ (nullable instancetype)activeController {
    return s_activeController;
}

- (instancetype)initWithParameters:(nullable NSDictionary<NSString*, NSString*>*)params {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _instanceId = params[@"instance_id"];
        _topRowText = @"Not Playing";
        _bottomRowText = @"";
        _currentVolume = 0.0f;
        _isEditingMode = NO;

        [self compileTitleFormatScripts];
    }
    return self;
}

- (void)dealloc {
    if (s_activeController == self) {
        s_activeController = nil;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)loadView {
    // Determine display mode
    playback_controls_config::DisplayMode mode =
        playback_controls_config::getDisplayMode(_instanceId.UTF8String);

    BOOL compact = (mode == playback_controls_config::DisplayModeCompact);

    // Create the main controls view
    self.controlsView = [[PlaybackControlsView alloc] initWithCompactMode:compact];
    self.controlsView.delegate = self;

    // Load button order from config
    [self loadButtonOrder];

    self.view = self.controlsView;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // Set as active controller
    s_activeController = self;

    // Initial state update
    [self updatePlaybackState];
    [self updateTrackInfo];
}

- (void)viewWillAppear {
    [super viewWillAppear];
    s_activeController = self;
    [self updatePlaybackState];
    [self updateTrackInfo];
}

- (void)viewDidDisappear {
    [super viewDidDisappear];
    if (s_activeController == self) {
        s_activeController = nil;
    }
}

#pragma mark - Titleformat Compilation

- (void)compileTitleFormatScripts {
    @autoreleasepool {
        try {
            auto compiler = titleformat_compiler::get();

            // Top row format
            std::string topFormat = playback_controls_config::getTopRowFormat(_instanceId.UTF8String);
            compiler->compile_safe(_topRowScript, topFormat.c_str());

            // Bottom row format
            std::string bottomFormat = playback_controls_config::getBottomRowFormat(_instanceId.UTF8String);
            compiler->compile_safe(_bottomRowScript, bottomFormat.c_str());

        } catch (...) {
            console::error("[PlaybackControls] Failed to compile titleformat scripts");
        }
    }
}

#pragma mark - Button Order

- (void)loadButtonOrder {
    std::string orderJson = playback_controls_config::getButtonOrder(_instanceId.UTF8String);
    NSData *data = [[NSString stringWithUTF8String:orderJson.c_str()]
                    dataUsingEncoding:NSUTF8StringEncoding];

    NSError *error = nil;
    NSArray *order = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];

    if (!error && [order isKindOfClass:[NSArray class]]) {
        [self.controlsView setButtonOrder:order];
    }
}

- (void)saveButtonOrder {
    NSArray *order = [self.controlsView buttonOrder];
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:order options:0 error:&error];

    if (!error) {
        NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        playback_controls_config::setButtonOrder(json.UTF8String, _instanceId.UTF8String);
    }
}

#pragma mark - Playback State Updates

- (void)updatePlaybackState {
    @autoreleasepool {
        try {
            auto pc = playback_control::get();

            self.isPlaying = pc->is_playing();
            self.isPaused = pc->is_paused();
            self.currentVolume = pc->get_volume();

            // Update button states in view
            [self.controlsView updatePlayPauseState:self.isPlaying isPaused:self.isPaused];
            [self.controlsView updateVolume:self.currentVolume];

        } catch (...) {
            console::error("[PlaybackControls] Failed to update playback state");
        }
    }
}

- (void)updateTrackInfo {
    @autoreleasepool {
        try {
            auto pc = playback_control::get();

            if (!pc->is_playing()) {
                self.topRowText = @"Not Playing";
                self.bottomRowText = @"";
                self.playbackTime = 0;
                self.trackLength = 0;
            } else {
                // Format top row
                if (_topRowScript.is_valid()) {
                    pfc::string8 result;
                    pc->playback_format_title(NULL, result, _topRowScript, NULL,
                                              playback_control::display_level_all);
                    self.topRowText = [NSString stringWithUTF8String:result.c_str()];
                }

                // Format bottom row
                if (_bottomRowScript.is_valid()) {
                    pfc::string8 result;
                    pc->playback_format_title(NULL, result, _bottomRowScript, NULL,
                                              playback_control::display_level_all);
                    self.bottomRowText = [NSString stringWithUTF8String:result.c_str()];
                }

                // Get timing info
                self.playbackTime = pc->playback_get_position();

                metadb_handle_ptr track;
                if (pc->get_now_playing(track)) {
                    self.trackLength = track->get_length();
                }
            }

            [self.controlsView updateTrackInfoWithTopRow:self.topRowText
                                               bottomRow:self.bottomRowText];

        } catch (...) {
            console::error("[PlaybackControls] Failed to update track info");
        }
    }
}

- (void)updateVolume:(float)volume {
    self.currentVolume = volume;
    [self.controlsView updateVolume:volume];
}

#pragma mark - Actions

- (void)playOrPause {
    @autoreleasepool {
        try {
            auto pc = playback_control::get();
            pc->play_or_pause();
        } catch (...) {
            console::error("[PlaybackControls] Failed to play/pause");
        }
    }
}

- (void)stop {
    @autoreleasepool {
        try {
            auto pc = playback_control::get();
            pc->stop();
        } catch (...) {
            console::error("[PlaybackControls] Failed to stop");
        }
    }
}

- (void)previous {
    @autoreleasepool {
        try {
            auto pc = playback_control::get();
            pc->previous();
        } catch (...) {
            console::error("[PlaybackControls] Failed to go to previous");
        }
    }
}

- (void)next {
    @autoreleasepool {
        try {
            auto pc = playback_control::get();
            pc->next();
        } catch (...) {
            console::error("[PlaybackControls] Failed to go to next");
        }
    }
}

- (void)setVolume:(float)volume {
    @autoreleasepool {
        try {
            auto pc = playback_control::get();
            pc->set_volume(volume);
        } catch (...) {
            console::error("[PlaybackControls] Failed to set volume");
        }
    }
}

- (void)navigateToPlayingTrack {
    @autoreleasepool {
        try {
            auto pm = playlist_manager::get();

            t_size playlistIdx, itemIdx;
            if (pm->get_playing_item_location(&playlistIdx, &itemIdx)) {
                pm->playlist_ensure_visible(playlistIdx, itemIdx);
                pm->playlist_set_focus_item(playlistIdx, itemIdx);
            }
        } catch (...) {
            console::error("[PlaybackControls] Failed to navigate to playing track");
        }
    }
}

#pragma mark - Editing Mode

- (void)enterEditingMode {
    self.isEditingMode = YES;
    [self.controlsView enterEditingMode];
}

- (void)exitEditingMode {
    self.isEditingMode = NO;
    [self.controlsView exitEditingMode];
    [self saveButtonOrder];
}

#pragma mark - PlaybackControlsViewDelegate

- (void)controlsViewDidTapPlayPause:(PlaybackControlsView *)view {
    [self playOrPause];
}

- (void)controlsViewDidTapStop:(PlaybackControlsView *)view {
    [self stop];
}

- (void)controlsViewDidTapPrevious:(PlaybackControlsView *)view {
    [self previous];
}

- (void)controlsViewDidTapNext:(PlaybackControlsView *)view {
    [self next];
}

- (void)controlsView:(PlaybackControlsView *)view didChangeVolume:(float)volume {
    [self setVolume:volume];
}

- (void)controlsViewDidTapTrackInfo:(PlaybackControlsView *)view {
    [self navigateToPlayingTrack];
}

- (void)controlsViewDidRequestEditMode:(PlaybackControlsView *)view {
    if (self.isEditingMode) {
        [self exitEditingMode];
    } else {
        [self enterEditingMode];
    }
}

- (void)controlsViewDidChangeButtonOrder:(PlaybackControlsView *)view {
    [self saveButtonOrder];
}

- (void)controlsViewDidRequestContextMenu:(PlaybackControlsView *)view atPoint:(NSPoint)point {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Playback Controls"];

    // Edit layout option
    NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:self.isEditingMode ? @"Done Editing" : @"Edit Layout"
                                                      action:@selector(toggleEditModeFromMenu:)
                                               keyEquivalent:@""];
    editItem.target = self;
    [menu addItem:editItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // Display mode submenu
    NSMenuItem *modeItem = [[NSMenuItem alloc] initWithTitle:@"Display Mode" action:nil keyEquivalent:@""];
    NSMenu *modeSubmenu = [[NSMenu alloc] init];

    NSMenuItem *fullMode = [[NSMenuItem alloc] initWithTitle:@"Full"
                                                      action:@selector(setDisplayModeFull:)
                                               keyEquivalent:@""];
    fullMode.target = self;
    fullMode.state = (playback_controls_config::getDisplayMode(_instanceId.UTF8String) == playback_controls_config::DisplayModeFull)
                     ? NSControlStateValueOn : NSControlStateValueOff;
    [modeSubmenu addItem:fullMode];

    NSMenuItem *compactMode = [[NSMenuItem alloc] initWithTitle:@"Compact"
                                                         action:@selector(setDisplayModeCompact:)
                                                  keyEquivalent:@""];
    compactMode.target = self;
    compactMode.state = (playback_controls_config::getDisplayMode(_instanceId.UTF8String) == playback_controls_config::DisplayModeCompact)
                        ? NSControlStateValueOn : NSControlStateValueOff;
    [modeSubmenu addItem:compactMode];

    modeItem.submenu = modeSubmenu;
    [menu addItem:modeItem];

    [menu popUpMenuPositioningItem:nil atLocation:point inView:view];
}

- (void)toggleEditModeFromMenu:(id)sender {
    if (self.isEditingMode) {
        [self exitEditingMode];
    } else {
        [self enterEditingMode];
    }
}

- (void)setDisplayModeFull:(id)sender {
    playback_controls_config::setDisplayMode(playback_controls_config::DisplayModeFull,
                                             _instanceId.UTF8String);
    // Would need to reload view to apply
}

- (void)setDisplayModeCompact:(id)sender {
    playback_controls_config::setDisplayMode(playback_controls_config::DisplayModeCompact,
                                             _instanceId.UTF8String);
    // Would need to reload view to apply
}

@end
