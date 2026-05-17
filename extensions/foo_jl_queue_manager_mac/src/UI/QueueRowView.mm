//
//  QueueRowView.mm
//  foo_jl_queue_manager
//
//  Custom row view for queue table with SimPlaylist-matching selection style
//

#import "QueueRowView.h"
#import "../../../../shared/UIStyles.h"

@implementation QueueRowView

- (void)viewDidMoveToSuperview {
    [super viewDidMoveToSuperview];
    // Cache transparent mode when added to hierarchy
    _transparentModeCached = NO;
}

- (BOOL)isTransparentMode {
    if (_transparentModeCached) {
        return _cachedTransparentMode;
    }

    _cachedTransparentMode = NO;
    NSView* view = self.superview;
    while (view) {
        if ([view isKindOfClass:[NSTableView class]]) {
            NSTableView* tableView = (NSTableView*)view;
            _cachedTransparentMode = tableView.backgroundColor.alphaComponent < 0.1;
            break;
        }
        view = view.superview;
    }
    _transparentModeCached = YES;
    return _cachedTransparentMode;
}

- (void)drawSelectionInRect:(NSRect)dirtyRect {
    // Draw sharp/square selection like SimPlaylist instead of rounded default
    if (self.selectionHighlightStyle != NSTableViewSelectionHighlightStyleNone) {
        NSRect selectionRect = self.bounds;
        // Use glass-aware selection color for consistency
        NSColor *selColor = fb2k_ui::selectedBackgroundColor();
        [selColor setFill];
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
