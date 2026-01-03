//
//  PlorgOutlineView.m
//  foo_plorg_mac
//
//  Custom NSOutlineView subclass to forward drag lifecycle callbacks
//

#import "PlorgOutlineView.h"

@implementation PlorgOutlineView

// CRITICAL: draggingEntered: is called BEFORE validateDrop: - this is the earliest point
// to capture pre-drag state before any selection changes can happen.
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    // NOTE: Do NOT call [super draggingEntered:] - NSOutlineView uses dataSource pattern,
    // not NSDraggingDestination. Calling super causes hangs.
    id<PlorgOutlineViewDelegate> delegate = (id)self.delegate;
    if ([delegate respondsToSelector:@selector(outlineView:draggingEntered:)]) {
        [delegate outlineView:self draggingEntered:sender];
    }
    // Return None here - actual validation happens in validateDrop:
    return NSDragOperationNone;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
    // NOTE: Do NOT call [super draggingExited:] - NSOutlineView uses dataSource pattern,
    // not NSDraggingDestination. Calling super causes hangs.
    id<PlorgOutlineViewDelegate> delegate = (id)self.delegate;
    if ([delegate respondsToSelector:@selector(outlineView:draggingExited:)]) {
        [delegate outlineView:self draggingExited:sender];
    }
}

// CRITICAL: draggingEnded: is called when ANY drag operation ends (drop, cancel, ESC).
// This is the definitive cleanup point. Without this, ESC to cancel while over the view
// would leave the hover timer running.
- (void)draggingEnded:(id<NSDraggingInfo>)sender {
    // NOTE: Do NOT call [super draggingEnded:] - NSOutlineView uses dataSource pattern,
    // not NSDraggingDestination. Calling super causes hangs.
    id<PlorgOutlineViewDelegate> delegate = (id)self.delegate;
    if ([delegate respondsToSelector:@selector(outlineView:draggingEnded:)]) {
        [delegate outlineView:self draggingEnded:sender];
    }
}

@end
