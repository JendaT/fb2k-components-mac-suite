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

## Versioning

### Single Source of Truth: `shared/version.h`

**CRITICAL:** All component versions are defined in `shared/version.h`. This is the ONLY place to update versions.

```cpp
// shared/version.h
#define SIMPLAYLIST_VERSION "1.1.0"
#define SIMPLAYLIST_VERSION_INT 110

#define PLORG_VERSION "1.0.0"
#define PLORG_VERSION_INT 100
// ... etc
```

### Version Update Checklist

When releasing a new version:

1. **Update `shared/version.h`** - Change BOTH the string and int versions
2. **Update CHANGELOG.md** in the extension's directory
3. **Rebuild the component** - The version propagates automatically via `common_about.h`
4. **Commit and push**
5. **Run release script**: `./Scripts/release_component.sh <name> --draft`

### What NOT to Do

- ❌ Do NOT edit `MARKETING_VERSION` in `generate_xcode_project.rb` directly
- ❌ Do NOT edit version in `Info.plist` directly
- ❌ Do NOT hardcode versions in `Main.mm`

The Xcode project generator and `JL_COMPONENT_ABOUT` macro read from `version.h` automatically.

### Independent Versioning

Each extension has its own version - they are completely independent:

| Extension | Version Constant | Release Tag |
|-----------|-----------------|-------------|
| SimPlaylist | `SIMPLAYLIST_VERSION` | `simplaylist-v1.1.0` |
| Playlist Organizer | `PLORG_VERSION` | `plorg-v1.0.0` |
| Waveform Seekbar | `WAVEFORM_VERSION` | `waveform-v1.0.0` |
| Last.fm Scrobbler | `SCROBBLE_VERSION` | `scrobble-v1.0.0` |

Releasing one extension does not affect others.

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
