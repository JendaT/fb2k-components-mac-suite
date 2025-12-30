# foo_jl_playback_controls_ext - Foundation Document

## Overview

A custom playback controls UI element for foobar2000 Mac that provides:
- Transport buttons: Previous, Stop, Play/Pause, Next
- Volume control slider
- Two-row configurable text display (title formatting)
- Click-to-navigate functionality
- Editing mode for button rearrangement

## Component Architecture

```
foo_jl_playback_controls_ext/
├── src/
│   ├── Core/
│   │   ├── PlaybackControlsConfig.h       # Configuration storage
│   │   └── PlaybackControlsConfig.mm
│   ├── UI/
│   │   ├── PlaybackControlsController.h   # Main NSViewController
│   │   ├── PlaybackControlsController.mm
│   │   ├── PlaybackControlsView.h         # Custom NSView
│   │   ├── PlaybackControlsView.mm
│   │   ├── TransportButton.h              # Draggable button component
│   │   ├── TransportButton.mm
│   │   ├── VolumeSlider.h                 # Volume control component
│   │   └── VolumeSlider.mm
│   └── Integration/
│       ├── Main.mm                        # Service registration
│       └── PlaybackCallbacks.mm           # Playback event handling
├── Resources/
│   └── Images.xcassets/                   # Button icons
├── docs/
│   └── FOUNDATION.md
└── Makefile
```

## SDK APIs Required

### 1. Playback Control

**Header:** `SDK/playback_control.h`

```cpp
playback_control::ptr pc = playback_control::get();

// Transport controls
pc->start();                    // Play
pc->stop();                     // Stop
pc->pause(true);                // Pause
pc->toggle_pause();             // Toggle pause
pc->play_or_pause();            // Smart play/pause
pc->next();                     // Next track
pc->previous();                 // Previous track

// State queries
bool playing = pc->is_playing();
bool paused = pc->is_paused();
```

### 2. Volume Control

**Header:** `SDK/playback_control.h`

```cpp
playback_control::ptr pc = playback_control::get();

// Volume in dB (0 = max, negative = quieter, -100 = mute)
float volume = pc->get_volume();
pc->set_volume(-6.0f);

// Step controls
pc->volume_up();
pc->volume_down();
pc->volume_mute_toggle();

// Custom volume (device-specific)
playback_control_v3::ptr pc3 = playback_control_v3::get();
if (pc3->custom_volume_is_active()) {
    int vol = pc3->custom_volume_get();
    int min = pc3->custom_volume_min();
    int max = pc3->custom_volume_max();
    pc3->custom_volume_set(vol + 1);
}
```

### 3. Title Formatting

**Header:** `SDK/titleformat.h`

```cpp
titleformat_compiler::ptr compiler = titleformat_compiler::get();
titleformat_object::ptr script;

// Compile format string
compiler->compile_safe(script, "%artist% - %title%");

// Render for current track
playback_control::ptr pc = playback_control::get();
pfc::string8 result;
pc->playback_format_title(NULL, result, script, NULL,
                          playback_control::display_level_all);
```

**Common Tags:**
- `%artist%`, `%title%`, `%album%`, `%date%`, `%genre%`
- `%playback_time%`, `%length%`, `%playback_time_remaining%`
- `%codec%`, `%bitrate%`, `%samplerate%`
- `$if(%isplaying%,...)`, `$if(%ispaused%,...)`

### 4. Playlist Navigation

**Header:** `SDK/playlist.h`

```cpp
playlist_manager::ptr pm = playlist_manager::get();

// Find currently playing track location
t_size playlistIdx, itemIdx;
if (pm->get_playing_item_location(&playlistIdx, &itemIdx)) {
    // Scroll to and focus the playing track
    pm->playlist_ensure_visible(playlistIdx, itemIdx);
    pm->playlist_set_focus_item(playlistIdx, itemIdx);
}
```

### 5. Playback Callbacks

**Header:** `SDK/play_callback.h`

```cpp
class PlaybackControlsCallback : public play_callback_impl_base {
public:
    PlaybackControlsCallback() : play_callback_impl_base(
        flag_on_playback_new_track |
        flag_on_playback_stop |
        flag_on_playback_pause |
        flag_on_playback_time |
        flag_on_volume_change
    ) {}

    void on_playback_new_track(metadb_handle_ptr track) override;
    void on_playback_stop(play_control::t_stop_reason reason) override;
    void on_playback_pause(bool state) override;
    void on_playback_time(double time) override;
    void on_volume_change(float volume) override;
};
```

## UI Components

### 1. PlaybackControlsView (Main Container)

Custom `NSView` containing all elements in a horizontal layout.

**Layout (default order):**
```
[Prev] [Stop] [Play/Pause] [Next] | [Volume Slider] | [Track Info]
                                                      Artist - Title
                                                      0:00 / 3:45
```

**Properties:**
- `isEditingMode` - enables drag-to-reorder
- `buttonOrder` - array of button identifiers
- `topRowFormat` - title format string (default: `%artist% - %title%`)
- `bottomRowFormat` - title format string (default: `%playback_time% / %length%`)

### 2. TransportButton (Draggable Button)

Custom `NSButton` subclass supporting:
- Standard button appearance with SF Symbols icons
- Drag source/destination for reordering
- Visual feedback during editing mode

**Button Identifiers:**
```objc
typedef NS_ENUM(NSInteger, TransportButtonType) {
    TransportButtonPrevious = 0,
    TransportButtonStop,
    TransportButtonPlayPause,
    TransportButtonNext,
    TransportButtonVolume,    // Volume slider container
    TransportButtonTrackInfo  // Track info container
};
```

### 3. VolumeSlider

Custom `NSSlider` or `NSView` with:
- Horizontal slider (0-100 mapped to dB)
- Optional mute button
- Visual feedback for custom volume mode
- Tooltip showing dB value

### 4. TrackInfoView

Two-row text display:
- Top row: Large text, configurable format, clickable
- Bottom row: Small text, configurable format
- Click handler calls playlist navigation

```objc
@interface TrackInfoView : NSView
@property (nonatomic, copy) NSString *topRowFormat;
@property (nonatomic, copy) NSString *bottomRowFormat;
@property (nonatomic, copy) NSString *topRowText;
@property (nonatomic, copy) NSString *bottomRowText;
@property (nonatomic, weak) id<TrackInfoViewDelegate> delegate;
@end

@protocol TrackInfoViewDelegate <NSObject>
- (void)trackInfoViewDidClick:(TrackInfoView *)view;
@end
```

## Editing Mode Implementation

### Activation
- Context menu option: "Edit Layout"
- Or dedicated "Edit" button in component

### Visual Feedback
- Jiggle animation on draggable items
- Drop indicator between items
- Semi-transparent drag image

### Drag-and-Drop Pattern

```objc
@interface PlaybackControlsView () <NSDraggingSource, NSDraggingDestination>
@end

// Pasteboard type for internal reordering
static NSPasteboardType const TransportButtonPasteboardType =
    @"com.foobar2000.playbackcontrols.button";

// Drag source
- (NSDragOperation)draggingSession:(NSDraggingSession *)session
    sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    return self.isEditingMode ? NSDragOperationMove : NSDragOperationNone;
}

// Drag destination
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    if (!self.isEditingMode) return NSDragOperationNone;

    NSPoint location = [self convertPoint:[sender draggingLocation] fromView:nil];
    [self updateDropIndicatorAtPoint:location];
    return NSDragOperationMove;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    // Reorder items in stack view
    // Save new order to config
    return YES;
}
```

### Jiggle Animation

```objc
- (void)startJiggleAnimation {
    for (NSView *item in self.arrangedSubviews) {
        CABasicAnimation *rotation = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        rotation.fromValue = @(-0.03);
        rotation.toValue = @(0.03);
        rotation.duration = 0.1;
        rotation.repeatCount = HUGE_VALF;
        rotation.autoreverses = YES;
        [item.layer addAnimation:rotation forKey:@"jiggle"];
    }
}

- (void)stopJiggleAnimation {
    for (NSView *item in self.arrangedSubviews) {
        [item.layer removeAnimationForKey:@"jiggle"];
    }
}
```

## Configuration Storage

**Namespace:** `playback_controls_config`

```cpp
namespace playback_controls_config {
    static const char* const kPrefix = "foo_playback_controls.";

    // Keys
    static const char* const kButtonOrder = "button_order";
    static const char* const kTopRowFormat = "top_row_format";
    static const char* const kBottomRowFormat = "bottom_row_format";
    static const char* const kShowVolume = "show_volume";
    static const char* const kShowTrackInfo = "show_track_info";

    // Defaults
    static const char* const kDefaultTopRowFormat = "%artist% - %title%";
    static const char* const kDefaultBottomRowFormat = "%playback_time% / %length%";
    static const char* const kDefaultButtonOrder = "[0,1,2,3,4,5]";

    // Accessors using fb2k::configStore
    inline std::string getButtonOrder() {
        return getConfigString(kButtonOrder, kDefaultButtonOrder);
    }

    inline void setButtonOrder(const std::string& order) {
        setConfigString(kButtonOrder, order.c_str());
    }

    inline std::string getTopRowFormat() {
        return getConfigString(kTopRowFormat, kDefaultTopRowFormat);
    }

    inline void setTopRowFormat(const std::string& format) {
        setConfigString(kTopRowFormat, format.c_str());
    }

    // ... similar for other settings
}
```

**Button Order Format (JSON):**
```json
[0, 1, 2, 3, 4, 5]
```
Where indices map to `TransportButtonType` enum.

## Service Registration

**Main.mm:**

```cpp
// GUID for the UI element
static const GUID g_guid_playback_controls =
    { 0x12345678, 0x1234, 0x1234, { 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0 } };

class playback_controls_ui_element : public ui_element_mac {
public:
    service_ptr instantiate(service_ptr arg) override {
        @autoreleasepool {
            NSDictionary* params = nil;
            if (arg.is_valid()) {
                id obj = fb2k::unwrapNSObject(arg);
                if ([obj isKindOfClass:[NSDictionary class]]) {
                    params = (NSDictionary*)obj;
                }
            }
            PlaybackControlsController* controller =
                [[PlaybackControlsController alloc] initWithParameters:params];
            return fb2k::wrapNSObject(controller);
        }
    }

    bool match_name(const char* name) override {
        return strcmp(name, "Playback Controls") == 0 ||
               strcmp(name, "playback_controls") == 0 ||
               strcmp(name, "transport") == 0;
    }

    fb2k::stringRef get_name() override {
        return fb2k::makeString("Playback Controls");
    }

    GUID get_guid() override {
        return g_guid_playback_controls;
    }
};

FB2K_SERVICE_FACTORY(playback_controls_ui_element);
```

## Playback State Management

### State Updates

```objc
@interface PlaybackControlsController ()
@property (nonatomic, assign) BOOL isPlaying;
@property (nonatomic, assign) BOOL isPaused;
@property (nonatomic, assign) float currentVolume;
@property (nonatomic, copy) NSString *topRowText;
@property (nonatomic, copy) NSString *bottomRowText;
@end

- (void)updatePlaybackState {
    playback_control::ptr pc = playback_control::get();

    self.isPlaying = pc->is_playing();
    self.isPaused = pc->is_paused();
    self.currentVolume = pc->get_volume();

    [self updateButtonStates];
    [self updateTrackInfo];
}

- (void)updateButtonStates {
    // Update play/pause button icon
    NSString *iconName = self.isPlaying && !self.isPaused ? @"pause.fill" : @"play.fill";
    [self.playPauseButton setImage:[NSImage imageWithSystemSymbolName:iconName
                                                accessibilityDescription:nil]];
}
```

### Title Format Rendering

```objc
- (void)updateTrackInfo {
    @autoreleasepool {
        playback_control::ptr pc = playback_control::get();

        if (!pc->is_playing()) {
            self.topRowText = @"Not Playing";
            self.bottomRowText = @"";
            return;
        }

        // Top row
        titleformat_object::ptr topScript;
        titleformat_compiler::get()->compile_safe(topScript,
            playback_controls_config::getTopRowFormat().c_str());
        pfc::string8 topResult;
        pc->playback_format_title(NULL, topResult, topScript, NULL,
                                  playback_control::display_level_all);
        self.topRowText = [NSString stringWithUTF8String:topResult.c_str()];

        // Bottom row
        titleformat_object::ptr bottomScript;
        titleformat_compiler::get()->compile_safe(bottomScript,
            playback_controls_config::getBottomRowFormat().c_str());
        pfc::string8 bottomResult;
        pc->playback_format_title(NULL, bottomResult, bottomScript, NULL,
                                  playback_control::display_level_all);
        self.bottomRowText = [NSString stringWithUTF8String:bottomResult.c_str()];

        [self.trackInfoView setNeedsDisplay:YES];
    }
}
```

## Click-to-Navigate Implementation

```objc
- (void)trackInfoViewDidClick:(TrackInfoView *)view {
    @autoreleasepool {
        playlist_manager::ptr pm = playlist_manager::get();

        t_size playlistIdx, itemIdx;
        if (pm->get_playing_item_location(&playlistIdx, &itemIdx)) {
            pm->playlist_ensure_visible(playlistIdx, itemIdx);
            pm->playlist_set_focus_item(playlistIdx, itemIdx);
        }
    }
}
```

## Preferences Integration (Optional)

If a preferences page is desired:

```cpp
class playback_controls_preferences : public preferences_page {
public:
    service_ptr instantiate() override {
        return fb2k::wrapNSObject([[PlaybackControlsPrefsController alloc] init]);
    }

    const char* get_name() override { return "Playback Controls"; }
    GUID get_guid() override { return g_guid_prefs; }
    GUID get_parent_guid() override { return preferences_page::guid_display; }
};

FB2K_SERVICE_FACTORY(playback_controls_preferences);
```

**Preferences UI:**
- Top row format text field
- Bottom row format text field
- Show volume control checkbox
- Show track info checkbox
- Reset to default layout button

## Threading Considerations

1. **Playback callbacks execute on background thread** - dispatch to main queue for UI updates
2. **SDK calls are thread-safe** - can query playback_control from any thread
3. **UI updates must be on main thread**

```objc
void on_playback_new_track(metadb_handle_ptr track) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[PlaybackControlsController shared] updateTrackInfo];
    });
}
```

## Implementation Priority

1. **Phase 1 - Core Transport**
   - Basic view with play/pause, stop, prev, next buttons
   - Wire up playback control actions
   - Register as ui_element_mac

2. **Phase 2 - Track Info Display**
   - Add track info view with configurable formats
   - Implement playback callbacks for updates
   - Add click-to-navigate

3. **Phase 3 - Volume Control**
   - Add volume slider
   - Handle custom volume mode
   - Add mute toggle

4. **Phase 4 - Editing Mode**
   - Implement drag-and-drop reordering
   - Add jiggle animation
   - Persist button order

5. **Phase 5 - Preferences**
   - Create preferences page
   - Format string configuration
   - Layout reset option

## Dependencies

- foobar2000 SDK (2025-03-07 or later)
- macOS 11.0+ (for SF Symbols)
- Objective-C++ (.mm files)

## Design Decisions

| Question | Decision |
|----------|----------|
| Multiple instances with different configs | Yes - each instance stores config by instance GUID |
| Vertical volume slider option | Yes - configurable orientation |
| Compact mode (icons only) | Yes - secondary priority, full mode is primary |
| Long-press to enter edit mode | Yes - in addition to context menu |

## Multiple Instance Support

Each instance receives a unique identifier and stores its configuration separately:

```cpp
namespace playback_controls_config {
    // Instance-specific key generation
    inline std::string getInstanceKey(const GUID& instanceGuid, const char* key) {
        char guidStr[64];
        snprintf(guidStr, sizeof(guidStr), "%08x%04x%04x%02x%02x%02x%02x%02x%02x%02x%02x",
                 instanceGuid.Data1, instanceGuid.Data2, instanceGuid.Data3,
                 instanceGuid.Data4[0], instanceGuid.Data4[1], instanceGuid.Data4[2],
                 instanceGuid.Data4[3], instanceGuid.Data4[4], instanceGuid.Data4[5],
                 instanceGuid.Data4[6], instanceGuid.Data4[7]);
        return std::string(kPrefix) + guidStr + "." + key;
    }
}
```

**Instance Parameters:**
```objc
- (instancetype)initWithParameters:(NSDictionary *)params {
    // params may contain:
    // - @"instance_id" : unique identifier for this instance
    // - @"compact" : @"true" for compact mode
    // - @"volume_orientation" : @"vertical" or @"horizontal"
}
```

## Long-Press Edit Mode

```objc
@interface PlaybackControlsView ()
@property (nonatomic, strong) NSPressGestureRecognizer *longPressRecognizer;
@end

- (void)setupGestureRecognizers {
    self.longPressRecognizer = [[NSPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleLongPress:)];
    self.longPressRecognizer.minimumPressDuration = 0.5;  // 500ms
    self.longPressRecognizer.allowedTouchTypes = NSTouchTypeMaskDirect;
    [self addGestureRecognizer:self.longPressRecognizer];
}

- (void)handleLongPress:(NSPressGestureRecognizer *)recognizer {
    if (recognizer.state == NSGestureRecognizerStateBegan) {
        [self enterEditingMode];
    }
}
```

## Compact Mode

**Full Mode (default):**
```
[Prev] [Stop] [Play/Pause] [Next] | [Volume] | Artist - Title
                                              0:00 / 3:45
```

**Compact Mode:**
```
[Prev] [Play/Pause] [Next] | [Vol]
```

Compact mode:
- Hides Stop button (use Play/Pause to stop via double-click or context menu)
- Smaller volume slider
- No track info display
- Reduced spacing

```objc
typedef NS_ENUM(NSInteger, PlaybackControlsDisplayMode) {
    PlaybackControlsDisplayModeFull = 0,
    PlaybackControlsDisplayModeCompact
};
```

## Volume Slider Orientation

```objc
typedef NS_ENUM(NSInteger, VolumeSliderOrientation) {
    VolumeSliderOrientationHorizontal = 0,
    VolumeSliderOrientationVertical
};

@interface VolumeSliderView : NSView
@property (nonatomic, assign) VolumeSliderOrientation orientation;
@end

- (void)setOrientation:(VolumeSliderOrientation)orientation {
    _orientation = orientation;

    if (orientation == VolumeSliderOrientationVertical) {
        self.slider.sliderType = NSSliderTypeLinear;
        self.slider.isVertical = YES;
        // Adjust frame for vertical layout
    } else {
        self.slider.sliderType = NSSliderTypeLinear;
        self.slider.isVertical = NO;
    }

    [self setNeedsLayout:YES];
}
```
