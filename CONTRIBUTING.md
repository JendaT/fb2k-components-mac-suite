# Contributing to foobar2000 macOS Components

## Code Standards

### Naming Conventions

| Type | Pattern | Example |
|------|---------|---------|
| C++ Callback class | `{prefix}_{type}_callback` | `simplaylist_playlist_callback` |
| ObjC Controller | `{Feature}Controller` | `SimPlaylistController` |
| ObjC View | `{Feature}View` | `WaveformSeekbarView` |
| Config namespace | `{extension}_config` | `simplaylist_config` |
| Console prefix | `[{ShortName}]` | `[SimPlaylist]` |
| Notification name | `{ExtensionName}SettingsChanged` | `SimPlaylistSettingsChanged` |

### Required Patterns

#### Configuration Persistence

Use `fb2k::configStore` via namespace helpers, NOT `cfg_var` (doesn't persist on macOS v2):

```cpp
namespace myext_config {
    static const char* const kConfigPrefix = "foo_myext.";

    inline int64_t getConfigInt(const char* key, int64_t defaultVal) {
        return fb2k::configStore::get()->getConfigInt(
            pfc::string8(kConfigPrefix) + key, defaultVal);
    }

    inline void setConfigInt(const char* key, int64_t value) {
        fb2k::configStore::get()->setConfigInt(
            pfc::string8(kConfigPrefix) + key, value);
    }
}
```

#### Callback Registration

Use singleton pattern with weak controller references:

```cpp
static std::vector<__weak MyController*> g_controllers;
static std::mutex g_controllersMutex;

void registerController(MyController* controller) {
    std::lock_guard<std::mutex> lock(g_controllersMutex);
    g_controllers.push_back(controller);
}
```

#### Threading

Always dispatch UI updates to main thread:

```cpp
dispatch_async(dispatch_get_main_queue(), ^{
    [controller updateUI];
});
```

#### Error Handling

Log errors to console with component prefix:

```cpp
FB2K_console_formatter() << "[MyExt] Error: " << message;
```

#### Preferences UI

Use shared utilities from `shared/PreferencesCommon.h`:

```objc
#import "PreferencesCommon.h"

- (void)loadView {
    JLFlippedView *container = [[JLFlippedView alloc] initWithFrame:...];

    // Page title (non-bold, matches foobar2000 style)
    NSTextField *title = JLCreatePreferencesTitle(@"My Extension");

    // Section headers
    NSTextField *section = JLCreateSectionHeader(@"Options");
}
```

### File Organization

```
foo_myext_mac/
├── src/
│   ├── Core/           # Platform-agnostic C++ logic
│   ├── UI/             # Cocoa views and controllers
│   ├── Integration/    # SDK service registration
│   ├── fb2k_sdk.h      # SDK wrapper header
│   └── Prefix.pch      # Precompiled headers
├── Resources/
│   └── Info.plist      # Bundle metadata
├── Scripts/
│   ├── build.sh
│   ├── install.sh
│   └── generate_xcode_project.rb
└── README.md
```

### Component Registration

Use the shared branding macro in Main.mm:

```cpp
#include "common_about.h"

JL_COMPONENT_ABOUT(
    "My Extension",
    "1.0.0",
    "Description of the extension.\n\n"
    "Features:\n"
    "- Feature 1\n"
    "- Feature 2"
);
```

## Building

1. Generate Xcode project: `ruby Scripts/generate_xcode_project.rb`
2. Build: `./Scripts/build.sh`
3. Install: `./Scripts/install.sh`
4. Test: Restart foobar2000

## Testing

- Test with both light and dark mode
- Test with Intel and Apple Silicon (if possible)
- Verify settings persist after foobar2000 restart
- Check console for errors during operation

## Pull Requests

1. Create a feature branch
2. Follow code standards above
3. Test thoroughly
4. Update CHANGELOG.md
5. Submit PR with clear description
