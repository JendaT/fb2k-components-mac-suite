# foobar2000 macOS SDK - Service Patterns

## Overview

This document covers the core SDK patterns for registering services, handling callbacks, and integrating with the foobar2000 architecture on macOS.

## 1. Service Registration

### 1.1 FB2K_SERVICE_FACTORY

The primary mechanism for registering services with foobar2000:

```cpp
#include "fb2k_sdk.h"

namespace {
    class my_service_impl : public my_service_interface {
    public:
        void do_something() override {
            // Implementation
        }
    };

    FB2K_SERVICE_FACTORY(my_service_impl);
}
```

**Key points:**
- Place in anonymous namespace to avoid symbol conflicts
- One `FB2K_SERVICE_FACTORY` per implementation class
- Service is instantiated automatically at component load

### 1.2 Static Initialization Warning

**CRITICAL**: Never create SDK-dependent objects as static globals. They initialize during dylib load, BEFORE the SDK is ready, causing segfaults.

```cpp
// BAD - crashes on component load
class my_callback : public playlist_callback_single_impl_base {
    my_callback() : playlist_callback_single_impl_base(flags) {}
};
static my_callback g_callback;  // CRASH!

// GOOD - use FB2K_SERVICE_FACTORY (handles timing)
FB2K_SERVICE_FACTORY(my_play_callback);

// GOOD - or defer to initquit::on_init()
static my_callback* g_callback = nullptr;
void on_init() { g_callback = new my_callback(); }
void on_quit() { delete g_callback; g_callback = nullptr; }
```

See `07_DEBUGGING.md` Section 4.0 for diagnosis and fix details.

### 1.3 Component Version Declaration

Required in every component's Main.mm:

```cpp
DECLARE_COMPONENT_VERSION(
    "Component Name",
    "1.0.0",
    "Description of component\n"
    "Author: Your Name\n"
    "License: MIT"
);

VALIDATE_COMPONENT_FILENAME("foo_mycomponent.component");
```

## 2. GUID Generation and Usage

### 2.1 Generating GUIDs

Use `uuidgen` command or online generator:

```bash
$ uuidgen
A1B2C3D4-E5F6-7890-ABCD-EF1234567890
```

### 2.2 GUID Declaration Pattern

```cpp
// In header or implementation file
static const GUID guid_my_service = {
    0xa1b2c3d4, 0xe5f6, 0x7890,
    { 0xab, 0xcd, 0xef, 0x12, 0x34, 0x56, 0x78, 0x90 }
};
```

### 2.3 Common Parent GUIDs

For preferences pages, use these standard parents:

```cpp
// From SDK - preferences page categories
extern const GUID guid_root;           // Root preferences
extern const GUID guid_display;        // Display settings
extern const GUID guid_playback;       // Playback settings
extern const GUID guid_tools;          // Tools category
extern const GUID guid_advanced;       // Advanced settings
```

## 3. ui_element_mac Interface

### 3.1 Basic UI Element

```objc
// MyUIElement.h
#import <Cocoa/Cocoa.h>
#include "fb2k_sdk.h"

@interface MyUIElementView : NSView
@property (nonatomic, assign) double playbackPosition;
- (void)updateDisplay;
@end

// MyUIElement.mm
#include "fb2k_sdk.h"
#import "MyUIElement.h"

namespace {
    static const GUID guid_my_ui_element = { /* GUID */ };

    class my_ui_element : public ui_element_mac {
    public:
        static GUID g_get_guid() { return guid_my_ui_element; }
        static GUID g_get_subclass() { return ui_element_subclass_utility; }
        static void g_get_name(pfc::string_base& out) { out = "My Element"; }

        static ui_element_config::ptr g_get_default_configuration() {
            return ui_element_config::create_empty(g_get_guid());
        }

        NSView* createView(NSRect frame,
                          ui_element_config::ptr config,
                          ui_element_instance_callback::ptr callback) override {
            MyUIElementView* view = [[MyUIElementView alloc] initWithFrame:frame];
            m_callback = callback;
            return view;
        }

    private:
        ui_element_instance_callback::ptr m_callback;
    };

    FB2K_SERVICE_FACTORY(my_ui_element);
}
```

### 3.2 UI Element Subclasses

```cpp
// Available subclass GUIDs
ui_element_subclass_utility      // General utility panels
ui_element_subclass_playback     // Playback-related (seekbars, controls)
ui_element_subclass_playlist     // Playlist views
ui_element_subclass_media_library // Library views
```

## 4. play_callback Integration

### 4.1 Implementing play_callback

**CRITICAL**: Exceptions in callbacks will crash foobar2000. Always wrap callback
implementations in try-catch blocks.

```cpp
#include "fb2k_sdk.h"

namespace {
    class my_play_callback : public play_callback_static {
    public:
        // Flags for which callbacks we want
        unsigned get_flags() override {
            return flag_on_playback_new_track |
                   flag_on_playback_stop |
                   flag_on_playback_seek |
                   flag_on_playback_time;
        }

        // New track started
        void on_playback_new_track(metadb_handle_ptr p_track) override {
            try {
                // Request waveform generation, update display
                console::info("Now playing: new track");
                // Your code here...
            } catch (const std::exception& e) {
                console::formatter() << "play_callback error: " << e.what();
            } catch (...) {
                console::error("Unknown exception in on_playback_new_track");
            }
        }

        // Playback stopped
        void on_playback_stop(play_callback::t_stop_reason p_reason) override {
            try {
                // Clear display, cancel pending operations
            } catch (...) {
                // Never let exceptions escape
            }
        }

        // User seeked
        void on_playback_seek(double p_time) override {
            try {
                // Update position immediately
            } catch (...) {}
        }

        // Position update (1Hz by default)
        void on_playback_time(double p_time) override {
            try {
                // Update position indicator
            } catch (...) {}
        }

        // Other callbacks (implement as empty if not needed)
        void on_playback_starting(play_control::t_track_command p_command,
                                  bool p_paused) override {}
        void on_playback_pause(bool p_state) override {}
        void on_playback_edited(metadb_handle_ptr p_track) override {}
        void on_playback_dynamic_info(const file_info& p_info) override {}
        void on_playback_dynamic_info_track(const file_info& p_info) override {}
        void on_volume_change(float p_new_val) override {}
    };

    FB2K_SERVICE_FACTORY(my_play_callback);
}
```

### 4.2 Callback Flags

```cpp
// Available flags
flag_on_playback_starting        // About to start
flag_on_playback_new_track       // New track playing
flag_on_playback_stop            // Playback stopped
flag_on_playback_seek            // Position changed
flag_on_playback_pause           // Pause state changed
flag_on_playback_edited          // Track metadata edited
flag_on_playback_dynamic_info    // Stream info changed
flag_on_playback_dynamic_info_track // Dynamic track info
flag_on_playback_time            // Position update (1Hz)
flag_on_volume_change            // Volume changed
```

## 5. Configuration with cfg_var

### 5.1 Basic Configuration Variables

```cpp
// In MyConfig.h
#include "fb2k_sdk.h"

// GUID for config namespace
static const GUID guid_my_config = { /* GUID */ };

namespace mycomponent_config {
    // Boolean setting
    extern cfg_bool cfg_enabled;

    // Integer setting
    extern cfg_int cfg_value;

    // String setting
    extern cfg_string cfg_format;
}

// In MyConfig.cpp
#include "MyConfig.h"

namespace mycomponent_config {
    // Parameters: GUID, sub-ID, default value
    cfg_bool cfg_enabled(guid_my_config, 0, true);
    cfg_int cfg_value(guid_my_config, 1, 100);
    cfg_string cfg_format(guid_my_config, 2, "%artist% - %title%");
}
```

### 5.2 Using cfg_var in UI

```objc
// In preferences controller
- (void)loadFromConfig {
    self.enabledCheckbox.state = mycomponent_config::cfg_enabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.valueSlider.intValue = mycomponent_config::cfg_value;
    self.formatField.stringValue = [NSString stringWithUTF8String:mycomponent_config::cfg_format.get()];
}

- (void)saveToConfig {
    mycomponent_config::cfg_enabled = (self.enabledCheckbox.state == NSControlStateValueOn);
    mycomponent_config::cfg_value = self.valueSlider.intValue;
    mycomponent_config::cfg_format = [self.formatField.stringValue UTF8String];
}
```

### 5.3 cfg_var Types

```cpp
cfg_bool        // Boolean (true/false)
cfg_int         // 32-bit integer
cfg_uint        // Unsigned 32-bit integer
cfg_int64       // 64-bit integer
cfg_uint64      // Unsigned 64-bit integer
cfg_float       // Single-precision float
cfg_double      // Double-precision float
cfg_string      // UTF-8 string
cfg_guid        // GUID value
```

## 6. NSObject Wrapping

### 6.1 Wrapping NSViewController for Preferences

```objc
#include "fb2k_sdk.h"
#import "MyPreferences.h"

namespace {
    static const GUID guid_my_preferences = { /* GUID */ };

    class my_preferences_page : public preferences_page {
    public:
        const char* get_name() override {
            return "My Component";
        }

        GUID get_guid() override {
            return guid_my_preferences;
        }

        GUID get_parent_guid() override {
            return guid_tools;  // Appears under Tools
        }

        service_ptr instantiate(service_ptr args) override {
            MyPreferencesController* vc = [[MyPreferencesController alloc]
                initWithNibName:@"MyPreferences"
                bundle:[NSBundle bundleForClass:[MyPreferencesController class]]];
            return fb2k::wrapNSObject(vc);
        }
    };

    FB2K_SERVICE_FACTORY(my_preferences_page);
}
```

### 6.2 Programmatic Preferences Page (No XIB)

For simple preferences pages, you can build the UI programmatically:

```objc
// FlippedView for top-left coordinate system (standard macOS is bottom-left)
@interface FlippedView : NSView
@end
@implementation FlippedView
- (BOOL)isFlipped { return YES; }
@end

@implementation MyPreferencesController

- (void)loadView {
    // Use FlippedView for top-down layout
    FlippedView *view = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, 450, 300)];
    self.view = view;
    [self buildUI];
    [self loadSettings];
}

- (void)buildUI {
    CGFloat y = 10;      // Start from top (flipped coords)
    CGFloat labelX = 20;
    CGFloat controlX = 130;

    // Controls follow top-down, increasing y pattern
    // Use standard 11pt system font
    // No bold headers - use regular weight for section titles
    // Indent sub-items by 10px (labelX + 10)
}

- (NSTextField *)createLabel:(NSString *)text at:(NSPoint)point {
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(point.x, point.y, 200, 17)];
    label.stringValue = text;
    label.editable = NO;
    label.bordered = NO;
    label.backgroundColor = [NSColor clearColor];
    label.font = [NSFont systemFontOfSize:11];  // Standard size
    return label;
}

- (NSColorWell *)createColorWellAt:(NSPoint)point {
    NSColorWell *well = [[NSColorWell alloc] initWithFrame:NSMakeRect(point.x, point.y, 40, 24)];
    [well setTarget:self];
    [well setAction:@selector(colorChanged:)];
    // Use popover style on macOS 13+ for better positioning
    if (@available(macOS 13.0, *)) {
        well.colorWellStyle = NSColorWellStyleMinimal;
    }
    return well;
}

@end
```

**Layout Guidelines:**
- Use `FlippedView` subclass with `isFlipped = YES` for top-left coordinate origin
- Standard font: `[NSFont systemFontOfSize:11]` (11pt system font)
- No large bold headers - section titles use same font as labels
- Indent sub-items by 10px from section title
- Vertical spacing: 22px between items, 30-32px between sections
- Control positions: labels at x=20, controls at x=130

### 6.3 Important Notes

- `fb2k::wrapNSObject()` creates a service_ptr that holds an NSObject
- The wrapped object is retained by the service_ptr
- Use `[NSBundle bundleForClass:]` to load resources from your component bundle

## 7. playback_control API

### 7.1 Getting Playback State

```cpp
#include "fb2k_sdk.h"

void check_playback() {
    auto pc = playback_control::get();

    if (pc->is_playing()) {
        double position = pc->playback_get_position();
        double length = pc->playback_get_length();

        metadb_handle_ptr track;
        if (pc->get_now_playing(track)) {
            // Have access to current track
        }
    }
}
```

### 7.2 Seeking

```cpp
void seek_to_position(double seconds) {
    auto pc = playback_control::get();
    if (pc->is_playing() && pc->playback_can_seek()) {
        pc->playback_seek(seconds);
    }
}

void seek_relative(double delta_seconds) {
    auto pc = playback_control::get();
    if (pc->is_playing() && pc->playback_can_seek()) {
        pc->playback_seek_delta(delta_seconds);
    }
}
```

## 8. metadb_handle Operations

### 8.1 Accessing Track Information

```cpp
#include "fb2k_sdk.h"

void process_track(metadb_handle_ptr track) {
    if (track.is_empty()) return;

    // Get file path
    const char* path = track->get_path();

    // Get duration
    double duration = track->get_length();

    // Get file stats
    t_filestats stats = track->get_filestats();
    t_filetimestamp modified = stats.m_timestamp;
    t_filesize size = stats.m_size;

    console::formatter() << "Path: " << path
                         << ", Duration: " << duration << "s"
                         << ", Size: " << size;
}
```

### 8.2 Accessing Metadata

```cpp
void read_metadata(metadb_handle_ptr track) {
    if (track.is_empty()) return;

    // Get file_info - contains all metadata
    file_info_impl info;
    track->get_info(info);

    // Read specific tags (returns nullptr if not present)
    const char* artist = info.meta_get("artist", 0);
    const char* title = info.meta_get("title", 0);
    const char* album = info.meta_get("album", 0);

    // Check for multi-value tags
    t_size artist_count = info.meta_get_count_by_name("artist");
    for (t_size i = 0; i < artist_count; i++) {
        const char* artist_i = info.meta_get("artist", i);
    }

    // Technical info
    int samplerate = info.info_get_int("samplerate");
    int channels = info.info_get_int("channels");
    int bitrate = info.info_get_int("bitrate");
    const char* codec = info.info_get("codec");
}
```

### 8.3 Using input_helper for Audio Access

```cpp
#include <helpers/input_helpers.h>

void scan_audio_file(const playable_location& location) {
    try {
        input_helper helper;

        // Open the file for decoding
        abort_callback_dummy aborter;
        helper.open(service_ptr_t<file>(), location, input_flag_no_seeking,
                    aborter, false, false);

        // Get track info
        file_info_impl info;
        helper.get_info(0, info, aborter);

        double duration = info.get_length();
        int samplerate = info.info_get_int("samplerate");
        int channels = info.info_get_int("channels");

        // Decode audio in chunks
        audio_chunk_impl chunk;
        while (helper.run(chunk, aborter)) {
            // Process audio data
            const audio_sample* samples = chunk.get_data();
            t_size sample_count = chunk.get_sample_count();
            t_size channel_count = chunk.get_channel_count();

            // samples is interleaved: [L0, R0, L1, R1, ...]
            for (t_size i = 0; i < sample_count; i++) {
                for (t_size ch = 0; ch < channel_count; ch++) {
                    audio_sample sample = samples[i * channel_count + ch];
                    // sample is in range [-1.0, 1.0]
                }
            }
        }

        helper.close();
    }
    catch (const pfc::exception& e) {
        console::formatter() << "Failed to open: " << e.what();
    }
}
```

## 9. Titleformat API

### 9.1 Compiling and Using Titleformat Scripts

```cpp
#include "fb2k_sdk.h"

void format_track_info() {
    // Compile a titleformat script
    titleformat_object::ptr script;
    static_api_ptr_t<titleformat_compiler>()->compile_safe(
        script, "%artist% - %title%");

    // Format current playing track
    pfc::string8 result;
    auto pc = playback_control::get();
    if (pc->playback_format_title(nullptr, result, script, nullptr,
            playback_control::display_level_all)) {
        console::info(result.c_str());
    }
}

// Format any track
void format_any_track(metadb_handle_ptr track) {
    if (track.is_empty()) return;

    titleformat_object::ptr script;
    static_api_ptr_t<titleformat_compiler>()->compile_safe(
        script, "[%album artist%] - %album% - %tracknumber%. %title%");

    pfc::string8 result;
    track->format_title(nullptr, result, script, nullptr);
    console::info(result.c_str());
}
```

### 9.2 Common Titleformat Fields

| Field | Description |
|-------|-------------|
| `%artist%` | Track artist |
| `%album artist%` | Album artist |
| `%title%` | Track title |
| `%album%` | Album name |
| `%tracknumber%` | Track number |
| `%date%` | Release date |
| `%genre%` | Genre |
| `%codec%` | Audio codec |
| `%bitrate%` | Bitrate in kbps |
| `%samplerate%` | Sample rate in Hz |
| `%channels%` | Number of channels |
| `%length%` | Duration formatted |
| `%length_seconds%` | Duration in seconds |
| `%path%` | Full file path |
| `%filename%` | Filename without path |
| `%filename_ext%` | Filename with extension |

## 10. initquit Service

### 10.1 Component Initialization

```cpp
namespace {
    class my_initquit : public initquit {
    public:
        void on_init() override {
            // Called when component loads
            console::info("My Component: Initialized");

            // Initialize caches, start background tasks, etc.
        }

        void on_quit() override {
            // Called when foobar2000 shuts down
            console::info("My Component: Shutting down");

            // Save state, clean up resources
        }
    };

    FB2K_SERVICE_FACTORY(my_initquit);
}
```

## 9. Console Logging

### 9.1 Logging Functions

```cpp
// Info message
console::info("Component initialized");

// Warning
console::warning("Cache file not found, creating new");

// Error
console::error("Failed to open database");

// Formatted output
console::formatter() << "Processing track: " << track_path;
```

## 10. Thread Safety

### 10.1 Main Thread Callbacks

**WARNING**: `fb2k::inMainThread()` will deadlock if called from the main thread!
Always check the current thread first.

```cpp
#include "fb2k_sdk.h"

// WRONG - will deadlock if already on main thread
void bad_main_thread_call() {
    fb2k::inMainThread([=]() {
        // If called from main thread, this blocks waiting for... itself
    });
}

// CORRECT - check thread first
void safe_main_thread_call() {
    if ([NSThread isMainThread]) {
        // Already on main thread - execute directly
        doWork();
    } else {
        fb2k::inMainThread([=]() {
            doWork();
        });
    }
}

// Alternative: use dispatch_async which is always safe
void always_safe_main_thread_call() {
    dispatch_async(dispatch_get_main_queue(), ^{
        // This is always safe - dispatch_async never blocks
        doWork();
    });
}
```

### 10.2 Background Tasks with GCD

```objc
- (void)processInBackground:(void(^)(void))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Background processing

        dispatch_async(dispatch_get_main_queue(), ^{
            // Back to main thread
            completion();
        });
    });
}
```

## 11. Error Handling

### 11.1 Exception Pattern

```cpp
try {
    // SDK operations
    input_helper helper;
    helper.open(location, abort_callback_dummy());
}
catch (const pfc::exception& e) {
    console::formatter() << "Error: " << e.what();
}
catch (const std::exception& e) {
    console::formatter() << "STL Error: " << e.what();
}
```

### 11.2 Abort Callbacks

```cpp
// For user-cancellable operations
class my_abort_callback : public abort_callback_impl {
    // Can check is_aborting() or throw if aborted
};

// For background operations without user cancellation
abort_callback_dummy aborter;
```

## Best Practices

1. **Always use anonymous namespaces** for service implementations
2. **Generate unique GUIDs** for each service, config namespace, and preference page
3. **Handle exceptions** at SDK boundaries - never let exceptions escape
4. **Use main thread** for all UI updates and most SDK calls
5. **Check playback state** before accessing playback data
6. **Use cfg_var** for all persistent settings
7. **Clean up in on_quit()** - save state, close files, stop threads
