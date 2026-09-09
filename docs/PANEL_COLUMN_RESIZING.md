# Panel Column Resizing in foobar2000

## Symptom

A component panel hosted in a foobar2000 UI column prevents the user from
resizing that column smaller (or shrinking adjacent columns wider into it).
The column appears "stuck" at the panel's natural width.

## Root cause

foobar2000 puts each panel inside a splitter-style column. The column's
final size is negotiated using AppKit auto-layout. By default, an `NSView`
with auto-layout subviews has high content-hugging and
content-compression-resistance priorities (`NSLayoutPriorityDefaultLow` = 250
or higher). That makes the view assert: "I do not want to be smaller than my
intrinsic content size." The splitter respects that and refuses to shrink
the column past the panel's natural width.

## Fix

Two things are required and **both are needed** — lowering priorities alone
is not enough if the root view is a plain `NSView` with auto-layout subviews.

### 1. Override `intrinsicContentSize` to opt out entirely

A plain `NSView` (and any subclass that doesn't override this) computes its
intrinsic content size from its subviews' constraints. Even if you lower the
view's own resistance, the layout engine still has a minimum size to honour —
the smallest size that satisfies the subviews. Result: the column stops
shrinking at the panel's natural width.

Subclass the root view and return "no metric" for both axes:

```objc
@interface MyPanelContainerView : NSView
@end
@implementation MyPanelContainerView
- (NSSize)intrinsicContentSize {
    return NSMakeSize(NSViewNoIntrinsicMetric, NSViewNoIntrinsicMetric);
}
@end
```

This tells the layout engine: "Don't derive a preferred size from me — the
host can pick any size."

### 2. Lower hugging and compression-resistance priorities

On that same root view, set both priorities to a very low value (1):

```objc
[container setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
[container setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
[container setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
[container setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
```

Together: the subviews inside the panel still lay out according to their own
constraints; only the panel's resistance to the outer column is relaxed.

## Where this lives in each component

| Component | Root view created in | File |
| --- | --- | --- |
| SimPlaylist | `commonInit` (the view itself) | `SimPlaylistView.mm` |
| Album Art | view's `init`/setup | `AlbumArtView.mm` |
| Biography | content view setup | `BiographyContentView.mm` |
| Playback Controls | view's setup | `PlaybackControlsView.mm` |
| Scrobble Widget | view's setup | `ScrobbleWidgetView.mm` |
| Tidal Browser | `loadView` (the `container` NSView) | `TidalBrowserController.mm` |

## How to spot it before users do

Build the panel, drop it into a UI column, then grab the adjacent column's
divider and drag it across the panel. If the divider stops at the panel's
natural width instead of going all the way across, the priorities haven't
been lowered.
