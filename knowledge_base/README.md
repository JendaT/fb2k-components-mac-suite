# foobar2000 macOS Component Development - Knowledge Base

This knowledge base provides comprehensive documentation for developing foobar2000 components on macOS.

## Contents

### Getting Started

#### [01_MACOS_COMPONENT_QUICKSTART.md](01_MACOS_COMPONENT_QUICKSTART.md)
Getting started guide for creating a new foobar2000 macOS component:
- Project naming conventions
- Directory structure
- Essential files (fb2k_sdk.h, Prefix.pch, Info.plist, Main.mm)
- SDK library linking
- Build configuration
- Verification steps

#### [02_PROJECT_STRUCTURE_TEMPLATE.md](02_PROJECT_STRUCTURE_TEMPLATE.md)
Complete project structure reference:
- Directory layout template
- File purposes (Core/, Platform/, UI/, Integration/)
- Code examples for each layer
- Scripts organization
- Best practices for separation of concerns

### SDK Integration

#### [03_SDK_SERVICE_PATTERNS.md](03_SDK_SERVICE_PATTERNS.md)
SDK integration patterns:
- Service registration with FB2K_SERVICE_FACTORY
- GUID generation and usage
- ui_element_mac interface implementation
- play_callback integration (with exception handling)
- Configuration with cfg_var
- NSObject wrapping with fb2k::wrapNSObject()
- playback_control API
- **metadb_handle operations** (new)
- **input_helper for audio access** (new)
- **Titleformat API** (new)
- Thread safety patterns (with deadlock warnings)

### UI Development

#### [04_UI_ELEMENT_IMPLEMENTATION.md](04_UI_ELEMENT_IMPLEMENTATION.md)
Cocoa UI development guide:
- NSView vs NSViewController patterns
- XIB file integration
- Dark mode support
- Retina display rendering
- Mouse event handling
- **Timer-based animation with correct CVDisplayLink usage** (updated)
- **Waveform data format specification** (new)
- Core Graphics rendering
- Layer-backed views
- Accessibility
- Memory management patterns

### Build System

#### [05_BUILD_AUTOMATION.md](05_BUILD_AUTOMATION.md)
Build system documentation:
- Xcode project generation with Ruby
- Library and header search paths
- Build phases configuration
- Debug vs Release settings
- Build scripts
- Continuous integration

### Audio Processing

#### [06_AUDIO_PROCESSING.md](06_AUDIO_PROCESSING.md) (NEW)
Audio processing guide for decoders, DSP, and visualizers:
- audio_chunk fundamentals (sample format, channel layout)
- Decoding audio with input_helper
- Waveform generation algorithms
- **Real-time audio constraints** (what NOT to do)
- DSP effect implementation
- Memory pooling for audio
- Performance tips with vDSP/Accelerate

### Debugging & Profiling

#### [07_DEBUGGING.md](07_DEBUGGING.md) (NEW)
Debugging and profiling guide:
- Xcode debugging setup (attaching to foobar2000)
- Console.app log filtering
- Instruments profiling (Time Profiler, Allocations, Leaks)
- Common crash causes and fixes
- Memory debugging (Address Sanitizer, Zombie Objects)
- Component loading issues
- Testing strategies

### Settings & UI Patterns

#### [08_SETTINGS_AND_UI_PATTERNS.md](08_SETTINGS_AND_UI_PATTERNS.md) (NEW)
Practical patterns for settings and UI updates (from foo_wave_seekbar_mac):
- **fb2k::configStore API** - proper config persistence on macOS (cfg_var doesn't work!)
- **NSNotificationCenter pattern** - dynamic settings updates without restart
- **Preferences page layout** - FlippedView, control positioning
- **Core Graphics waveform rendering** - gradient bands, stereo layout
- **Animated effects** - time-based animation, BPM sync from ID3 tags
- **Heat map / Rainbow coloring** - amplitude and position to color mapping
- **Common pitfalls** - memory management, race conditions, dark mode

---

## Prerequisites

- **macOS 11+** (Big Sur or later)
- **Xcode 12+** with Command Line Tools
- **Ruby** (for project generation scripts)
- **foobar2000 for Mac** installed for testing
- **foobar2000 SDK** (2025-03-07 or later)

## Quick Start

1. Read [01_MACOS_COMPONENT_QUICKSTART.md](01_MACOS_COMPONENT_QUICKSTART.md)
2. Copy the project structure from [02_PROJECT_STRUCTURE_TEMPLATE.md](02_PROJECT_STRUCTURE_TEMPLATE.md)
3. Build the SDK libraries (see quickstart guide)
4. Create your component following the patterns

## SDK Location

The SDK should be located at:
```
/path/to/your/projects/
├── SDK-2025-03-07/           # Official SDK
├── foo_scrobble_mac/         # Reference implementation
└── foo_[your_component]_mac/ # Your component
```

## Document Categories

| Category | Documents | Target Audience |
|----------|-----------|-----------------|
| **Getting Started** | 01, 02 | All developers |
| **SDK Integration** | 03 | All developers |
| **UI Development** | 04 | UI component developers |
| **Build System** | 05 | All developers |
| **Audio Processing** | 06 | Decoder/DSP developers |
| **Debugging** | 07 | All developers |
| **Settings & UI** | 08 | UI component developers |

## Reference Implementations

- **foo_scrobble_mac** - Last.fm scrobbler, good example of service patterns
- **foo_sample** (in SDK) - Official SDK sample component

## External Resources

- [foobar2000 SDK](https://www.foobar2000.org/SDK)
- [foobar2000 Components Repository](https://www.foobar2000.org/components)
- [Hydrogenaudio Development Wiki](https://wiki.hydrogenaudio.org/index.php?title=Foobar2000:Development:Overview)

## Changelog

### 2025-12-22
- Created 08_SETTINGS_AND_UI_PATTERNS.md - practical patterns from foo_wave_seekbar_mac
  - fb2k::configStore API (cfg_var doesn't persist on macOS!)
  - NSNotificationCenter for dynamic settings updates
  - Preferences layout with FlippedView
  - Core Graphics waveform rendering techniques
  - Animated effects with BPM sync
  - Heat map / rainbow coloring algorithms

### 2025-12-21
- Added exception handling patterns to play_callback examples (03)
- Fixed CVDisplayLink memory management (04)
- Added waveform data format specification (04)
- Added animation technique comparison table (04)
- Added metadb_handle and input_helper documentation (03)
- Added Titleformat API documentation (03)
- Added deadlock warning for fb2k::inMainThread (03)
- Created 06_AUDIO_PROCESSING.md - audio chunk, real-time constraints, DSP
- Created 07_DEBUGGING.md - Xcode debugging, Instruments, crash diagnosis
