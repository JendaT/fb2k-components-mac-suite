//
//  QueueRowView.mm
//  foo_jl_queue_manager
//
//  Custom row view for queue table with SimPlaylist-matching selection style
//

#import "QueueRowView.h"
#import "../../../../shared/UIStyles.h"

@implementation QueueRowView

- (BOOL)isTransparentMode {
    // Check if table view has clear background (transparent mode)
    // Navigate up hierarchy to find the table view
    NSView* view = self.superview;
    while (view) {
        if ([view isKindOfClass:[NSTableView class]]) {
            NSTableView* tableView = (NSTableView*)view;
            // Use alpha component check for more reliable detection
            return tableView.backgroundColor.alphaComponent < 0.1;
        }
        view = view.superview;
    }
    return NO;
}

- (void)drawSelectionInRect:(NSRect)dirtyRect {
    // Draw sharp/square selection like SimPlaylist instead of rounded default
    if (self.selectionHighlightStyle != NSTableViewSelectionHighlightStyleNone) {
        NSRect selectionRect = self.bounds;
        [fb2k_ui::selectedBackgroundColor() setFill];
        NSRectFill(selectionRect);
    }
}

- (void)drawBackgroundInRect:(NSRect)dirtyRect {
    // Only draw background if not in transparent mode
    if (![self isTransparentMode]) {
        [fb2k_ui::backgroundColor() setFill];
        NSRectFill(dirtyRect);
    }
}

- (BOOL)isEmphasized {
    // Always show emphasized (blue) selection, not gray
    return YES;
}

@end
