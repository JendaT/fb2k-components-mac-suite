# foobar2000 macOS Component Development - Quickstart Guide

## Overview

This guide covers creating a new foobar2000 macOS component from scratch, including project setup, SDK integration, and build verification.

## Prerequisites

- **macOS 11+** (Big Sur or later)
- **Xcode 12+** with Command Line Tools
- **Ruby** (for project generation scripts)
- **foobar2000 for Mac** installed for testing
- **foobar2000 SDK** (2025-03-07 or later)

## 1. Naming Convention

Components follow the naming pattern:
```
foo_[functional_slug]_mac
```

Examples:
- `foo_scrobble_mac` - Last.fm scrobbler
- `foo_wave_seekbar_mac` - Waveform seekbar
- `foo_discogs_mac` - Discogs tagger

## 2. Directory Structure

Create your project directory at the same level as the SDK:
```
/path/to/foobar2000/
├── SDK-2025-03-07/          # Official SDK
├── foo_scrobble_mac/        # Existing reference project
└── foo_[your_name]_mac/     # Your new component
```

### Project Layout
```
foo_[name]_mac/
├── src/
│   ├── Core/                # Platform-agnostic C++ logic
│   ├── Platform/            # macOS-specific adapters (optional)
│   ├── UI/                  # Cocoa views/controllers
│   ├── Integration/         # SDK service registration
│   │   └── Main.mm          # Component entry point
│   ├── fb2k_sdk.h           # SDK include wrapper
│   └── Prefix.pch           # Precompiled header
├── Resources/
│   ├── Info.plist           # Bundle metadata
│   └── *.xib                # Interface Builder files
├── Scripts/
│   ├── generate_xcode_project.rb
│   ├── update_project_libraries.rb
│   └── build.sh
├── Tests/                   # Unit tests (optional)
├── README.md
├── .gitignore
└── foo_[name].xcodeproj/    # Generated Xcode project
```

## 3. Git Repository Setup

```bash
# Create project directory
mkdir foo_mycomponent_mac
cd foo_mycomponent_mac

# Initialize git
git init

# Create .gitignore
cat > .gitignore << 'EOF'
# Xcode
build/
DerivedData/
*.xcworkspace
xcuserdata/
*.xccheckout

# Build artifacts
*.component
*.o
*.a

# macOS
.DS_Store
.AppleDouble
.LSOverride

# IDE
.idea/
*.swp
*.swo
EOF

# Initial commit
git add .gitignore
git commit -m "Initial commit - project structure"
```

## 4. Essential Files

### 4.1 fb2k_sdk.h
```cpp
#pragma once

// Include order matters
#include <SDK/foobar2000.h>
#include <helpers/foobar2000+atl.h>

#ifdef __OBJC__
#import <Cocoa/Cocoa.h>
#import <helpers-mac/foobar2000-mac-helpers.h>
#endif
```

### 4.2 Prefix.pch
```cpp
#ifdef __cplusplus
#include "fb2k_sdk.h"
#endif

#ifdef __OBJC__
#import <Cocoa/Cocoa.h>
#endif
```

### 4.3 Info.plist
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright (c) 2025 Your Name</string>
    <key>NSPrincipalClass</key>
    <string></string>
</dict>
</plist>
```

### 4.4 Main.mm (Minimal)
```objc
#include "fb2k_sdk.h"

// Component version declaration
DECLARE_COMPONENT_VERSION(
    "My Component",
    "1.0.0",
    "Description of your component\n"
    "Author: Your Name"
);

// Validate SDK version
VALIDATE_COMPONENT_FILENAME("foo_mycomponent.component");

// Optional: Initialization
namespace {
    class mycomponent_initquit : public initquit {
    public:
        void on_init() override {
            console::info("My Component initialized");
        }
        void on_quit() override {
            console::info("My Component shutting down");
        }
    };

    FB2K_SERVICE_FACTORY(mycomponent_initquit);
}
```

## 5. SDK Library Linking

### Required Libraries (5 static libraries + 1 framework)

| Library | Location | Purpose |
|---------|----------|---------|
| `libfoobar2000_SDK.a` | `SDK/build/Release/` | Core SDK |
| `libfoobar2000_SDK_helpers.a` | `helpers/build/Release/` | Helper utilities |
| `libfoobar2000_component_client.a` | `foobar2000_component_client/build/Release/` | Component loader |
| `libshared.a` | `shared/build/Release/` | Shared utilities |
| `libpfc-Mac.a` | `pfc/build/Release/` | Platform foundation |
| `Cocoa.framework` | System | macOS UI framework |

### Building SDK Libraries

Before building your component, build the SDK libraries:

```bash
cd /path/to/SDK-2025-03-07

# Build all SDK projects in Release mode
xcodebuild -project foobar2000/SDK/foobar2000_SDK.xcodeproj -configuration Release
xcodebuild -project foobar2000/helpers/foobar2000_SDK_helpers.xcodeproj -configuration Release
xcodebuild -project foobar2000/foobar2000_component_client/foobar2000_component_client.xcodeproj -configuration Release
xcodebuild -project foobar2000/shared/shared.xcodeproj -configuration Release
xcodebuild -project pfc/pfc.xcodeproj -configuration Release
```

### Header Search Paths
```
$(PROJECT_DIR)/../SDK-2025-03-07
$(PROJECT_DIR)/../SDK-2025-03-07/foobar2000
$(PROJECT_DIR)/../SDK-2025-03-07/pfc
```

### Library Search Paths
```
$(PROJECT_DIR)/../SDK-2025-03-07/foobar2000/SDK/build/Release
$(PROJECT_DIR)/../SDK-2025-03-07/foobar2000/helpers/build/Release
$(PROJECT_DIR)/../SDK-2025-03-07/foobar2000/foobar2000_component_client/build/Release
$(PROJECT_DIR)/../SDK-2025-03-07/foobar2000/shared/build/Release
$(PROJECT_DIR)/../SDK-2025-03-07/pfc/build/Release
```

## 6. Build Configuration

### Xcode Build Settings

| Setting | Value |
|---------|-------|
| Product Type | `com.apple.product-type.bundle` |
| Bundle Extension | `component` |
| Deployment Target | `11.0` (Big Sur - verify against SDK minimum) |
| C++ Language Standard | `gnu++17` (or `gnu++20`) |
| Objective-C ARC | `YES` |
| Code Signing | Automatic |

**Note**: The deployment target should match or exceed the SDK's minimum requirement.
Check the SDK release notes for the exact minimum macOS version supported.

### Build Phases

1. **Sources** - Compile `.cpp`, `.mm`, `.m` files
2. **Frameworks** - Link SDK libraries + Cocoa.framework
3. **Resources** - Copy Info.plist and XIB files

## 7. Build Verification

### Step 1: Generate Xcode Project
```bash
cd foo_mycomponent_mac
ruby Scripts/generate_xcode_project.rb
```

### Step 2: Build
```bash
xcodebuild -project foo_mycomponent.xcodeproj -configuration Release
```

### Step 3: Install for Testing
```bash
# Copy to foobar2000 components folder
cp -r build/Release/foo_mycomponent.component \
  ~/Library/foobar2000-v2/user-components/
```

### Step 4: Verify in foobar2000
1. Launch foobar2000 for Mac
2. Open Preferences > Components
3. Your component should appear in the list
4. Check console output for initialization message

## 8. Common Issues

### Build Fails: Missing Headers
- Ensure SDK is at correct relative path (`../SDK-2025-03-07/`)
- Verify header search paths in Xcode project

### Build Fails: Missing Libraries
- Build SDK projects first (see section 5)
- Verify library search paths

### Component Doesn't Load
- Check bundle extension is `.component`
- Verify `DECLARE_COMPONENT_VERSION` is present
- Check Console.app for error messages

### Linker Errors: Undefined Symbols
- Ensure all 5 SDK libraries are linked
- Check `Cocoa.framework` is included
- Verify C++ standard library is linked

## 9. Next Steps

After your skeleton compiles:

1. **Add UI Elements** - See `04_UI_ELEMENT_IMPLEMENTATION.md`
2. **Register Services** - See `03_SDK_SERVICE_PATTERNS.md`
3. **Implement Features** - Add your component-specific logic
4. **Test Thoroughly** - Use both Debug and Release builds

## References

- [foobar2000 SDK Documentation](https://www.foobar2000.org/SDK)
- [Hydrogenaudio Development Wiki](https://wiki.hydrogenaudio.org/index.php?title=Foobar2000:Development:Overview)
- [foo_sample in SDK](../SDK-2025-03-07/foobar2000/foo_sample/) - Reference implementation
