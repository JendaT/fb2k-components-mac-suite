#pragma once

//
// Keeps a panel's drawing view on whole device pixels.
//
// The host layout can place a panel between pixels (a splitter at two
// thirds of 1280 points puts its edge at 853.33). A view that starts between
// pixels is resampled by the window server on every frame and looks soft.
// The panel's container keeps whatever frame the host gives it; its drawing
// view is placed inside on whole pixels, each edge rounded inward, so at
// most one pixel of the container shows at an edge.
//
// Call JLPixelSnapContent from the controller's viewDidLayout and from its
// redraw tick: a splitter can move the panel without resizing it, and only
// the tick notices that. It is cheap and does nothing when already aligned.
//

#import <Cocoa/Cocoa.h>
#include <math.h>

// The largest rect inside `container`'s bounds whose edges lie on whole
// device pixels of its window, in `container`'s coordinates.
static inline NSRect JLPixelSnappedRect(NSView *container) {
    NSWindow *window = container.window;
    const NSRect bounds = container.bounds;
    if (!window || NSIsEmptyRect(bounds)) return bounds;

    const NSRect px = [window convertRectToBacking:[container convertRect:bounds toView:nil]];
    // Tolerance, so an edge a hair off a pixel boundary is not pulled in a
    // whole pixel by floating-point noise.
    const CGFloat eps = 0.01;
    const CGFloat x0 = ceil(NSMinX(px) - eps), y0 = ceil(NSMinY(px) - eps);
    const CGFloat x1 = floor(NSMaxX(px) + eps), y1 = floor(NSMaxY(px) + eps);
    if (x1 <= x0 || y1 <= y0) return bounds;

    const NSRect snapped = NSMakeRect(x0, y0, x1 - x0, y1 - y0);
    return [container convertRect:[window convertRectFromBacking:snapped] fromView:nil];
}

// Place `content` (a subview of `container`) on whole device pixels.
static inline void JLPixelSnapContent(NSView *container, NSView *content) {
    if (!container || !content) return;
    const NSRect r = JLPixelSnappedRect(container);
    const NSRect f = content.frame;
    if (fabs(NSMinX(f) - NSMinX(r)) < 0.001 && fabs(NSMinY(f) - NSMinY(r)) < 0.001 &&
        fabs(NSWidth(f) - NSWidth(r)) < 0.001 && fabs(NSHeight(f) - NSHeight(r)) < 0.001) {
        return;
    }
    content.frame = r;
}
