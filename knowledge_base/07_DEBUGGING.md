# foobar2000 macOS - Debugging & Profiling Guide

## Overview

This document covers debugging foobar2000 macOS components, using Xcode debugging tools, Console.app for log filtering, Instruments for profiling, and diagnosing common issues.

## 1. Xcode Debugging Setup

### 1.1 Attaching to foobar2000

Since foobar2000 is a separate application, you need to attach the debugger:

**Method 1: Attach to Running Process**
1. Build your component in Debug configuration
2. Install to `~/Library/foobar2000-v2/user-components/`
3. Launch foobar2000
4. In Xcode: Debug > Attach to Process > foobar2000

**Method 2: Auto-Attach on Launch**
1. In Xcode: Product > Scheme > Edit Scheme
2. Select "Run" on the left
3. Set "Executable" to foobar2000.app (Browse to Applications folder)
4. Click Run - Xcode will launch foobar2000 with debugger attached

### 1.2 Breakpoint Configuration

```
// Useful breakpoints to set:

// 1. Component initialization
on_init()  // In your initquit implementation

// 2. Playback events
on_playback_new_track()
on_playback_stop()

// 3. UI element creation
createView()  // In ui_element_mac

// 4. Preferences page
instantiate()  // In preferences_page
```

### 1.3 Debugging Objective-C and C++ Together

When debugging mixed code:

```lldb
# Print Objective-C object
po myNSObject

# Print C++ object (may need type cast)
p *(WaveformData*)ptr

# Print service_ptr contents
p m_service.get_ptr()

# Print pfc::string8
p myString.c_str()

# Print std::vector
p myVector[0]
p (size_t)myVector.size()
```

### 1.4 Symbolic Breakpoints

Set breakpoints on SDK functions:

| Function | Purpose |
|----------|---------|
| `console::info` | Catch all info logs |
| `console::error` | Catch errors |
| `pfc::exception::exception` | All exceptions |
| `objc_exception_throw` | Objective-C exceptions |

## 2. Console Logging

### 2.1 SDK Logging Functions

```cpp
// Levels
console::info("Info message");
console::warning("Warning message");
console::error("Error message");

// Formatted output
console::formatter() << "Value: " << value << ", Name: " << name;

// Print variable info
console::formatter() << "Track: " << track->get_path()
                     << " Duration: " << track->get_length();
```

### 2.2 Viewing Logs in Console.app

1. Open Console.app (Applications > Utilities > Console)
2. Select your Mac in the sidebar
3. In the search field, type: `foobar2000` or your component name
4. Filter by process: Right-click > Show Process

**Pro tip**: Include a unique prefix in your log messages:
```cpp
console::info("[WaveSeek] Scanning started");
console::info("[WaveSeek] Cache hit for track");
```

### 2.3 Debug-Only Logging

```cpp
#ifdef DEBUG
#define WAVE_LOG(msg) console::info(msg)
#define WAVE_LOGF(...) console::formatter() << __VA_ARGS__
#else
#define WAVE_LOG(msg) ((void)0)
#define WAVE_LOGF(...) ((void)0)
#endif

// Usage
WAVE_LOG("[WaveSeek] Initializing");
WAVE_LOGF("[WaveSeek] Processing " << count << " samples");
```

## 3. Instruments Profiling

### 3.1 Time Profiler

For CPU performance analysis:

1. Open Instruments (Xcode > Open Developer Tool > Instruments)
2. Choose "Time Profiler"
3. Click the target dropdown > Choose Target > foobar2000
4. Click Record
5. Trigger the operation you want to profile
6. Stop recording
7. Analyze the call tree

**What to look for:**
- Functions taking >10% of time
- Deep call stacks indicating inefficient code
- Unexpected framework calls

### 3.2 Allocations

For memory analysis:

1. Choose "Allocations" instrument
2. Record while using your component
3. Look for:
   - Memory growth over time (leaks)
   - Excessive allocations in hot paths
   - Large allocations

**Mark generations** to compare memory before/after operations:
- Click "Mark Generation" before an operation
- Perform the operation
- Click "Mark Generation" after
- Expand to see what was allocated

### 3.3 Leaks

1. Choose "Leaks" instrument
2. Run your component through typical usage
3. Leaks will be flagged automatically
4. Click a leak to see the allocation backtrace

### 3.4 System Trace

For understanding threading and I/O:

1. Choose "System Trace"
2. Record during audio playback
3. Analyze:
   - Thread scheduling
   - System calls
   - I/O operations

## 4. Common Crash Causes

### 4.0 Static Initialization Crash (Segfault on Load)

**Symptom**: Segmentation fault immediately after "Pre component load" message, before component services are registered.

**Cause**: Creating SDK-dependent objects as static globals. These initialize during dylib load, BEFORE the foobar2000 SDK is ready.

```cpp
// BAD - crashes on load
class my_playlist_callback : public playlist_callback_single_impl_base {
    my_playlist_callback() : playlist_callback_single_impl_base(flags) {}
    // ...
};
static my_playlist_callback g_callback;  // CRASH - SDK not ready
```

**Diagnosis**:
1. Move component out of user-components folder
2. Run foobar2000 - if it works, your component is the problem
3. Look for static objects that inherit from SDK classes

**Fix**: Defer creation to `initquit::on_init()`:

```cpp
// GOOD - created after SDK is ready
static my_playlist_callback* g_callback = nullptr;

class my_init : public initquit {
    void on_init() override {
        g_callback = new my_playlist_callback();
    }
    void on_quit() override {
        delete g_callback;
        g_callback = nullptr;
    }
};
FB2K_SERVICE_FACTORY(my_init);
```

**Safe patterns**:
- `FB2K_SERVICE_FACTORY` - handles timing correctly
- Pointer + `initquit::on_init()` - for objects needing SDK access
- Plain static data (no SDK calls in constructor) - always safe

### 4.1 EXC_BAD_ACCESS

**Cause**: Accessing freed memory or null pointer

**Common scenarios:**
```cpp
// 1. Using service_ptr after it's invalid
metadb_handle_ptr track;
playback_control::get()->get_now_playing(track);
// Later, playback stopped but you still use track
track->get_path();  // CRASH if track is now null

// Fix: Always check validity
if (!track.is_empty()) {
    track->get_path();
}
```

```objc
// 2. CVDisplayLink callback after view deallocated
// The callback fires but 'self' is freed
static CVReturn callback(void *ctx) {
    WaveformView *view = (__bridge WaveformView *)ctx;
    [view update];  // CRASH if view is deallocated
}

// Fix: Stop display link in viewDidMoveToWindow when window is nil
```

### 4.2 Exception in Callback

**Cause**: Unhandled exception escaping SDK callback

```cpp
// BAD - exception crashes foobar2000
void on_playback_new_track(metadb_handle_ptr track) override {
    throw std::runtime_error("oops");  // CRASH
}

// GOOD - catch all exceptions
void on_playback_new_track(metadb_handle_ptr track) override {
    try {
        // Your code
    }
    catch (const std::exception& e) {
        console::formatter() << "Error: " << e.what();
    }
    catch (...) {
        console::error("Unknown exception");
    }
}
```

### 4.3 Main Thread Deadlock

**Cause**: Calling `fb2k::inMainThread` from main thread

```cpp
// BAD - deadlocks if already on main thread
void update() {
    fb2k::inMainThread([=]() {
        // This blocks forever if called from main thread
    });
}

// GOOD - check thread first
void update() {
    if ([NSThread isMainThread]) {
        doUpdate();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            doUpdate();
        });
    }
}
```

### 4.4 Thread Safety Violations

**Cause**: Accessing non-thread-safe data from multiple threads

```objc
// BAD - modifying UI from background thread
dispatch_async(background_queue, ^{
    self.waveformData = processedData;  // CRASH - not thread safe
    [self setNeedsDisplay:YES];         // CRASH - UI must be on main thread
});

// GOOD - dispatch UI updates to main thread
dispatch_async(background_queue, ^{
    NSData *result = [self processData];

    dispatch_async(dispatch_get_main_queue(), ^{
        self.waveformData = result;
        [self setNeedsDisplay:YES];
    });
});
```

## 5. Memory Debugging

### 5.1 Enable Address Sanitizer

In Xcode:
1. Product > Scheme > Edit Scheme
2. Run > Diagnostics
3. Enable "Address Sanitizer"

This catches:
- Use after free
- Buffer overflows
- Stack buffer overflows

### 5.2 Enable Zombie Objects

For Objective-C memory issues:
1. Edit Scheme > Run > Diagnostics
2. Enable "Zombie Objects"

This replaces freed objects with zombies that log when accessed.

### 5.3 malloc Debugging

Set environment variables in scheme:

| Variable | Value | Purpose |
|----------|-------|---------|
| `MallocStackLogging` | `1` | Track allocations |
| `MallocScribble` | `1` | Fill freed memory with 0x55 |
| `MallocGuardEdges` | `1` | Detect buffer overruns |

## 6. Component Doesn't Load

### 6.1 Diagnostic Steps

1. **Check Console.app** for loading errors:
   ```
   foobar2000: Failed to load component: foo_mycomponent
   foobar2000: dlopen error: ...
   ```

2. **Check library dependencies**:
   ```bash
   otool -L build/Release/foo_mycomponent.component/Contents/MacOS/foo_mycomponent
   ```

3. **Verify component structure**:
   ```bash
   ls -la build/Release/foo_mycomponent.component/Contents/
   # Should have: Info.plist, MacOS/foo_mycomponent
   ```

4. **Check code signing**:
   ```bash
   codesign -dv build/Release/foo_mycomponent.component
   ```

### 6.2 Common Loading Issues

| Error | Cause | Fix |
|-------|-------|-----|
| "Library not loaded" | Missing SDK library | Verify library search paths |
| "Symbol not found" | SDK version mismatch | Rebuild against current SDK |
| "Code signature invalid" | Signing issue | Re-sign or disable Gatekeeper |
| "Component version" error | Missing DECLARE_COMPONENT_VERSION | Add macro to Main.mm |

## 7. Debug Build Configuration

### 7.1 Recommended Debug Settings

```ruby
# In generate_xcode_project.rb
DEBUG_SETTINGS = {
    "GCC_OPTIMIZATION_LEVEL" => "0",
    "GCC_PREPROCESSOR_DEFINITIONS" => '("DEBUG=1", "$(inherited)")',
    "ENABLE_TESTABILITY" => "YES",
    "ONLY_ACTIVE_ARCH" => "YES",
    "DEBUG_INFORMATION_FORMAT" => "dwarf",
    "GCC_GENERATE_DEBUGGING_SYMBOLS" => "YES"
}
```

### 7.2 Debug Assertions

```cpp
#include <cassert>

void process(audio_chunk* chunk) {
    assert(chunk != nullptr);  // Debug-only check
    assert(chunk->get_sample_count() > 0);

    // Processing...
}
```

## 8. Testing Strategies

### 8.1 Unit Testing

Create a test target in Xcode:

```objc
// WaveformDataTests.mm
#import <XCTest/XCTest.h>
#include "WaveformData.h"

@interface WaveformDataTests : XCTestCase
@end

@implementation WaveformDataTests

- (void)testSerialization {
    WaveformData data;
    // Set up test data...

    std::vector<uint8_t> serialized;
    data.serialize(serialized);

    WaveformData restored;
    XCTAssertTrue(restored.deserialize(serialized.data(), serialized.size()));
    XCTAssertEqual(data.channelCount, restored.channelCount);
}

- (void)testCompression {
    WaveformData data;
    // Set up test data...

    auto compressed = data.compress();
    auto decompressed = WaveformData::decompress(compressed.data(),
                                                  compressed.size());

    XCTAssertTrue(decompressed.isValid());
}

@end
```

### 8.2 Integration Testing

Test with various audio formats:

```cpp
void test_scanner() {
    std::vector<std::string> test_files = {
        "/path/to/test.flac",
        "/path/to/test.mp3",
        "/path/to/test.aac",
        "/path/to/test.wav"
    };

    for (const auto& path : test_files) {
        playable_location_impl loc;
        loc.set_path(path.c_str());

        try {
            auto result = scanner.scan(loc, abort_callback_dummy());
            console::formatter() << "Scanned: " << path
                                << " Duration: " << result.duration;
        }
        catch (const std::exception& e) {
            console::formatter() << "FAILED: " << path << " - " << e.what();
        }
    }
}
```

## 9. Performance Regression Testing

### 9.1 Timing Measurements

```cpp
#include <mach/mach_time.h>

class ScopedTimer {
    uint64_t m_start;
    const char* m_name;

public:
    ScopedTimer(const char* name) : m_name(name) {
        m_start = mach_absolute_time();
    }

    ~ScopedTimer() {
        uint64_t end = mach_absolute_time();
        uint64_t elapsed = end - m_start;

        mach_timebase_info_data_t info;
        mach_timebase_info(&info);

        double ms = (double)elapsed * info.numer / info.denom / 1e6;
        console::formatter() << m_name << ": " << ms << " ms";
    }
};

// Usage
void scan_file() {
    ScopedTimer timer("Waveform scan");
    // Scanning code...
}
```

### 9.2 Automated Performance Tests

```cpp
void performance_test() {
    const int ITERATIONS = 100;
    double total_ms = 0;

    for (int i = 0; i < ITERATIONS; i++) {
        uint64_t start = mach_absolute_time();

        // Code to test
        process_chunk(test_chunk);

        uint64_t end = mach_absolute_time();
        total_ms += convert_to_ms(end - start);
    }

    double avg = total_ms / ITERATIONS;
    console::formatter() << "Average time: " << avg << " ms";

    // Assert performance target
    assert(avg < 5.0);  // Must complete in under 5ms
}
```

## Best Practices

1. **Always test Debug builds** - Catches issues hidden by optimization
2. **Use Address Sanitizer** - Finds memory bugs early
3. **Log with prefixes** - Makes filtering easy in Console.app
4. **Profile before optimizing** - Don't guess at performance issues
5. **Test multiple formats** - Different codecs have different behaviors
6. **Test with short buffers** - Some configurations use 64-sample buffers
7. **Reproduce crashes** - Get consistent repro before debugging
8. **Check Console.app first** - Often has the answer
