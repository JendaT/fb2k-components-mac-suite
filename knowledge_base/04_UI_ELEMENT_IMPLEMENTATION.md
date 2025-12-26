# foobar2000 macOS - UI Element Implementation

## Overview

This document covers implementing custom UI elements for foobar2000 on macOS using Cocoa (NSView/NSViewController) and integrating them with the SDK's ui_element_mac interface.

## 1. Layout Editor Name Matching (CRITICAL)

The foobar2000 Layout Editor finds and instantiates UI elements by name using the `match_name()` method. This is **critical for backward compatibility** when renaming components.

### 1.1 How Layout Editor Finds Components

When a user's layout config references a component by name (e.g., `"SimPlaylist"`), the layout editor queries all registered `ui_element_mac` services, calling `match_name()` on each until one returns `true`.

```cpp
// The layout editor essentially does:
for (auto& element : ui_element_services) {
    if (element->match_name(saved_name)) {
        return element->instantiate(arg);
    }
}
```

### 1.2 Supporting Multiple Name Variations

Always support **all possible variations** users might have saved in their layouts:

```cpp
bool match_name(const char* name) override {
    return strcmp(name, "SimPlaylist") == 0 ||           // Display name
           strcmp(name, "simplaylist") == 0 ||           // lowercase
           strcmp(name, "sim_playlist") == 0 ||          // snake_case
           strcmp(name, "Simple Playlist") == 0 ||       // Human readable
           // Legacy names (before renaming)
           strcmp(name, "foo_simplaylist") == 0 ||       // Old component name
           // New jl-prefixed names
           strcmp(name, "foo_jl_simplaylist") == 0 ||    // New component name
           strcmp(name, "jl_simplaylist") == 0;          // Short prefix form
}
```

### 1.3 Why This Matters

| Scenario | Without Proper match_name() | With Proper match_name() |
|----------|----------------------------|--------------------------|
| User upgrades from old version | Layout breaks, component not found | Seamless - works with old saved name |
| Component renamed | Users lose their layouts | Backward compatible |
| Different naming conventions | Only one form works | All reasonable forms work |

### 1.4 Best Practices

1. **Always include the display name** (what `get_name()` returns)
2. **Include lowercase and snake_case variants**
3. **Include legacy names when renaming components** - users may have old layouts
4. **Include both old and new foo_xxx component names**
5. **Document supported names in comments**

### 1.5 Example from JL Components

All JL components support both legacy (pre-jl prefix) and new naming:

```cpp
// foo_jl_plorg_mac/src/Integration/Main.mm
bool match_name(const char* name) override {
    return strcmp(name, "Playlist Organizer") == 0 ||
           strcmp(name, "playlist_organizer") == 0 ||
           strcmp(name, "playlist-organizer") == 0 ||
           strcmp(name, "plorg") == 0 ||
           // Legacy names (pre-jl prefix)
           strcmp(name, "foo_plorg") == 0 ||
           // New jl-prefixed names
           strcmp(name, "foo_jl_plorg") == 0 ||
           strcmp(name, "jl_plorg") == 0;
}
```

---

## 2. NSView vs NSViewController

### 1.1 When to Use NSView

Use a custom NSView subclass when:
- Building a single, self-contained visual component
- Custom drawing is the primary purpose (waveforms, visualizations)
- No complex subview hierarchy needed
- Direct mouse/keyboard handling required

```objc
// WaveformView.h
#import <Cocoa/Cocoa.h>

@interface WaveformView : NSView

@property (nonatomic) double playbackPosition;
@property (nonatomic) double duration;
@property (nonatomic, strong) NSData *waveformData;

- (void)setNeedsDisplayForPlaybackChange;

@end
```

### 1.2 When to Use NSViewController

Use NSViewController when:
- Managing a complex view hierarchy
- Using XIB files for layout
- Need lifecycle management (viewDidLoad, viewWillAppear)
- Building preferences pages

```objc
// PreferencesController.h
#import <Cocoa/Cocoa.h>

@interface PreferencesController : NSViewController

@property (weak) IBOutlet NSButton *enabledCheckbox;
@property (weak) IBOutlet NSSlider *qualitySlider;
@property (weak) IBOutlet NSColorWell *colorWell;

- (IBAction)settingChanged:(id)sender;

@end
```

## 2. XIB File Integration

### 2.1 Creating XIB Files

1. In Xcode: File > New > File > macOS > User Interface > View
2. Name it matching your controller (e.g., `MyPreferences.xib`)
3. Set File's Owner class to your controller class
4. Connect outlets and actions

### 2.2 Loading XIB from Component Bundle

```objc
// CRITICAL: Use bundleForClass to load from component bundle
- (instancetype)init {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    self = [super initWithNibName:@"MyPreferences" bundle:bundle];
    return self;
}

// Or when instantiating from C++
MyPreferencesController* vc = [[MyPreferencesController alloc]
    initWithNibName:@"MyPreferences"
    bundle:[NSBundle bundleForClass:[MyPreferencesController class]]];
```

### 2.3 Common XIB Issues

| Issue | Solution |
|-------|----------|
| "Could not load NIB" | Use `bundleForClass:` not `mainBundle` |
| Outlets not connected | Check File's Owner class in XIB |
| View appears empty | Ensure XIB has top-level view object |

## 3. Dark Mode Support

### 3.1 Detecting Appearance

```objc
- (BOOL)isDarkMode {
    if (@available(macOS 10.14, *)) {
        NSAppearanceName appearanceName =
            [self.effectiveAppearance bestMatchFromAppearancesWithNames:
                @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
        return [appearanceName isEqualToString:NSAppearanceNameDarkAqua];
    }
    return NO;
}

- (NSColor *)waveformColor {
    return [self isDarkMode] ? self.waveColorDark : self.waveColorLight;
}
```

### 3.2 Responding to Appearance Changes

```objc
// Override in NSView subclass
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self setNeedsDisplay:YES];
}

// For NSViewController
- (void)viewDidLoad {
    [super viewDidLoad];

    // Observe appearance changes
    [NSApp addObserver:self
            forKeyPath:@"effectiveAppearance"
               options:NSKeyValueObservingOptionNew
               context:nil];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    if ([keyPath isEqualToString:@"effectiveAppearance"]) {
        [self updateColors];
    }
}
```

### 3.3 Dynamic Colors

```objc
// Use semantic colors that adapt automatically
NSColor *backgroundColor = [NSColor windowBackgroundColor];
NSColor *textColor = [NSColor labelColor];
NSColor *secondaryTextColor = [NSColor secondaryLabelColor];

// Or create custom dynamic colors
NSColor *customColor = [NSColor colorWithName:@"WaveformColor"
                               dynamicProvider:^NSColor * _Nonnull(NSAppearance * _Nonnull appearance) {
    NSAppearanceName name = [appearance bestMatchFromAppearancesWithNames:
                             @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    if ([name isEqualToString:NSAppearanceNameDarkAqua]) {
        return [NSColor colorWithRed:0.3 green:0.7 blue:1.0 alpha:1.0];
    }
    return [NSColor colorWithRed:0.0 green:0.4 blue:0.8 alpha:1.0];
}];
```

## 4. Retina Display Rendering

### 4.1 Getting Scale Factor

```objc
- (CGFloat)scaleFactor {
    return self.window.backingScaleFactor ?: 1.0;
}

// Use in drawing
- (void)drawRect:(NSRect)dirtyRect {
    CGFloat scale = [self scaleFactor];
    CGFloat lineWidth = 1.0 / scale;  // 1 pixel line
    // ...
}
```

### 4.2 Drawing Sharp Lines

```objc
- (void)drawRect:(NSRect)dirtyRect {
    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];

    // Enable antialiasing for smooth curves
    CGContextSetShouldAntialias(ctx, YES);

    // For crisp 1-pixel lines, offset by 0.5
    CGFloat scale = self.window.backingScaleFactor;
    CGFloat offset = 0.5 / scale;

    CGContextSetLineWidth(ctx, 1.0 / scale);

    // Draw vertical line at x=100
    CGContextMoveToPoint(ctx, 100.0 + offset, 0);
    CGContextAddLineToPoint(ctx, 100.0 + offset, self.bounds.size.height);
    CGContextStrokePath(ctx);
}
```

### 4.3 High-Resolution Images

```objc
// Load @2x images automatically
NSImage *icon = [NSImage imageNamed:@"MyIcon"];  // Loads MyIcon@2x.png on Retina

// Or use Assets.xcassets with 1x, 2x, 3x variants
```

## 5. Mouse Event Handling

### 5.1 Click Handling

```objc
- (void)mouseDown:(NSEvent *)event {
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];

    // Convert to normalized position (0.0 to 1.0)
    CGFloat normalizedX = location.x / self.bounds.size.width;

    // Convert to time
    double seekTime = normalizedX * self.duration;

    // Perform seek
    [self seekToTime:seekTime];
}
```

### 5.2 Drag Handling

```objc
@property (nonatomic) BOOL isDragging;
@property (nonatomic) double dragStartPosition;

- (void)mouseDown:(NSEvent *)event {
    self.isDragging = YES;
    [self updatePositionFromEvent:event];
}

- (void)mouseDragged:(NSEvent *)event {
    if (self.isDragging) {
        [self updatePositionFromEvent:event];
    }
}

- (void)mouseUp:(NSEvent *)event {
    if (self.isDragging) {
        [self updatePositionFromEvent:event];
        [self commitSeek];
        self.isDragging = NO;
    }
}

- (void)updatePositionFromEvent:(NSEvent *)event {
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];
    double time = (location.x / self.bounds.size.width) * self.duration;
    time = MAX(0, MIN(time, self.duration));
    self.previewPosition = time;
    [self setNeedsDisplay:YES];
}
```

### 5.3 Tracking Areas for Hover Effects

```objc
- (void)updateTrackingAreas {
    [super updateTrackingAreas];

    // Remove existing tracking areas
    for (NSTrackingArea *area in self.trackingAreas) {
        [self removeTrackingArea:area];
    }

    // Add new tracking area
    NSTrackingArea *trackingArea = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:(NSTrackingMouseEnteredAndExited |
                      NSTrackingMouseMoved |
                      NSTrackingActiveInKeyWindow)
               owner:self
            userInfo:nil];
    [self addTrackingArea:trackingArea];
}

- (void)mouseEntered:(NSEvent *)event {
    self.isHovering = YES;
    [self setNeedsDisplay:YES];
}

- (void)mouseExited:(NSEvent *)event {
    self.isHovering = NO;
    [self setNeedsDisplay:YES];
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];
    self.hoverPosition = location.x / self.bounds.size.width;
    [self setNeedsDisplay:YES];
}
```

## 6. Timer-Based Animation

### 6.1 Display Link for 60 FPS

**IMPORTANT**: CVDisplayLinkRef is a Core Foundation type, not an Objective-C object.
Do not use `strong` - you must manually manage its lifecycle.

```objc
// NOTE: CVDisplayLinkRef is CF type - no ARC, must manually release
@property (nonatomic) CVDisplayLinkRef displayLink;

- (void)startAnimation {
    if (_displayLink) return;  // Already running

    CVDisplayLinkCreateWithActiveCGDisplays(&_displayLink);
    CVDisplayLinkSetOutputCallback(_displayLink, &displayLinkCallback, (__bridge void *)self);
    CVDisplayLinkStart(_displayLink);
}

- (void)stopAnimation {
    if (_displayLink) {
        CVDisplayLinkStop(_displayLink);
        CVDisplayLinkRelease(_displayLink);
        _displayLink = NULL;
    }
}

// CRITICAL: CVDisplayLink runs on a background thread.
// The view's lifecycle is managed by viewDidMoveToWindow - stop the display link
// before the view is deallocated to prevent callbacks to a freed object.
static CVReturn displayLinkCallback(CVDisplayLinkRef displayLink,
                                   const CVTimeStamp *inNow,
                                   const CVTimeStamp *inOutputTime,
                                   CVOptionFlags flagsIn,
                                   CVOptionFlags *flagsOut,
                                   void *displayLinkContext) {
    // Bridge to view - lifecycle managed by viewDidMoveToWindow stopping the link
    WaveformView *view = (__bridge WaveformView *)displayLinkContext;
    dispatch_async(dispatch_get_main_queue(), ^{
        [view updateAndDraw];
    });
    return kCVReturnSuccess;
}

// REQUIRED: Stop display link when view leaves window hierarchy
- (void)viewDidMoveToWindow {
    if (self.window) {
        [self startAnimation];
    } else {
        [self stopAnimation];  // Prevents callbacks after view is gone
    }
}
```

### 6.2 Choosing the Right Animation Technique

| Technique | Use When | Target FPS | Memory | CPU |
|-----------|----------|------------|--------|-----|
| `drawRect:` only | Static or rarely changing UI | <10 | Low | Low |
| NSTimer + `setNeedsDisplay` | Moderate updates (position indicator) | 30 | Low | Medium |
| CVDisplayLink | Smooth animation, visualizers | 60 | Medium | Medium |
| CADisplayLink + Metal | Heavy visualization, real-time audio | 60+ | High | GPU |

### 6.3 NSTimer for Lower Frequency Updates

```objc
@property (nonatomic, strong) NSTimer *updateTimer;

- (void)startUpdates {
    // 30 FPS update timer
    self.updateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/30.0
                                                        target:self
                                                      selector:@selector(timerFired:)
                                                      userInfo:nil
                                                       repeats:YES];
    // Keep timer running during tracking
    [[NSRunLoop currentRunLoop] addTimer:self.updateTimer forMode:NSRunLoopCommonModes];
}

- (void)stopUpdates {
    [self.updateTimer invalidate];
    self.updateTimer = nil;
}

- (void)timerFired:(NSTimer *)timer {
    [self setNeedsDisplay:YES];
}
```

## 7. Core Graphics Rendering

### 7.1 Waveform Data Format

Before drawing, define the expected data format clearly:

```objc
// Waveform peak data structure
// - Values normalized to range [-1.0, 1.0] (standard audio normalization)
// - Fixed bucket count (e.g., 2048 buckets per track regardless of duration)
// - Interleaved min/max pairs: [min0, max0, min1, max1, ...]

typedef struct {
    float min;  // Minimum sample value in bucket (-1.0 to 0.0 typically)
    float max;  // Maximum sample value in bucket (0.0 to 1.0 typically)
} WaveformPeak;

// Example wrapper class
@interface WaveformDataWrapper : NSObject
@property (nonatomic, readonly) const WaveformPeak *peaks;
@property (nonatomic, readonly) NSUInteger bucketCount;  // e.g., 2048
@property (nonatomic, readonly) NSUInteger channelCount; // 1 or 2
@end
```

### 7.2 Basic Waveform Drawing

```objc
- (void)drawRect:(NSRect)dirtyRect {
    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    NSRect bounds = self.bounds;

    // Background
    CGContextSetFillColorWithColor(ctx, self.backgroundColor.CGColor);
    CGContextFillRect(ctx, bounds);

    if (!self.waveformData) return;

    // Draw waveform
    CGContextSetStrokeColorWithColor(ctx, self.waveformColor.CGColor);
    CGContextSetLineWidth(ctx, 1.0);

    CGFloat width = bounds.size.width;
    CGFloat height = bounds.size.height;
    CGFloat centerY = height / 2.0;

    // Waveform data: interleaved min/max pairs, normalized to [-1.0, 1.0]
    const float *peaks = (const float *)self.waveformData.bytes;
    NSUInteger peakCount = self.waveformData.length / sizeof(float) / 2;  // min/max pairs

    for (NSUInteger i = 0; i < peakCount && i < width; i++) {
        CGFloat x = (CGFloat)i / peakCount * width;
        float minVal = peaks[i * 2];      // Range: -1.0 to 0.0 (negative = below center)
        float maxVal = peaks[i * 2 + 1];  // Range: 0.0 to 1.0 (positive = above center)

        // Map normalized audio values to screen coordinates
        // minVal (-1.0) -> centerY + centerY = height (bottom)
        // maxVal (+1.0) -> centerY - centerY = 0 (top)
        CGFloat y1 = centerY - (minVal * centerY);  // Note: subtract because screen Y is inverted
        CGFloat y2 = centerY - (maxVal * centerY);

        CGContextMoveToPoint(ctx, x, y1);
        CGContextAddLineToPoint(ctx, x, y2);
    }
    CGContextStrokePath(ctx);

    // Draw played portion overlay
    if (self.playbackPosition > 0 && self.duration > 0) {
        CGFloat playedWidth = (self.playbackPosition / self.duration) * width;
        CGContextSetFillColorWithColor(ctx, self.playedOverlayColor.CGColor);
        CGContextFillRect(ctx, CGRectMake(0, 0, playedWidth, height));
    }

    // Draw position indicator
    CGFloat posX = (self.playbackPosition / self.duration) * width;
    CGContextSetStrokeColorWithColor(ctx, self.positionIndicatorColor.CGColor);
    CGContextSetLineWidth(ctx, 2.0);
    CGContextMoveToPoint(ctx, posX, 0);
    CGContextAddLineToPoint(ctx, posX, height);
    CGContextStrokePath(ctx);
}
```

### 7.3 Stereo Waveform Drawing

```objc
- (void)drawStereoWaveform:(CGContextRef)ctx inRect:(NSRect)bounds {
    CGFloat height = bounds.size.height;
    CGFloat halfHeight = height / 2.0;

    // Left channel (top half)
    [self drawChannelWaveform:ctx
                     inRect:NSMakeRect(0, halfHeight, bounds.size.width, halfHeight)
                    channel:0
                   inverted:NO];

    // Right channel (bottom half, inverted)
    [self drawChannelWaveform:ctx
                     inRect:NSMakeRect(0, 0, bounds.size.width, halfHeight)
                    channel:1
                   inverted:YES];

    // Center line
    CGContextSetStrokeColorWithColor(ctx, self.centerLineColor.CGColor);
    CGContextSetLineWidth(ctx, 1.0);
    CGContextMoveToPoint(ctx, 0, halfHeight);
    CGContextAddLineToPoint(ctx, bounds.size.width, halfHeight);
    CGContextStrokePath(ctx);
}

- (void)drawChannelWaveform:(CGContextRef)ctx
                    inRect:(NSRect)rect
                   channel:(NSUInteger)channel
                  inverted:(BOOL)inverted {
    // Implementation for single channel
}
```

## 8. Layer-Backed Views

### 8.1 Enabling Layer Backing

```objc
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    }
    return self;
}
```

### 8.2 Using CALayer for Performance

```objc
- (CALayer *)makeBackingLayer {
    CALayer *layer = [CALayer layer];
    layer.drawsAsynchronously = YES;
    return layer;
}

- (BOOL)wantsUpdateLayer {
    return YES;  // Use updateLayer instead of drawRect
}

- (void)updateLayer {
    // Update layer contents directly
    self.layer.backgroundColor = self.backgroundColor.CGColor;

    // For complex drawing, render to CGImage
    CGImageRef image = [self renderWaveformImage];
    self.layer.contents = (__bridge id)image;
    CGImageRelease(image);
}
```

## 9. Accessibility

### 9.1 Basic Accessibility Support

```objc
- (BOOL)isAccessibilityElement {
    return YES;
}

- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilitySliderRole;
}

- (NSString *)accessibilityLabel {
    return @"Waveform Seekbar";
}

- (NSString *)accessibilityValue {
    return [NSString stringWithFormat:@"%.0f seconds of %.0f",
            self.playbackPosition, self.duration];
}

- (BOOL)accessibilityPerformIncrement {
    [self seekRelative:5.0];  // Skip forward 5 seconds
    return YES;
}

- (BOOL)accessibilityPerformDecrement {
    [self seekRelative:-5.0];  // Skip back 5 seconds
    return YES;
}
```

## 10. Memory Management

### 10.1 Cleanup Pattern

```objc
- (void)dealloc {
    [self stopAnimation];
    [self.updateTimer invalidate];

    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidMoveToWindow {
    if (self.window) {
        [self startAnimation];
    } else {
        [self stopAnimation];
    }
}
```

### 10.2 Weak References for Callbacks

```objc
// IMPORTANT: Capture data locally before dispatching to background
// Do NOT call self methods from background thread

// Capture input data locally (immutable copy)
NSData *inputData = [self.audioData copy];

__weak typeof(self) weakSelf = self;
dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    // Background work - use only local variables, not self
    NSData *result = [WaveformProcessor processAudioData:inputData];

    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            strongSelf.waveformData = result;
            [strongSelf setNeedsDisplay:YES];
        }
    });
});
```

**Common mistake to avoid:**
```objc
// WRONG - calls self from background thread
dispatch_async(background_queue, ^{
    NSData *result = [self processWaveform];  // BAD: accesses self on background
});
```

## Best Practices

1. **Use `bundleForClass:`** - Never use `mainBundle` for component resources
2. **Support dark mode** - Implement `viewDidChangeEffectiveAppearance`
3. **Handle Retina** - Use `backingScaleFactor` for pixel-perfect rendering
4. **Clean up timers** - Stop in `dealloc` and when view leaves window
5. **Use weak self** - In blocks to avoid retain cycles
6. **Layer-back for performance** - For frequently updating views
7. **Accessibility** - Implement basic accessibility for all interactive elements
