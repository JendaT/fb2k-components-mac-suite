# View Sizing and Container Constraints

**Revision:** 1.1
**Last Updated:** 2026-01-03

This document explains how NSView sizing affects foobar2000 layout containers, and how to prevent components from accidentally limiting their parent container's resizability.

---

## Table of Contents

1. [The Problem](#1-the-problem)
2. [How Container Limiting Happens](#2-how-container-limiting-happens)
3. [The Three Mechanisms](#3-the-three-mechanisms)
4. [Correct Implementation Pattern](#4-correct-implementation-pattern)
5. [Intentional Locking (Waveform Pattern)](#5-intentional-locking-waveform-pattern)
6. [Runtime Debugging](#6-runtime-debugging)
7. [Diagnostic Checklist](#7-diagnostic-checklist)
8. [Component Audit Results](#8-component-audit-results)

---

## 1. The Problem

There are TWO symptom patterns, both caused by improper view sizing configuration:

### 1.1 Can't Shrink (blocked by compression resistance)

**Symptom:** User tries to shrink a column but it snaps back to a minimum width.

**Cause:** A view in that column has:
- `intrinsicContentSize` returning actual dimensions (not NoIntrinsicMetric)
- High `contentCompressionResistancePriority` (750 is default high)

**Diagnosis:** Look for `[HIGH-COMP]` + actual intrinsic dimensions in the column you're shrinking.

### 1.2 Can't Expand (blocked by adjacent view's compression resistance)

**Symptom:** User tries to make a column WIDER but it snaps back SMALLER.

**Cause:** The ADJACENT column (the one that would need to shrink) has a view with:
- `intrinsicContentSize` returning actual dimensions
- High `contentCompressionResistancePriority` (750)

When you expand column A, column B must shrink. If column B contains a view that resists compression, the divider snaps back.

**Diagnosis:** Look for `[HIGH-COMP]` + actual intrinsic dimensions in the ADJACENT column.

**THIS IS THE WORST UX BUG** - the user is dragging the correct divider but a completely different component is blocking them.

### Impact

Users cannot freely arrange their layout. The component "fights" with the user's resize attempts. This creates frustration and a perception of broken software.

---

## 2. How Container Limiting Happens

macOS Auto Layout uses three mechanisms to determine view sizing:

```
┌─────────────────────────────────────────────────────────────────┐
│  foobar2000 Column Container                                    │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  Your Component View                                      │  │
│  │                                                           │  │
│  │  intrinsicContentSize: NSSize(400, 300)  ← "I want to be  │  │
│  │  contentHuggingPriority: 750 (high)         400x300"      │  │
│  │  compressionResistance: 750 (high)                        │  │
│  │                                                           │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                                                 │
│  ← User tries to resize to 200px wide                           │
│  ✗ BLOCKED by compressionResistance at 750                      │
└─────────────────────────────────────────────────────────────────┘
```

When the container tries to shrink:
1. Auto Layout checks the view's `intrinsicContentSize`
2. If the view has high `contentCompressionResistancePriority`, it resists being made smaller
3. The container cannot shrink past the intrinsic size

When the container tries to expand:
1. If the view has high `contentHuggingPriority`, it resists being made larger than intrinsic size
2. The container may not expand the view (less common issue)

---

## 3. The Three Mechanisms

### 3.1 Intrinsic Content Size

```objc
- (NSSize)intrinsicContentSize {
    // WRONG: Returns actual content dimensions
    return NSMakeSize(self.contentWidth, self.contentHeight);

    // CORRECT: No intrinsic size - fill container
    return NSMakeSize(NSViewNoIntrinsicMetric, NSViewNoIntrinsicMetric);
}
```

| Return Value | Behavior |
|--------------|----------|
| `NSViewNoIntrinsicMetric` (-1) | View has no preferred size on this axis |
| Positive value | View prefers this size (may resist resize) |

**Rule:** UI element views (playlist, waveform, album art) should return `NSViewNoIntrinsicMetric` for both dimensions.

### 3.2 Content Hugging Priority

Controls how strongly the view resists being made **larger** than its intrinsic size.

```objc
// Set LOW priority = allow expansion freely
[self setContentHuggingPriority:NSLayoutPriorityDefaultLow  // 250
                 forOrientation:NSLayoutConstraintOrientationHorizontal];
[self setContentHuggingPriority:NSLayoutPriorityDefaultLow
                 forOrientation:NSLayoutConstraintOrientationVertical];

// Or use minimum priority (1) for maximum flexibility
[self setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
[self setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
```

| Priority | Constant | Behavior |
|----------|----------|----------|
| 1 | (minimum) | Will expand freely |
| 250 | `NSLayoutPriorityDefaultLow` | Low resistance to expansion |
| 500 | `NSLayoutPriorityDragThatCanResizeWindow` | Medium |
| 750 | `NSLayoutPriorityDefaultHigh` | High resistance - **AVOID** |
| 1000 | `NSLayoutPriorityRequired` | Will NOT expand - **NEVER USE** |

### 3.3 Content Compression Resistance Priority

Controls how strongly the view resists being made **smaller** than its intrinsic size.

```objc
// Set LOW priority = allow shrinking freely
[self setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow  // 250
                               forOrientation:NSLayoutConstraintOrientationHorizontal];
[self setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                               forOrientation:NSLayoutConstraintOrientationVertical];

// Or use minimum priority (1) for maximum flexibility
[self setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
[self setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
```

| Priority | Behavior |
|----------|----------|
| 1 | Will shrink freely |
| 250 | Low resistance to compression |
| 750 | High resistance - **CAUSES CONTAINER LIMITING** |
| 1000 | Will NOT shrink - **CAUSES HARD LIMIT** |

---

## 4. Correct Implementation Pattern

**Every UI element view MUST implement this pattern in its initializer:**

```objc
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupView];
    }
    return self;
}

- (void)setupView {
    // CRITICAL: Prevent container limiting
    // Set both priorities to minimum (1) for both orientations
    [self setContentHuggingPriority:1
                     forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self setContentHuggingPriority:1
                     forOrientation:NSLayoutConstraintOrientationVertical];
    [self setContentCompressionResistancePriority:1
                                   forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self setContentCompressionResistancePriority:1
                                   forOrientation:NSLayoutConstraintOrientationVertical];

    // ... rest of setup
}

- (NSSize)intrinsicContentSize {
    // Return no intrinsic size - view should fill its container
    return NSMakeSize(NSViewNoIntrinsicMetric, NSViewNoIntrinsicMetric);
}
```

### 4.1 Helper Macro (Optional)

Add to a shared header:

```objc
// JLViewSizing.h
#define JL_MAKE_VIEW_FLEXIBLE(view) do { \
    [(view) setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal]; \
    [(view) setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical]; \
    [(view) setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal]; \
    [(view) setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationVertical]; \
} while(0)
```

Usage:
```objc
- (void)setupView {
    JL_MAKE_VIEW_FLEXIBLE(self);
    // ... rest of setup
}
```

---

## 5. Intentional Locking (Waveform Pattern)

If you **intentionally** want to allow users to lock dimensions (like Waveform Seekbar), use explicit constraints:

```objc
@interface MyController () {
    BOOL _widthLocked;
    BOOL _heightLocked;
    NSLayoutConstraint *_widthConstraint;
    NSLayoutConstraint *_heightConstraint;
}
@end

- (void)toggleLockWidth {
    _widthLocked = !_widthLocked;

    if (_widthLocked) {
        // Lock to current width
        CGFloat currentWidth = self.view.frame.size.width;

        // Remove existing constraint if any
        if (_widthConstraint) {
            [self.view removeConstraint:_widthConstraint];
        }

        // Create exact width constraint with REQUIRED priority
        _widthConstraint = [self.view.widthAnchor constraintEqualToConstant:currentWidth];
        _widthConstraint.priority = NSLayoutPriorityRequired;  // 1000
        _widthConstraint.active = YES;

    } else {
        // Unlock - remove constraint
        if (_widthConstraint) {
            [self.view removeConstraint:_widthConstraint];
            _widthConstraint = nil;
        }
    }
}
```

**Key points:**
- Use explicit `NSLayoutConstraint` objects
- Use `NSLayoutPriorityRequired` (1000) for the constraint
- Provide UI (context menu) to toggle
- Save preference to config
- This is INTENTIONAL and USER-CONTROLLED

---

## 6. Runtime Debugging

### Using JLConstraintDebugger

A runtime debugging helper is available in `shared/JLConstraintDebugger.h`:

```objc
#import "JLConstraintDebugger.h"

// In your component's on_init():
[JLConstraintDebugger enable];

// Enable verbose logging of intrinsicContentSize calls
[JLConstraintDebugger setVerboseLogging:YES];

// Dump the view hierarchy (logs to Console.app)
[JLConstraintDebugger dumpAllWindows];

// Find and highlight suspect views (red border)
NSView *myView = ...;
[JLConstraintDebugger highlightSuspectViews:myView];

// Get detailed info for a specific view
[JLConstraintDebugger logSizingInfo:someView];
```

**Output in Console.app** (filter by "JLConstraint"):
```
[JLConstraint] SimPlaylistView frame:800x600 intrinsic:1200x5000 hug:250/250 comp:750/750 [INTRINSIC] [HIGH-COMP]
[JLConstraint]   NSScrollView frame:800x600 intrinsic:-1x-1 hug:250/250 comp:750/750 [HIGH-COMP]
```

**Issue Markers:**
- `[INTRINSIC]` - View returns actual dimensions from `intrinsicContentSize`
- `[HIGH-HUG]` - High hugging priority (>= 750)
- `[HIGH-COMP]` - High compression resistance (>= 750) - **main cause of snap-back**

### Quick Debug Without Code Changes

Add this to **any** view controller temporarily:

```objc
- (void)viewDidAppear {
    [super viewDidAppear];

    // Dump this view's hierarchy
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [JLConstraintDebugger dumpView:self.view indent:0];
    });
}
```

---

## 7. Diagnostic Checklist

### Finding the Offending Component

When container limiting occurs:

1. **Binary search by disabling components:**
   - Use `fb2k-debug` script to disable half the components
   - If problem persists, it's in the enabled half
   - Repeat until found

2. **Check Console.app for constraint conflicts:**
   - Filter by "foobar2000" or "Unable to simultaneously satisfy constraints"
   - Look for views with high priority constraints

3. **Search codebase for problematic patterns:**

```bash
# Find intrinsicContentSize implementations that return actual sizes
grep -rn "intrinsicContentSize" extensions/ --include="*.mm" -A 5 | \
  grep -v "NSViewNoIntrinsicMetric" | grep -v "return NSMakeSize(-1"

# Find missing priority settings (views without setContent*Priority)
for f in extensions/*/src/UI/*.mm; do
  if grep -q "intrinsicContentSize" "$f"; then
    if ! grep -q "setContentHuggingPriority\|setContentCompressionResistancePriority" "$f"; then
      echo "MISSING PRIORITIES: $f"
    fi
  fi
done

# Find high priority settings (potential problems)
grep -rn "NSLayoutPriorityDefaultHigh\|NSLayoutPriorityRequired\|priority.*750\|priority.*1000" \
  extensions/ --include="*.mm"
```

### Code Review Checklist

For each view class:

- [ ] Does `intrinsicContentSize` return `NSViewNoIntrinsicMetric` for both dimensions?
- [ ] Are `setContentHuggingPriority` calls present for both orientations with low values?
- [ ] Are `setContentCompressionResistancePriority` calls present for both orientations with low values?
- [ ] Are there any explicit constraints with `NSLayoutPriorityRequired`? (Should only be intentional locking)
- [ ] Are there any frame-based size calculations that might conflict with Auto Layout?

---

## 8. Component Audit Results

| Component | intrinsicContentSize | Hugging Priority | Compression Priority | Status |
|-----------|---------------------|------------------|---------------------|--------|
| Album Art | ✅ NoIntrinsicMetric | ✅ 1 (both) | ✅ 1 (both) | OK |
| Scrobble Widget | ✅ NoIntrinsicMetric | ✅ 1 (both) | ✅ 1 (both) | OK |
| Biography Content | ✅ (-1, -1) | ⚠️ Low (H only) | ⚠️ Low (H only) | CHECK V |
| SimPlaylist | ✅ NoIntrinsicMetric | ✅ 1 (both) | ✅ 1 (both) | **FIXED** (2025-01-03) |
| Waveform Seekbar | N/A (no override) | N/A | N/A | OK (uses constraints) |
| Plorg | N/A | N/A | N/A | CHECK |
| Queue Manager | N/A | N/A | N/A | CHECK |

### SimPlaylist Fix (Applied 2025-01-03)

**Problem:** SimPlaylist was returning actual content dimensions from `intrinsicContentSize` with default high compression resistance. This caused the "can't expand adjacent column" bug - users couldn't widen the right column because SimPlaylist in the middle resisted shrinking.

**Fix applied to `SimPlaylistView.mm`:**

1. Changed `intrinsicContentSize` to return `NSViewNoIntrinsicMetric`:
```objc
- (NSSize)intrinsicContentSize {
    return NSMakeSize(NSViewNoIntrinsicMetric, NSViewNoIntrinsicMetric);
}

// Added separate method for internal frame calculation:
- (NSSize)calculatedContentSize {
    CGFloat totalHeight = [self totalContentHeightCached];
    CGFloat totalWidth = [self totalColumnWidth] + _groupColumnWidth;
    return NSMakeSize(totalWidth, totalHeight);
}
```

2. Added low priority settings in `commonInit`:
```objc
[self setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
[self setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
[self setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
[self setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
```

---

## References

- Apple Documentation: [Intrinsic Content Size](https://developer.apple.com/documentation/uikit/uiview/1622600-intrinsiccontentsize)
- Apple Documentation: [Content Hugging and Compression Resistance](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/AutolayoutPG/WorkingwithConstraintsinInterfaceBuilderv702.html)
- Waveform Seekbar: `extensions/foo_jl_wave_seekbar_mac/src/UI/WaveformSeekbarController.mm` (intentional locking pattern)
- Album Art: `extensions/foo_jl_album_art_mac/src/UI/AlbumArtView.mm` (correct pattern)
