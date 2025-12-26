# foobar2000 macOS Component - Project Structure Template

## Overview

This document provides a complete reference template for organizing a foobar2000 macOS component project. The structure is designed for maintainability, testability, and clean separation of concerns.

## Complete Directory Template

```
foo_[name]_mac/
│
├── src/
│   │
│   ├── Core/                           # Platform-agnostic C++ logic
│   │   ├── [Feature]Data.h/cpp         # Data structures
│   │   ├── [Feature]Service.h/cpp      # Service interfaces
│   │   ├── [Feature]Config.h/cpp       # Configuration (cfg_var)
│   │   └── [Feature]Cache.h/cpp        # Persistence (if needed)
│   │
│   ├── Platform/                       # macOS platform adapters (optional)
│   │   ├── I[Interface].h              # Abstract interfaces
│   │   ├── Mac[Interface].h/mm         # macOS implementations
│   │   └── README.md                   # Platform notes
│   │
│   ├── UI/                             # Cocoa views and controllers
│   │   ├── [Feature]View.h/mm          # NSView subclasses
│   │   ├── [Feature]ViewController.h/mm # NSViewController subclasses
│   │   └── [Feature]Preferences.h/mm   # Preferences page
│   │
│   ├── Integration/                    # SDK service registration
│   │   └── Main.mm                     # Component entry point
│   │
│   ├── Utils/                          # Shared utilities (optional)
│   │   ├── Threading.h                 # GCD helpers
│   │   └── Logging.h                   # Debug logging
│   │
│   ├── fb2k_sdk.h                      # SDK include wrapper
│   └── Prefix.pch                      # Precompiled header
│
├── Resources/
│   ├── Info.plist                      # Bundle metadata
│   ├── [Feature]Preferences.xib        # Preferences UI
│   └── Assets.xcassets/                # Images (optional)
│
├── Scripts/
│   ├── generate_xcode_project.rb       # Project generator
│   ├── update_project_libraries.rb     # Library linker
│   ├── add_missing_libraries.rb        # Additional libraries
│   ├── fix_library_search_paths.rb     # Path fixes
│   └── build.sh                        # Build script
│
├── Tests/
│   ├── [Feature]DataTests.mm           # Unit tests
│   └── Info.plist                      # Test bundle info
│
├── docs/                               # Component documentation (optional)
│   └── ARCHITECTURE.md
│
├── foo_[name].xcodeproj/               # Generated Xcode project
│   └── project.pbxproj
│
├── build/                              # Build output (gitignored)
│
├── README.md                           # Component readme
├── CHANGELOG.md                        # Version history
├── LICENSE                             # License file
└── .gitignore                          # Git ignores
```

## File Purposes

### src/Core/

**Purpose:** Platform-independent business logic that can be shared with Windows version.

```cpp
// [Feature]Data.h - Data structures
struct WaveformData {
    std::vector<float> min[2];
    std::vector<float> max[2];
    uint32_t channelCount;

    void serialize(stream_writer& out) const;
    bool deserialize(stream_reader& in);
};

// [Feature]Config.h - Configuration
namespace mycomponent_config {
    extern cfg_bool cfg_enabled;
    extern cfg_int cfg_option;
    extern cfg_string cfg_format;
}

// [Feature]Service.h - Service interface
class my_service : public service_base {
    FB2K_MAKE_SERVICE_INTERFACE_ENTRYPOINT(my_service);
public:
    virtual void do_something() = 0;
};
```

### src/Platform/

**Purpose:** Platform abstraction for cross-platform code. Use when Core logic needs platform-specific functionality.

```cpp
// IHttpClient.h - Abstract interface
class IHttpClient {
public:
    virtual ~IHttpClient() = default;
    virtual void requestAsync(
        const std::string& url,
        std::function<void(int status, std::string body)> callback
    ) = 0;
};

// MacHttpClient.h/mm - macOS implementation
@interface MacHttpClient : NSObject
- (void)requestURL:(NSString*)url
        completion:(void(^)(NSInteger status, NSString* body))completion;
@end

class MacHttpClientWrapper : public IHttpClient {
    MacHttpClient* m_client;
public:
    void requestAsync(...) override;
};
```

### src/UI/

**Purpose:** Cocoa-based UI components.

```objc
// [Feature]View.h - Custom NSView
@interface WaveformSeekbarView : NSView
@property (nonatomic) double playbackPosition;
@property (nonatomic) double duration;
@property (nonatomic, strong) WaveformDataWrapper *waveform;

- (void)setNeedsDisplayForPlaybackChange;
@end

// [Feature]Preferences.h - Preferences controller
@interface MyComponentPreferences : NSViewController
@property (weak) IBOutlet NSButton *enabledCheckbox;
@property (weak) IBOutlet NSPopUpButton *optionPopup;

- (void)loadFromConfig;
- (void)saveToConfig;
@end
```

### src/Integration/Main.mm

**Purpose:** SDK registration - component version, services, preferences pages.

```objc
#include "fb2k_sdk.h"
#import "UI/MyComponentPreferences.h"

// Version declaration
DECLARE_COMPONENT_VERSION(
    "My Component",
    "1.0.0",
    "Description\nAuthor: Name"
);

VALIDATE_COMPONENT_FILENAME("foo_mycomponent.component");

namespace {
    // Preferences page registration
    static const GUID guid_preferences = { ... };

    class mycomponent_preferences_page : public preferences_page {
    public:
        const char* get_name() override { return "My Component"; }
        GUID get_guid() override { return guid_preferences; }
        GUID get_parent_guid() override { return guid_tools; }

        service_ptr instantiate(service_ptr args) override {
            auto* vc = [[MyComponentPreferences alloc]
                initWithNibName:@"MyComponentPreferences"
                bundle:[NSBundle bundleForClass:[MyComponentPreferences class]]];
            return fb2k::wrapNSObject(vc);
        }
    };

    FB2K_SERVICE_FACTORY(mycomponent_preferences_page);

    // UI element registration (if applicable)
    class mycomponent_ui_element : public ui_element_mac {
        // ...
    };

    FB2K_SERVICE_FACTORY(mycomponent_ui_element);
}
```

### Resources/

**Info.plist:**
```xml
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.yourname.foo_mycomponent</string>
    <key>CFBundleName</key>
    <string>foo_mycomponent</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
```

### Scripts/

**generate_xcode_project.rb pattern:**
```ruby
#!/usr/bin/env ruby
require 'fileutils'
require 'securerandom'

PROJECT_NAME = "foo_mycomponent"
BUNDLE_ID = "com.yourname.foo_mycomponent"
SDK_PATH = "../SDK-2025-03-07"

# Generate UUIDs for all Xcode objects
# Collect source files from src/
# Generate project.pbxproj with:
#   - File references
#   - Build phases (Sources, Frameworks, Resources)
#   - Build configurations (Debug, Release)
#   - Header/library search paths
```

**build.sh:**
```bash
#!/bin/bash
set -e

# Regenerate project if needed
ruby Scripts/generate_xcode_project.rb

# Build
xcodebuild -project foo_mycomponent.xcodeproj \
           -configuration Release \
           -arch arm64 -arch x86_64

# Install
DEST=~/Library/Application\ Support/foobar2000/user-components
cp -r build/Release/foo_mycomponent.component "$DEST/"

echo "Component installed to $DEST"
```

## .gitignore Template

```gitignore
# Build
build/
DerivedData/
*.component

# Xcode
xcuserdata/
*.xcworkspace
*.xccheckout
*.moved-aside

# macOS
.DS_Store
.AppleDouble
.LSOverride
._*

# IDE
.idea/
*.swp
*.swo
*~

# Debug
*.dSYM/
*.log
```

## README.md Template

```markdown
# foo_mycomponent

A foobar2000 macOS component that [description].

## Features

- Feature 1
- Feature 2

## Requirements

- foobar2000 for Mac 2.x
- macOS 11.0+

## Installation

1. Download `foo_mycomponent.component`
2. Copy to `~/Library/Application Support/foobar2000/user-components/`
3. Restart foobar2000

## Building from Source

```bash
# Build SDK libraries first
cd ../SDK-2025-03-07
./build_all.sh

# Build component
cd ../foo_mycomponent_mac
./Scripts/build.sh
```

## Configuration

Access settings in Preferences > Tools > My Component.

## License

[Your License]
```

## Best Practices

### 1. Separation of Concerns
- Keep Core/ free of Cocoa/Objective-C dependencies
- Use Platform/ interfaces for platform-specific code
- Keep UI/ focused on presentation

### 2. Naming Conventions
- Files: `PascalCase` for classes, `snake_case` for utilities
- Classes: `PascalCase`
- Methods: `camelCase` for C++, standard conventions for ObjC

### 3. Error Handling
- Use `pfc::exception` for recoverable errors
- Log to console with `console::info()`, `console::warning()`, `console::error()`
- Never throw across SDK boundaries

### 4. Memory Management
- Use `service_ptr_t<>` for SDK objects
- Use ARC for Objective-C objects
- Use RAII patterns in C++

### 5. Threading
- Use GCD for background work
- Always update UI on main thread
- Use `fb2k::inMainThread()` for SDK callbacks
