# Settings Persistence and UI Update Patterns

This document covers key patterns for settings management, UI updates, and dynamic rendering in foobar2000 macOS components, based on lessons learned from building foo_wave_seekbar_mac.

## 1. Settings Persistence with fb2k::configStore

### The Problem with cfg_var
Traditional `cfg_var_legacy` does **NOT persist** on macOS foobar2000 v2. It's designed for Windows file-based config only. Attempting to use `cfg_var_modern` results in linker errors due to missing SDK implementations.

### The Solution: fb2k::configStore API
foobar2000 v2 on macOS uses SQLite-backed config storage via `fb2k::configStore`:

```cpp
// ConfigHelper.h - Wrapper for safe config access
#pragma once
#include "../fb2k_sdk.h"

namespace waveform_config {

inline int64_t getConfigInt(const char* key, int64_t defaultValue) {
    try {
        auto store = fb2k::configStore::get();
        if (store) {
            return store->getConfigInt(key, defaultValue);
        }
    } catch (...) {}
    return defaultValue;
}

inline void setConfigInt(const char* key, int64_t value) {
    try {
        auto store = fb2k::configStore::get();
        if (store) {
            store->setConfigInt(key, value);
        }
    } catch (...) {}
}

inline bool getConfigBool(const char* key, bool defaultValue) {
    return getConfigInt(key, defaultValue ? 1 : 0) != 0;
}

inline void setConfigBool(const char* key, bool value) {
    setConfigInt(key, value ? 1 : 0);
}

// Define config keys as constants
static const char* const kKeyDisplayMode = "display_mode";
static const char* const kKeyCacheSizeMB = "cache_size_mb";
// ... more keys

} // namespace waveform_config
```

### Key Points
- Always wrap configStore calls in try/catch - the store may not be available during shutdown
- Use consistent key naming: `component_name.setting_name` pattern recommended
- Config is persisted automatically by foobar2000 at shutdown
- Debug: Run foobar2000 from CLI to see `setConfigInt()` calls logged at shutdown

---

## 2. Dynamic Settings Updates

### The Problem
Views don't automatically respond to preference changes. Users change settings in Preferences, but the UI doesn't update.

### The Solution: NSNotificationCenter Pattern

**Step 1: Define notification name**
```objc
// Use a unique notification name
static NSString *const kSettingsChangedNotification = @"WaveformSeekbarSettingsChanged";
```

**Step 2: Post notification from Preferences**
```objc
// In WaveformPreferences.mm
- (void)notifySettingsChanged {
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"WaveformSeekbarSettingsChanged"
                      object:nil];
}

- (void)displayModeChanged:(id)sender {
    using namespace waveform_config;
    setConfigInt(kKeyDisplayMode, [_displayModePopup indexOfSelectedItem]);
    [self notifySettingsChanged];  // Always notify after saving
}
```

**Step 3: Observe in View**
```objc
// In WaveformSeekbarView.mm
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // Register for settings changes
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(handleSettingsChanged:)
                   name:@"WaveformSeekbarSettingsChanged"
                 object:nil];
        [self reloadSettings];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handleSettingsChanged:(NSNotification *)notification {
    [self reloadSettings];
}

- (void)reloadSettings {
    using namespace waveform_config;
    _displayMode = static_cast<WaveformDisplayMode>(
        getConfigInt(kKeyDisplayMode, kDefaultDisplayMode));
    _shadePlayedPortion = getConfigBool(kKeyShadePlayedPortion, kDefaultShadePlayedPortion);
    // ... load all settings

    [self setNeedsDisplay:YES];  // Trigger redraw
}
```

---

## 3. Preferences Page Layout

### Flipped Coordinate System
macOS uses bottom-left origin by default. For top-down layout (like Windows), create a flipped container:

```objc
@interface FlippedView : NSView
@end

@implementation FlippedView
- (BOOL)isFlipped { return YES; }
@end

// In loadView:
- (void)loadView {
    FlippedView *container = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, 450, 400)];
    self.view = container;
    [self buildUI];
}
```

### Layout Pattern
```objc
- (void)buildUI {
    CGFloat labelX = 20;
    CGFloat controlX = 130;
    CGFloat y = 15;  // Start from top (flipped coordinates)

    // Section header
    [self.view addSubview:[self createLabel:@"Display" at:NSMakePoint(labelX, y)]];
    y += 22;

    // Control row
    [self.view addSubview:[self createLabel:@"Mode:" at:NSMakePoint(labelX + 10, y + 3)]];
    _modePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, 150, 25)];
    [_modePopup addItemWithTitle:@"Option 1"];
    [_modePopup setTarget:self];
    [_modePopup setAction:@selector(modeChanged:)];
    [self.view addSubview:_modePopup];
    y += 30;

    // Checkbox
    _checkbox = [[NSButton alloc] initWithFrame:NSMakeRect(labelX + 10, y, 250, 20)];
    _checkbox.buttonType = NSButtonTypeSwitch;
    _checkbox.title = @"Enable feature";
    [_checkbox setTarget:self];
    [_checkbox setAction:@selector(checkboxChanged:)];
    [self.view addSubview:_checkbox];
    y += 30;
}

- (NSTextField *)createLabel:(NSString *)text at:(NSPoint)point {
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(point.x, point.y, 200, 17)];
    label.stringValue = text;
    label.bezeled = NO;
    label.editable = NO;
    label.drawsBackground = NO;
    label.font = [NSFont systemFontOfSize:11];
    return label;
}
```

---

## 4. Core Graphics Waveform Rendering

### Basic Pattern
```objc
- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    CGContextRef context = [[NSGraphicsContext currentContext] CGContext];
    CGRect bounds = self.bounds;

    // Draw background
    [self.backgroundColor setFill];
    NSRectFill(bounds);

    // Draw waveform
    [self drawWaveformInContext:context bounds:bounds];

    // Draw played overlay
    [self drawPlayedOverlayInContext:context bounds:bounds];
}
```

### Color Handling
Always convert to device RGB for Core Graphics:
```objc
NSColor *deviceColor = [self.waveformColor colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]];
if (!deviceColor) deviceColor = self.waveformColor;

CGFloat r = deviceColor.redComponent;
CGFloat g = deviceColor.greenComponent;
CGFloat b = deviceColor.blueComponent;

CGContextSetRGBStrokeColor(context, r, g, b, alpha);
```

### Gradient Bands for Fade Effect
Draw waveform in multiple passes with decreasing alpha for smooth fade:
```objc
const int gradientBands = 8;
for (int band = 0; band < gradientBands; band++) {
    CGFloat bandStart = (CGFloat)band / gradientBands;
    CGFloat bandEnd = (CGFloat)(band + 1) / gradientBands;
    CGFloat alpha = 1.0 - (bandStart * 0.6);  // Fade from 1.0 to 0.4

    CGContextSetRGBStrokeColor(context, r, g, b, alpha);
    CGContextSetLineWidth(context, 1.0);
    CGContextBeginPath(context);

    for (size_t i = 0; i < bucketCount; i++) {
        CGFloat peakVal = data[i];
        if (peakVal > bandStart) {
            CGFloat drawPeak = MIN(peakVal, bandEnd);
            // Draw line segment for this band
        }
    }
    CGContextStrokePath(context);
}
```

### Stereo Layout
Draw L/R channels in separate halves:
```objc
CGFloat quarterHeight = viewHeight / 4.0;
CGFloat channelAmplitude = quarterHeight - padding;
CGFloat leftCenterY = viewHeight * 0.75;   // Top half
CGFloat rightCenterY = viewHeight * 0.25;  // Bottom half
```

---

## 5. Animated Effects

### Time-Based Animation
Use `CFAbsoluteTimeGetCurrent()` for smooth, frame-independent animation:
```objc
CGFloat time = CFAbsoluteTimeGetCurrent();
CGFloat pulse = 0.5 + 0.5 * sin(time * frequency * 2.0 * M_PI);
```

### BPM Sync Pattern
Read BPM from track metadata and use it to drive animation frequency:
```objc
// In callback when track changes
const char* bpmStr = info.meta_get("BPM", 0);
if (!bpmStr) bpmStr = info.meta_get("bpm", 0);
if (!bpmStr) bpmStr = info.meta_get("TBPM", 0);  // ID3v2 frame
if (bpmStr) {
    bpm = atof(bpmStr);
}

// In view
- (CGFloat)animationFrequencyWithDefault:(CGFloat)defaultHz {
    if (self.bpmSync && self.trackBpm > 0) {
        return self.trackBpm / 60.0;  // BPM to Hz
    }
    return defaultHz;
}
```

### 60 FPS Timer for Smooth Updates
```objc
- (void)startPositionTimer {
    [self stopPositionTimer];
    _positionTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/60.0
                                                      target:self
                                                    selector:@selector(updatePosition:)
                                                    userInfo:nil
                                                     repeats:YES];
}

- (void)updatePosition:(NSTimer *)timer {
    // Update playback position and redraw
    [self.waveformView setNeedsDisplay:YES];
}
```

---

## 6. Heat Map / Rainbow Coloring

### Amplitude to Color (Heat Map)
```objc
- (void)getHeatMapColorForAmplitude:(CGFloat)amplitude
                                  r:(CGFloat*)r g:(CGFloat*)g b:(CGFloat*)b {
    amplitude = MAX(0.0, MIN(1.0, amplitude));

    if (amplitude < 0.25) {
        // Blue to Cyan
        *r = 0.0; *g = amplitude / 0.25; *b = 1.0;
    } else if (amplitude < 0.5) {
        // Cyan to Green
        CGFloat t = (amplitude - 0.25) / 0.25;
        *r = 0.0; *g = 1.0; *b = 1.0 - t;
    } else if (amplitude < 0.75) {
        // Green to Yellow
        CGFloat t = (amplitude - 0.5) / 0.25;
        *r = t; *g = 1.0; *b = 0.0;
    } else {
        // Yellow to Red
        CGFloat t = (amplitude - 0.75) / 0.25;
        *r = 1.0; *g = 1.0 - t; *b = 0.0;
    }
}
```

### Position to Color (Rainbow)
```objc
- (void)getRainbowColorForPosition:(CGFloat)position
                                 r:(CGFloat*)r g:(CGFloat*)g b:(CGFloat*)b {
    CGFloat hue = fmod(position, 1.0);
    // HSV to RGB conversion with S=1, V=1
    int hi = (int)(hue * 6.0) % 6;
    CGFloat f = hue * 6.0 - (int)(hue * 6.0);

    switch (hi) {
        case 0: *r = 1.0; *g = f;     *b = 0.0;   break;
        case 1: *r = 1-f; *g = 1.0;   *b = 0.0;   break;
        case 2: *r = 0.0; *g = 1.0;   *b = f;     break;
        case 3: *r = 0.0; *g = 1.0-f; *b = 1.0;   break;
        case 4: *r = f;   *g = 0.0;   *b = 1.0;   break;
        default: *r = 1.0; *g = 0.0;  *b = 1.0-f; break;
    }
}
```

---

## 7. Common Pitfalls

### Memory Management
- **Never pass pointers to local std::optional** - causes use-after-free
- Controller should store owned copy: `std::unique_ptr<WaveformData> _storedWaveform`
- Pass `.get()` to view for display

### Race Conditions
- Avoid duplicate async requests from multiple code paths
- Use a single point of control for waveform requests

### Dark Mode
```objc
- (void)viewDidChangeEffectiveAppearance {
    [self updateColorsForAppearance];
    [self setNeedsDisplay:YES];
}

- (void)updateColorsForAppearance {
    BOOL isDark = [self.effectiveAppearance.name
        containsString:NSAppearanceNameDarkAqua];
    // Select appropriate color set
}
```

### Retina Support
```objc
CGFloat scale = self.window.backingScaleFactor;
// Use scale for high-resolution rendering if needed
```

---

## 8. Debugging Tips

### Console Output
Run foobar2000 from CLI to see all console messages:
```bash
pkill -x foobar2000; sleep 1; /Applications/foobar2000.app/Contents/MacOS/foobar2000
```

### Verifying Component Load
When foobar2000 starts from CLI, it logs component loading. Use this to verify builds work at runtime (not just compile):

```
2025-12-26 17:59:29.285 foobar2000[98621:464287] Component : foo_plorg API 81
2025-12-26 17:59:29.285 foobar2000[98621:464287] Added 5 services
2025-12-26 17:59:29.289 foobar2000[98621:464287] Component : foo_simplaylist API 81
2025-12-26 17:59:29.289 foobar2000[98621:464287] Added 5 services
2025-12-26 17:59:29.294 foobar2000[98621:464287] Component : foo_scrobble API 81
2025-12-26 17:59:29.294 foobar2000[98621:464287] Added 4 services
2025-12-26 17:59:29.296 foobar2000[98621:464287] Component : foo_wave_seekbar API 81
2025-12-26 17:59:29.296 foobar2000[98621:464287] Added 6 services
2025-12-26 17:59:29.296 foobar2000[98621:464287] Total: 730 services, 130 classes
2025-12-26 17:59:29.296 foobar2000[98621:464287] Components loaded in: 0:00.013339
```

A successful load shows:
- **Component name** recognized (e.g., `foo_simplaylist`)
- **API version** (81 = current SDK version)
- **Services registered** (confirms component initialized properly)

If a component fails to load, it will either be missing from the list or show an error message. This verification confirms the binary is valid, loads into the host process, and registers its services correctly.

### Config Debugging
Add logging to config helpers:
```cpp
inline int64_t getConfigInt(const char* key, int64_t defaultValue) {
    try {
        auto store = fb2k::configStore::get();
        if (store) {
            int64_t value = store->getConfigInt(key, defaultValue);
            FB2K_console_formatter() << "[Config] get " << key << " = " << value;
            return value;
        }
    } catch (...) {}
    return defaultValue;
}
```

### View Refresh Issues
If view doesn't update:
1. Check `[self setNeedsDisplay:YES]` is called
2. Verify notification observer is registered
3. Confirm `reloadSettings` reads the correct config keys
4. Check `drawRect:` is being called (add logging)
