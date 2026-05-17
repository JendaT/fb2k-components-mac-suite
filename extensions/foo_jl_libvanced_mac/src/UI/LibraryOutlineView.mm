//
//  LibraryOutlineView.mm
//  foo_jl_libvanced
//

#import "LibraryOutlineView.h"
#import "../Core/LibraryTreeNode.h"
#import "../fb2k_sdk.h"

NSPasteboardType const LibVancedPasteboardType = @"com.foobar2000.libvanced.nodes";

// Shared pasteboard type for interop with SimPlaylist and Queue Manager
static NSPasteboardType const SimPlaylistPasteboardType = @"com.foobar2000.simplaylist.rows";

@implementation LibraryOutlineView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self registerForDraggedTypes:@[
            LibVancedPasteboardType,
            NSPasteboardTypeFileURL
        ]];
    }
    return self;
}

#pragma mark - Keyboard Shortcuts

- (void)keyDown:(NSEvent *)event {
    NSString *chars = event.charactersIgnoringModifiers;
    NSUInteger modifiers = event.modifierFlags;
    BOOL hasCmd = (modifiers & NSEventModifierFlagCommand) != 0;

    if (chars.length == 0) {
        [super keyDown:event];
        return;
    }

    unichar key = [chars characterAtIndex:0];

    NSArray<LibraryTreeNode *> *selectedNodes = [self selectedNodes];

    switch (key) {
        case '\r': {
            if (selectedNodes.count > 0) {
                if ([_actionDelegate respondsToSelector:@selector(libraryView:didRequestSendToPlaylistNodes:)]) {
                    [_actionDelegate libraryView:self didRequestSendToPlaylistNodes:selectedNodes];
                }
            }
            break;
        }

        case ' ':
            playback_control::get()->toggle_pause();
            break;

        default:
            if (!hasCmd && (key == 'q' || key == 'Q')) {
                if (selectedNodes.count > 0) {
                    if ([_actionDelegate respondsToSelector:@selector(libraryView:didRequestQueueNodes:)]) {
                        [_actionDelegate libraryView:self didRequestQueueNodes:selectedNodes];
                    }
                }
            } else if (hasCmd && (key == 'a' || key == 'A')) {
                [self selectAll:nil];
            } else {
                [super keyDown:event];
            }
            break;
    }
}

#pragma mark - Context Menu

- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger row = [self rowAtPoint:point];

    if (row >= 0) {
        // If clicked row is not selected, select it
        if (![self isRowSelected:row]) {
            [self selectRowIndexes:[NSIndexSet indexSetWithIndex:row]
              byExtendingSelection:NO];
        }
    }

    NSArray<LibraryTreeNode *> *nodes = [self selectedNodes];
    if (nodes.count > 0 && [_actionDelegate respondsToSelector:@selector(libraryView:requestContextMenuForNodes:atPoint:)]) {
        [_actionDelegate libraryView:self requestContextMenuForNodes:nodes atPoint:point];
    }

    // Return nil - the delegate builds and shows the menu
    return nil;
}

#pragma mark - NSDraggingSource

- (NSDragOperation)draggingSession:(NSDraggingSession *)session
    sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    if (context == NSDraggingContextWithinApplication) {
        return NSDragOperationCopy;
    }
    return NSDragOperationCopy;
}

#pragma mark - Helpers

- (NSArray<LibraryTreeNode *> *)selectedNodes {
    NSMutableArray<LibraryTreeNode *> *nodes = [NSMutableArray array];
    NSIndexSet *selectedRows = self.selectedRowIndexes;

    [selectedRows enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        id item = [self itemAtRow:idx];
        if ([item isKindOfClass:[LibraryTreeNode class]]) {
            [nodes addObject:item];
        }
    }];

    return nodes;
}

@end
