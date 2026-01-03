# Drag and Drop Implementation Guide

**Revision:** 1.1
**Last Updated:** 2026-01-03

This document covers drag and drop implementation patterns for foobar2000 macOS components, including internal reordering, cross-component dragging, and integration with the foobar2000 SDK.

---

## Table of Contents

1. [Overview](#1-overview)
2. [NSPasteboard Fundamentals](#2-nspasteboard-fundamentals)
3. [foobar2000 SDK Limitations](#3-foobar2000-sdk-limitations)
4. [Internal Reordering (Same View)](#4-internal-reordering-same-view)
5. [NSTableView Drag & Drop](#5-nstableview-drag--drop)
6. [NSOutlineView Drag & Drop](#6-nsoutlineview-drag--drop)
7. [Custom View Drag & Drop](#7-custom-view-drag--drop)
8. [Cross-Component Dragging](#8-cross-component-dragging)
9. [External File Drops](#9-external-file-drops)
10. [Callback Debouncing](#10-callback-debouncing)
11. [Visual Feedback](#11-visual-feedback)
12. [Common Pitfalls](#12-common-pitfalls)
13. [Implementation Examples](#13-implementation-examples)
14. [NSOutlineView Drag Lifecycle (Critical Discoveries)](#14-nsoutlineview-drag-lifecycle-critical-discoveries)

---

## 1. Overview

macOS drag and drop uses the `NSPasteboard` system. Views can be:
- **Drag Source** - Initiates a drag operation
- **Drop Destination** - Accepts dropped items
- **Both** - For reordering within the same view

Key protocols:
- `NSDraggingSource` - For views that initiate drags
- `NSDraggingDestination` - For views that accept drops
- `NSTableViewDataSource` - Provides table-specific drag/drop methods
- `NSOutlineViewDataSource` - Provides outline-specific drag/drop methods

---

## 2. NSPasteboard Fundamentals

### 2.1 Pasteboard Types

Define custom pasteboard types for your component's data:

```objc
// Define as a static constant
static NSPasteboardType const SimPlaylistPasteboardType = @"com.foobar2000.simplaylist.tracks";
static NSPasteboardType const QueueItemPasteboardType = @"com.foobar2000.queue.items";
static NSPasteboardType const PlorgNodePasteboardType = @"com.foobar2000.plorg.node";
```

**Naming convention:** `com.foobar2000.<component>.<datatype>`

### 2.2 Registering for Drag Types

```objc
// In view initialization
- (void)setupDragAndDrop {
    // Register types this view accepts
    [self registerForDraggedTypes:@[
        MyCustomPasteboardType,      // Internal reordering
        NSPasteboardTypeFileURL      // External file drops
    ]];
}
```

### 2.3 Writing to Pasteboard

```objc
// Using NSPasteboardItem (recommended)
NSPasteboardItem *pbItem = [[NSPasteboardItem alloc] init];
NSData *data = [NSKeyedArchiver archivedDataWithRootObject:indices
                                     requiringSecureCoding:YES
                                                     error:nil];
[pbItem setData:data forType:MyCustomPasteboardType];

// Declare and write
NSPasteboard *pb = [NSPasteboard generalPasteboard];
[pb clearContents];
[pb writeObjects:@[pbItem]];
```

### 2.4 Reading from Pasteboard

```objc
NSPasteboard *pb = [sender draggingPasteboard];

// Check available types
if ([pb.types containsObject:MyCustomPasteboardType]) {
    NSData *data = [pb dataForType:MyCustomPasteboardType];
    NSIndexSet *indices = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSIndexSet class]
                                                            fromData:data
                                                               error:nil];
    // Process indices...
}
```

---

## 3. foobar2000 SDK Limitations

### 3.1 No Standard Pasteboard Type for Tracks

**Critical Finding:** The foobar2000 SDK does NOT define a standard `NSPasteboardType` for track handles on macOS.

On Windows, there's IDataObject/OLE integration, but for macOS:
- No `NSPasteboardType` constant for foobar2000 tracks
- No helper functions for macOS drag/drop
- Each component must define its own pasteboard format

### 3.2 Implications

| Scenario | Solution |
|----------|----------|
| Internal reordering | Define your own pasteboard type |
| Drag from playlists | Unknown if Default UI exposes a type - investigate at runtime |
| Drag to queue | Accept file URLs as fallback |
| Cross-component | Coordinate pasteboard types between components |

### 3.3 Runtime Investigation

To discover what the Default UI puts on the pasteboard:

```objc
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NSPasteboard *pb = [sender draggingPasteboard];

    // Debug: Log all available types
    NSLog(@"=== Pasteboard Types ===");
    for (NSString *type in pb.types) {
        NSLog(@"Type: %@", type);
        NSData *data = [pb dataForType:type];
        if (data.length < 1000) {
            NSLog(@"  Data: %@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: data);
        } else {
            NSLog(@"  Data length: %lu bytes", (unsigned long)data.length);
        }
    }

    return NSDragOperationNone; // For investigation only
}
```

### 3.4 Transferring Track Handles

Since there's no standard type, you have options:

**Option A: Store indices (internal only)**
```objc
// Write: Store playlist index + item indices
NSDictionary *dragData = @{
    @"playlist": @(playlistIndex),
    @"items": selectedIndices  // NSIndexSet
};
NSData *data = [NSKeyedArchiver archivedDataWithRootObject:dragData
                                     requiringSecureCoding:YES error:nil];
```

**Option B: Store file paths (cross-app compatible)**
```objc
// Write: Store file paths
NSMutableArray<NSURL*> *urls = [NSMutableArray array];
for (metadb_handle_ptr handle : handles) {
    pfc::string8 path = handle->get_path();
    // Convert foobar path format to file URL
    if (strncmp(path.c_str(), "file://", 7) == 0) {
        [urls addObject:[NSURL URLWithString:@(path.c_str())]];
    }
}
[pasteboard writeObjects:urls];
```

---

## 4. Internal Reordering (Same View)

### 4.1 The Reorder Algorithm

When reordering items within the same collection:

```objc
- (void)reorderItems:(NSIndexSet*)draggedIndices toIndex:(NSInteger)targetRow {
    // 1. Capture current state
    NSMutableArray *items = [self.items mutableCopy];

    // 2. Extract dragged items (in reverse to preserve indices)
    NSMutableArray *draggedItems = [NSMutableArray array];
    [draggedIndices enumerateIndexesWithOptions:NSEnumerationReverse
                                     usingBlock:^(NSUInteger idx, BOOL *stop) {
        [draggedItems insertObject:items[idx] atIndex:0];
        [items removeObjectAtIndex:idx];
    }];

    // 3. Adjust target index
    __block NSInteger adjustedTarget = targetRow;
    [draggedIndices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if ((NSInteger)idx < targetRow) {
            adjustedTarget--;
        }
    }];

    // 4. Insert at new position
    NSIndexSet *insertIndices = [NSIndexSet indexSetWithIndexesInRange:
                                 NSMakeRange(adjustedTarget, draggedItems.count)];
    [items insertObjects:draggedItems atIndexes:insertIndices];

    // 5. Update data source
    self.items = items;
    [self reloadData];
}
```

### 4.2 Index Adjustment Explained

When dragging rows 2 and 4 to position 6:
```
Before: [0] [1] [2*] [3] [4*] [5] [6] [7]
              ^drag      ^drag      ^target

Step 1: Remove dragged items
        [0] [1] [3] [5] [6] [7]
                        ^target was 6, now 4

Step 2: Insert at adjusted position (4)
        [0] [1] [3] [5] [2*] [4*] [6] [7]
```

---

## 5. NSTableView Drag & Drop

### 5.1 Data Source Methods

```objc
#pragma mark - Drag Source

// Called when drag begins - write data to pasteboard
- (BOOL)tableView:(NSTableView*)tableView
    writeRowsWithIndexes:(NSIndexSet*)rowIndexes
            toPasteboard:(NSPasteboard*)pasteboard {

    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:rowIndexes
                                         requiringSecureCoding:YES
                                                         error:nil];
    [pasteboard declareTypes:@[MyPasteboardType] owner:self];
    [pasteboard setData:data forType:MyPasteboardType];
    return YES;
}

#pragma mark - Drop Destination

// Validate drop - return operation type or None to reject
- (NSDragOperation)tableView:(NSTableView*)tableView
                validateDrop:(id<NSDraggingInfo>)info
                 proposedRow:(NSInteger)row
       proposedDropOperation:(NSTableViewDropOperation)dropOperation {

    // Force "between rows" drops (not "on row")
    if (dropOperation == NSTableViewDropOn) {
        [tableView setDropRow:row dropOperation:NSTableViewDropAbove];
    }

    NSPasteboard *pb = info.draggingPasteboard;
    if ([pb.types containsObject:MyPasteboardType]) {
        return NSDragOperationMove;
    }
    return NSDragOperationNone;
}

// Accept drop - perform the operation
- (BOOL)tableView:(NSTableView*)tableView
       acceptDrop:(id<NSDraggingInfo>)info
              row:(NSInteger)row
    dropOperation:(NSTableViewDropOperation)dropOperation {

    NSPasteboard *pb = info.draggingPasteboard;
    NSData *data = [pb dataForType:MyPasteboardType];
    if (!data) return NO;

    NSIndexSet *indices = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSIndexSet class]
                                                            fromData:data
                                                               error:nil];
    [self reorderItems:indices toIndex:row];
    return YES;
}
```

### 5.2 Enabling Drag Operations

```objc
- (void)setupTableView {
    // Enable dragging
    [self.tableView setDraggingSourceOperationMask:NSDragOperationMove forLocal:YES];
    [self.tableView setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];

    // Register drop types
    [self.tableView registerForDraggedTypes:@[MyPasteboardType, NSPasteboardTypeFileURL]];
}
```

---

## 6. NSOutlineView Drag & Drop

NSOutlineView (used for tree structures like Playlist Organizer) has slightly different methods:

### 6.1 Data Source Methods

```objc
#pragma mark - Drag Source

- (BOOL)outlineView:(NSOutlineView*)outlineView
         writeItems:(NSArray*)items
       toPasteboard:(NSPasteboard*)pasteboard {

    [pasteboard declareTypes:@[PlorgNodePasteboardType] owner:self];

    // Store node paths for reconstruction
    NSMutableArray *paths = [NSMutableArray array];
    for (TreeNode *node in items) {
        [paths addObject:node.path];
    }

    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:paths
                                         requiringSecureCoding:YES
                                                         error:nil];
    [pasteboard setData:data forType:PlorgNodePasteboardType];
    return YES;
}

#pragma mark - Drop Destination

- (NSDragOperation)outlineView:(NSOutlineView*)outlineView
                  validateDrop:(id<NSDraggingInfo>)info
                  proposedItem:(id)item
            proposedChildIndex:(NSInteger)index {

    // Only allow drops on folders or at root
    if (item && ![(TreeNode*)item isFolder]) {
        return NSDragOperationNone;
    }
    return NSDragOperationMove;
}

- (BOOL)outlineView:(NSOutlineView*)outlineView
         acceptDrop:(id<NSDraggingInfo>)info
               item:(id)item
         childIndex:(NSInteger)index {

    NSPasteboard *pb = info.draggingPasteboard;
    NSData *data = [pb dataForType:PlorgNodePasteboardType];
    if (!data) return NO;

    NSArray *paths = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSArray class]
                                                       fromData:data
                                                          error:nil];

    TreeNode *targetFolder = item ?: self.rootNode;
    [self moveNodesByPaths:paths toFolder:targetFolder atIndex:index];
    return YES;
}
```

### 6.2 Preventing Invalid Drops

```objc
- (NSDragOperation)outlineView:(NSOutlineView*)outlineView
                  validateDrop:(id<NSDraggingInfo>)info
                  proposedItem:(id)item
            proposedChildIndex:(NSInteger)index {

    TreeNode *targetNode = item;

    // Prevent dropping on non-folders
    if (targetNode && !targetNode.isFolder) {
        return NSDragOperationNone;
    }

    // Prevent dropping a folder into itself or its children
    NSPasteboard *pb = info.draggingPasteboard;
    NSData *data = [pb dataForType:PlorgNodePasteboardType];
    NSArray *paths = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSArray class]
                                                       fromData:data error:nil];

    for (NSString *path in paths) {
        TreeNode *draggedNode = [self nodeForPath:path];
        if ([targetNode isDescendantOf:draggedNode]) {
            return NSDragOperationNone;  // Can't drop parent into child
        }
    }

    return NSDragOperationMove;
}
```

---

## 7. Custom View Drag & Drop

For custom views (not table/outline), implement the protocols directly:

### 7.1 NSDraggingSource Protocol

```objc
@interface MyCustomView : NSView <NSDraggingSource>
@property (nonatomic) BOOL isDragging;
@property (nonatomic, strong) NSView *draggedView;
@end

@implementation MyCustomView

- (void)mouseDown:(NSEvent*)event {
    self.dragStartLocation = [self convertPoint:event.locationInWindow fromView:nil];
}

- (void)mouseDragged:(NSEvent*)event {
    NSPoint currentLocation = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat distance = hypot(currentLocation.x - self.dragStartLocation.x,
                            currentLocation.y - self.dragStartLocation.y);

    // Start drag after threshold
    if (distance > 5 && !self.isDragging) {
        [self beginDragOperation:event];
    }
}

- (void)beginDragOperation:(NSEvent*)event {
    self.isDragging = YES;

    // Create pasteboard item
    NSPasteboardItem *pbItem = [[NSPasteboardItem alloc] init];
    NSDictionary *dragData = @{@"itemIndex": @(self.selectedIndex)};
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:dragData
                                         requiringSecureCoding:YES error:nil];
    [pbItem setData:data forType:MyPasteboardType];

    // Create dragging item with image
    NSDraggingItem *dragItem = [[NSDraggingItem alloc] initWithPasteboardWriter:pbItem];

    NSImage *dragImage = [self createDragImage];
    dragItem.draggingFrame = NSMakeRect(event.locationInWindow.x - 50,
                                        event.locationInWindow.y - 15,
                                        100, 30);
    dragItem.imageComponentsProvider = ^NSArray<NSDraggingImageComponent*>* {
        NSDraggingImageComponent *component =
            [NSDraggingImageComponent draggingImageComponentWithKey:NSDraggingImageComponentIconKey];
        component.contents = dragImage;
        component.frame = NSMakeRect(0, 0, dragImage.size.width, dragImage.size.height);
        return @[component];
    };

    // Start drag session
    [self beginDraggingSessionWithItems:@[dragItem]
                                  event:event
                                 source:self];
}

#pragma mark - NSDraggingSource

- (NSDragOperation)draggingSession:(NSDraggingSession*)session
    sourceOperationMaskForDraggingContext:(NSDraggingContext)context {

    if (context == NSDraggingContextWithinApplication) {
        return NSDragOperationMove;
    }
    return NSDragOperationCopy;
}

- (void)draggingSession:(NSDraggingSession*)session
           endedAtPoint:(NSPoint)screenPoint
              operation:(NSDragOperation)operation {
    self.isDragging = NO;
    self.draggedView.alphaValue = 1.0;
    self.draggedView = nil;
}

@end
```

### 7.2 NSDraggingDestination Protocol

```objc
@implementation MyCustomView

- (void)awakeFromNib {
    [super awakeFromNib];
    [self registerForDraggedTypes:@[MyPasteboardType, NSPasteboardTypeFileURL]];
}

#pragma mark - NSDraggingDestination

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NSPasteboard *pb = sender.draggingPasteboard;

    if ([pb.types containsObject:MyPasteboardType]) {
        return NSDragOperationMove;
    } else if ([pb.types containsObject:NSPasteboardTypeFileURL]) {
        return NSDragOperationCopy;
    }
    return NSDragOperationNone;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    NSPoint location = [self convertPoint:sender.draggingLocation fromView:nil];

    // Update visual feedback
    self.dropTargetIndex = [self indexAtPoint:location];
    [self setNeedsDisplay:YES];

    return [self draggingEntered:sender];
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
    self.dropTargetIndex = -1;
    [self setNeedsDisplay:YES];
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender {
    return YES;  // Continue to performDragOperation
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSPasteboard *pb = sender.draggingPasteboard;

    if ([pb.types containsObject:MyPasteboardType]) {
        NSData *data = [pb dataForType:MyPasteboardType];
        // Process internal drag...
        return YES;
    } else if ([pb.types containsObject:NSPasteboardTypeFileURL]) {
        NSArray<NSURL*> *urls = [pb readObjectsForClasses:@[NSURL.class] options:nil];
        // Process file drops...
        return YES;
    }
    return NO;
}

- (void)concludeDragOperation:(id<NSDraggingInfo>)sender {
    self.dropTargetIndex = -1;
    [self setNeedsDisplay:YES];
}

@end
```

---

## 8. Cross-Component Dragging

### 8.1 Defining Shared Pasteboard Types

For components that need to exchange data, define shared types:

```objc
// In a shared header (e.g., SharedPasteboardTypes.h)
static NSPasteboardType const Fb2kTracksPasteboardType = @"com.foobar2000.tracks";
static NSPasteboardType const Fb2kPlaylistRefPasteboardType = @"com.foobar2000.playlistref";
```

### 8.2 Writing Track References

```objc
// Write playlist + indices that other components can read
- (void)writeTracksToPasteboard:(NSPasteboard*)pb
                   fromPlaylist:(size_t)playlist
                        indices:(NSIndexSet*)indices {

    NSDictionary *data = @{
        @"playlist": @(playlist),
        @"indices": indices,
        @"timestamp": @([NSDate date].timeIntervalSince1970)  // For staleness check
    };

    NSData *encoded = [NSKeyedArchiver archivedDataWithRootObject:data
                                            requiringSecureCoding:YES error:nil];
    [pb setData:encoded forType:Fb2kTracksPasteboardType];
}
```

### 8.3 Reading Track References

```objc
- (NSArray<metadb_handle_ptr>*)readTracksFromPasteboard:(NSPasteboard*)pb {
    NSData *data = [pb dataForType:Fb2kTracksPasteboardType];
    if (!data) return nil;

    NSDictionary *decoded = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSDictionary class]
                                                              fromData:data error:nil];

    size_t playlist = [decoded[@"playlist"] unsignedLongValue];
    NSIndexSet *indices = decoded[@"indices"];

    // Validate playlist still exists
    auto pm = playlist_manager::get();
    if (playlist >= pm->get_playlist_count()) {
        return nil;  // Playlist was deleted
    }

    // Get handles
    NSMutableArray *handles = [NSMutableArray array];
    [indices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        metadb_handle_ptr handle;
        if (pm->playlist_get_item_handle(handle, playlist, idx)) {
            // Wrap handle for Objective-C storage
            [handles addObject:[[TrackHandleWrapper alloc] initWithHandle:handle]];
        }
    }];

    return handles;
}
```

---

## 9. External File Drops

### 9.1 Accepting File URLs

```objc
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSPasteboard *pb = sender.draggingPasteboard;

    if ([pb.types containsObject:NSPasteboardTypeFileURL]) {
        NSArray<NSURL*> *urls = [pb readObjectsForClasses:@[NSURL.class]
                                                  options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];

        if (urls.count > 0) {
            [self addFilesFromURLs:urls];
            return YES;
        }
    }
    return NO;
}

- (void)addFilesFromURLs:(NSArray<NSURL*>*)urls {
    // Filter for supported audio files
    NSMutableArray<NSURL*> *audioFiles = [NSMutableArray array];

    for (NSURL *url in urls) {
        NSString *ext = url.pathExtension.lowercaseString;
        if ([@[@"flac", @"mp3", @"m4a", @"ogg", @"wav", @"aiff"] containsObject:ext]) {
            [audioFiles addObject:url];
        }
    }

    if (audioFiles.count > 0) {
        // Use SDK to add files to playlist
        fb2k::inMainThread([=] {
            auto pm = playlist_manager::get();
            // Convert URLs to foobar paths and add...
        });
    }
}
```

### 9.2 Converting Between Path Formats

```objc
// NSURL to foobar path
- (pfc::string8)foobarPathFromURL:(NSURL*)url {
    pfc::string8 path;
    path << "file://" << url.path.UTF8String;
    return path;
}

// foobar path to NSURL
- (NSURL*)urlFromFoobarPath:(const char*)path {
    if (strncmp(path, "file://", 7) == 0) {
        return [NSURL URLWithString:@(path)];
    }
    return nil;
}
```

---

## 10. Callback Debouncing

### 10.1 The Problem

When reordering queue items, the SDK pattern requires:
1. `queue_flush()` - Remove all items
2. `queue_add_item()` x N - Re-add in new order

This triggers N+1 callbacks (`on_changed`), causing UI flicker.

### 10.2 The Solution: Debounce Flag

```objc
@interface QueueManagerController : NSViewController
@property (nonatomic) BOOL isReorderingInProgress;
@end

@implementation QueueManagerController

- (BOOL)handleReorder:(NSIndexSet*)draggedIndices toRow:(NSInteger)targetRow {
    // 1. Set flag BEFORE modifications
    self.isReorderingInProgress = YES;

    // 2. Capture and rebuild queue
    pfc::list_t<t_playback_queue_item> currentQueue;
    playlist_manager::get()->queue_get_contents(currentQueue);

    // ... reorder logic ...

    // 3. Apply changes
    auto pm = playlist_manager::get();
    pm->queue_flush();  // Triggers callback - ignored due to flag
    for (size_t i = 0; i < newQueue.get_count(); i++) {
        pm->queue_add_item_playlist(newQueue[i].m_playlist, newQueue[i].m_item);
        // Each add triggers callback - ignored due to flag
    }

    // 4. Clear flag and reload ONCE
    dispatch_async(dispatch_get_main_queue(), ^{
        self.isReorderingInProgress = NO;
        [self reloadQueueContents];  // Single reload
    });

    return YES;
}

@end
```

### 10.3 In the Callback Manager

```objc
// QueueCallbackManager.mm
void QueueCallbackManager::onQueueChanged(t_change_origin origin) {
    std::lock_guard<std::mutex> lock(m_mutex);

    for (auto weakController : m_controllers) {
        if (QueueManagerController* controller = weakController) {
            // Skip if controller is doing a reorder
            if (!controller.isReorderingInProgress) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [controller reloadQueueContents];
                });
            }
        }
    }
}
```

---

## 11. Visual Feedback

### 11.1 Drop Indicator

```objc
@implementation MyTableView

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    // Draw drop indicator line
    if (self.dropTargetRow >= 0) {
        NSRect rowRect;
        if (self.dropTargetRow < self.numberOfRows) {
            rowRect = [self rectOfRow:self.dropTargetRow];
        } else {
            rowRect = [self rectOfRow:self.numberOfRows - 1];
            rowRect.origin.y += rowRect.size.height;
        }

        [[NSColor alternateSelectedControlColor] setFill];
        NSRect indicatorRect = NSMakeRect(0, rowRect.origin.y - 1, self.bounds.size.width, 2);
        NSRectFill(indicatorRect);
    }
}

@end
```

### 11.2 Drag Image

```objc
- (NSImage*)createDragImageForSelection {
    NSInteger count = self.selectedIndices.count;
    NSString *text = count == 1 ? @"1 item" : [NSString stringWithFormat:@"%ld items", count];

    // Create attributed string
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12],
        NSForegroundColorAttributeName: [NSColor labelColor]
    };
    NSSize textSize = [text sizeWithAttributes:attrs];

    // Create image
    NSSize imageSize = NSMakeSize(textSize.width + 20, textSize.height + 10);
    NSImage *image = [[NSImage alloc] initWithSize:imageSize];

    [image lockFocus];

    // Draw background
    [[NSColor controlBackgroundColor] setFill];
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, 0, imageSize.width, imageSize.height)
                                                         xRadius:5 yRadius:5];
    [path fill];

    // Draw text
    [text drawAtPoint:NSMakePoint(10, 5) withAttributes:attrs];

    [image unlockFocus];
    return image;
}
```

### 11.3 Dimming Dragged Items

```objc
- (void)beginDragOperation:(NSEvent*)event {
    // Dim dragged rows
    [self.selectedIndices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        NSTableRowView *rowView = [self rowViewAtRow:idx makeIfNecessary:NO];
        rowView.alphaValue = 0.5;
    }];

    // ... start drag ...
}

- (void)draggingSession:(NSDraggingSession*)session
           endedAtPoint:(NSPoint)screenPoint
              operation:(NSDragOperation)operation {

    // Restore opacity
    for (NSInteger i = 0; i < self.numberOfRows; i++) {
        NSTableRowView *rowView = [self rowViewAtRow:i makeIfNecessary:NO];
        rowView.alphaValue = 1.0;
    }
}
```

---

## 12. Common Pitfalls

### 12.1 Index Adjustment Errors

**Wrong:**
```objc
// Inserting at original target without adjustment
[items insertObjects:draggedItems atIndex:targetRow];
```

**Correct:**
```objc
// Adjust target for removed items
__block NSInteger adjustedTarget = targetRow;
[draggedIndices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
    if ((NSInteger)idx < targetRow) adjustedTarget--;
}];
[items insertObjects:draggedItems atIndex:adjustedTarget];
```

### 12.2 Not Handling Empty Drops

**Wrong:**
```objc
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSData *data = [sender.draggingPasteboard dataForType:MyType];
    NSIndexSet *indices = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSIndexSet class]
                                                            fromData:data error:nil];
    // Crash if data is nil!
```

**Correct:**
```objc
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSData *data = [sender.draggingPasteboard dataForType:MyType];
    if (!data) return NO;

    NSError *error;
    NSIndexSet *indices = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSIndexSet class]
                                                            fromData:data error:&error];
    if (!indices) {
        NSLog(@"Failed to decode: %@", error);
        return NO;
    }
```

### 12.3 Main Thread Violations

**Wrong:**
```objc
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        playlist_manager::get()->queue_add_item(handle);  // CRASH!
    });
}
```

**Correct:**
```objc
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    // SDK operations must be on main thread
    fb2k::inMainThread([=] {
        playlist_manager::get()->queue_add_item(handle);
    });
    return YES;
}
```

### 12.4 Memory Issues with C++ Handles

**Wrong:**
```objc
@property (assign) metadb_handle_ptr handle;  // Will corrupt memory!
```

**Correct:**
```objc
@interface TrackWrapper : NSObject {
    metadb_handle_ptr _handle;  // C++ member, not property
}
- (metadb_handle_ptr)handle;
@end
```

### 12.5 Forgetting to Register Types

**Symptom:** `draggingEntered:` never called

**Fix:**
```objc
- (void)awakeFromNib {
    [super awakeFromNib];
    [self registerForDraggedTypes:@[MyPasteboardType]];  // Don't forget!
}
```

---

## 13. Implementation Examples

### 13.1 Queue Manager (NSTableView Reordering)

See: `extensions/foo_jl_queue_manager_mac/src/UI/QueueManagerController.mm`

Key patterns:
- Custom pasteboard type for queue items
- Debouncing with `isReorderingInProgress` flag
- Flush-and-rebuild reorder algorithm

### 13.2 Playlist Organizer (NSOutlineView Tree)

See: `extensions/foo_jl_plorg_mac/src/UI/PlaylistOrganizerController.mm`

Key patterns:
- Tree node path storage
- Preventing drops into descendant folders
- Folder structure maintenance

### 13.3 SimPlaylist (Custom View)

See: `extensions/foo_jl_simplaylist_mac/src/UI/SimPlaylistView.mm`

Key patterns:
- NSDraggingSource/Destination protocols
- Custom drag image creation
- Visual drop indicator drawing

### 13.4 Playback Controls (Button Reordering)

See: `extensions/foo_jl_playback_controls_ext/src/UI/PlaybackControlsView.mm`

Key patterns:
- Edit mode gating
- Horizontal position-based drop targeting
- Immediate visual feedback

---

## 14. NSOutlineView Drag Lifecycle (Critical Discoveries)

These patterns were discovered while implementing drag-hover-expand in Playlist Organizer.

### 14.1 Do NOT Call Super on Drag Methods

**Critical:** NSOutlineView uses the dataSource pattern for drag/drop, NOT the NSDraggingDestination protocol. Calling super on these methods causes system hangs:

```objc
// WRONG - causes system gesture hangs!
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    [super draggingEntered:sender];  // DON'T DO THIS
    return NSDragOperationCopy;
}

// CORRECT - forward to delegate without calling super
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    id<MyOutlineViewDelegate> delegate = (id)self.delegate;
    if ([delegate respondsToSelector:@selector(outlineView:draggingEntered:)]) {
        [delegate outlineView:self draggingEntered:sender];
    }
    return NSDragOperationNone;  // Actual validation in validateDrop:
}
```

### 14.2 Drag Event Order

For external drags entering an NSOutlineView:

1. `draggingEntered:` - Called when cursor enters view (BEFORE validateDrop)
2. `validateDrop:proposedItem:proposedChildIndex:` - Called repeatedly as cursor moves
3. `draggingExited:` - Called when cursor leaves view
4. `draggingEnded:` - Called when drag operation completes (drop or cancel)

**Important:** `draggingEnded:` IS called on your view even when the drop happens elsewhere.

### 14.3 Timers During Drag Operations

NSTimer scheduled with `scheduledTimerWithTimeInterval:` uses default run loop mode. During drag, the run loop is in event tracking mode, so timers won't fire.

```objc
// WRONG - timer won't fire during drag
_hoverTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                               target:self
                                             selector:@selector(timerFired:)
                                             userInfo:nil
                                              repeats:NO];

// CORRECT - use common modes to fire during drag
_hoverTimer = [NSTimer timerWithTimeInterval:1.0
                                      target:self
                                    selector:@selector(timerFired:)
                                    userInfo:nil
                                     repeats:NO];
[[NSRunLoop currentRunLoop] addTimer:_hoverTimer forMode:NSRunLoopCommonModes];
```

### 14.4 Blocking Selection During Drag

To prevent selection changes while dragging over an outline view:

```objc
@implementation MyController {
    BOOL _hasDragSource;
}

- (BOOL)selectionShouldChangeInOutlineView:(NSOutlineView *)outlineView {
    return !_hasDragSource;  // Block selection during drag
}

- (void)outlineView:(NSOutlineView *)outlineView draggingEntered:(id<NSDraggingInfo>)sender {
    _hasDragSource = YES;
}

- (void)outlineView:(NSOutlineView *)outlineView draggingEnded:(id<NSDraggingInfo>)sender {
    _hasDragSource = NO;
    [self.outlineView reloadData];  // Clear lingering visual state
}
```

### 14.5 Modifier Keys for Copy vs Move

Check modifier keys in `validateDrop:` to change operation type:

```objc
- (NSDragOperation)outlineView:(NSOutlineView *)outlineView
                  validateDrop:(id<NSDraggingInfo>)info
                  proposedItem:(id)item
            proposedChildIndex:(NSInteger)index {

    if (targetNode && targetNode.nodeType == TreeNodeTypePlaylist) {
        // Option key: Copy, Default: Move
        BOOL optionKeyHeld = ([NSEvent modifierFlags] & NSEventModifierFlagOption) != 0;
        return optionKeyHeld ? NSDragOperationCopy : NSDragOperationMove;
    }
    return NSDragOperationNone;
}
```

The cursor icon changes automatically based on the returned operation.

### 14.6 Drop Target Highlighting vs Selection

NSOutlineView draws a special highlight for the proposed drop target (the row under cursor). This is NOT selection - it's internal visual feedback.

- **Selection:** Blue background, controlled by `selectRowIndexes:`
- **Drop target highlight:** Automatic during drag based on `validateDrop:` return value

The drop target highlight should clear automatically when drag ends. If it persists:

```objc
- (void)performDragCleanup {
    // Preserve selection across reload
    NSIndexSet *selection = [self.outlineView.selectedRowIndexes copy];
    [self.outlineView reloadData];  // Clears lingering drop target state
    if (selection.count > 0) {
        [self.outlineView selectRowIndexes:selection byExtendingSelection:NO];
    }
}
```

### 14.7 Custom NSOutlineView Subclass for Drag Callbacks

To receive `draggingEntered:`, `draggingExited:`, and `draggingEnded:` callbacks, subclass NSOutlineView:

```objc
// PlorgOutlineView.h
@protocol PlorgOutlineViewDelegate <NSOutlineViewDelegate>
@optional
- (void)outlineView:(NSOutlineView *)outlineView draggingEntered:(id<NSDraggingInfo>)sender;
- (void)outlineView:(NSOutlineView *)outlineView draggingExited:(id<NSDraggingInfo>)sender;
- (void)outlineView:(NSOutlineView *)outlineView draggingEnded:(id<NSDraggingInfo>)sender;
@end

@interface PlorgOutlineView : NSOutlineView
@end

// PlorgOutlineView.mm
@implementation PlorgOutlineView

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    // Do NOT call super - causes hangs
    id<PlorgOutlineViewDelegate> delegate = (id)self.delegate;
    if ([delegate respondsToSelector:@selector(outlineView:draggingEntered:)]) {
        [delegate outlineView:self draggingEntered:sender];
    }
    return NSDragOperationNone;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
    id<PlorgOutlineViewDelegate> delegate = (id)self.delegate;
    if ([delegate respondsToSelector:@selector(outlineView:draggingExited:)]) {
        [delegate outlineView:self draggingExited:sender];
    }
}

- (void)draggingEnded:(id<NSDraggingInfo>)sender {
    id<PlorgOutlineViewDelegate> delegate = (id)self.delegate;
    if ([delegate respondsToSelector:@selector(outlineView:draggingEnded:)]) {
        [delegate outlineView:self draggingEnded:sender];
    }
}

@end
```

---

## References

- Apple Documentation: [Drag and Drop](https://developer.apple.com/documentation/appkit/drag_and_drop)
- Apple Documentation: [NSPasteboard](https://developer.apple.com/documentation/appkit/nspasteboard)
- foobar2000 SDK: `playlist.h` (queue operations)
- Knowledge Base: `04_UI_ELEMENT_IMPLEMENTATION.md`
