//
//  QueueHeaderCell.mm
//  foo_jl_queue_manager
//
//  Custom header cell with SimPlaylist-matching appearance
//

#import "QueueHeaderCell.h"
#import "../../../../shared/UIStyles.h"

@implementation QueueHeaderCell

- (BOOL)isTransparentMode:(NSView*)controlView {
    // Navigate to table view to check if transparent mode is enabled
    NSView* view = controlView;
    while (view) {
        if ([view isKindOfClass:[NSTableView class]]) {
            return [((NSTableView*)view).backgroundColor isEqual:[NSColor clearColor]];
        }
        view = view.superview;
    }
    return NO;
}

- (void)drawWithFrame:(NSRect)cellFrame inView:(NSView*)controlView {
    BOOL transparent = [self isTransparentMode:controlView];

    // Draw background (only if not transparent)
    if (!transparent) {
        [fb2k_ui::headerBackgroundColor() setFill];
        NSRectFill(cellFrame);
    }

    // Draw bottom separator line
    [fb2k_ui::separatorColor() setFill];
    NSRectFill(NSMakeRect(cellFrame.origin.x, NSMaxY(cellFrame) - 1, cellFrame.size.width, 1));

    // Draw right separator line (column divider)
    NSRectFill(NSMakeRect(NSMaxX(cellFrame) - 1, cellFrame.origin.y + 4, 1, cellFrame.size.height - 8));

    // Draw text
    NSRect textRect = NSInsetRect(cellFrame, fb2k_ui::kHeaderTextPadding, 2);

    NSDictionary* attrs = @{
        NSFontAttributeName: fb2k_ui::headerFont(),
        NSForegroundColorAttributeName: fb2k_ui::secondaryTextColor()
    };

    NSMutableParagraphStyle* style = [[NSMutableParagraphStyle alloc] init];
    style.lineBreakMode = NSLineBreakByTruncatingTail;

    NSMutableDictionary* attrsCopy = [attrs mutableCopy];
    attrsCopy[NSParagraphStyleAttributeName] = style;

    [self.stringValue drawInRect:textRect withAttributes:attrsCopy];
}

- (void)highlight:(BOOL)flag withFrame:(NSRect)cellFrame inView:(NSView*)controlView {
    // Draw highlight state
    if (flag) {
        [[[NSColor labelColor] colorWithAlphaComponent:0.1] setFill];
        NSRectFill(cellFrame);
    }
    [self drawWithFrame:cellFrame inView:controlView];
}

@end
