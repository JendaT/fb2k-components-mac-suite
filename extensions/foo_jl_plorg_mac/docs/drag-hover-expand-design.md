# Drag-Hover-Expand Feature Design

## Overview

Enable plorg to accept track drops from simplaylist/playlist components, with hover-to-expand behavior that automatically opens folders or activates playlists when items are dragged over them.

## Current State

### What Exists
- Internal drag-drop for reordering plorg items (folders/playlists)
- Pasteboard type: `com.foobar2000.plorg.node`
- Folder expand/collapse via disclosure triangle click
- NSOutlineViewDataSource drag methods: `validateDrop:` and `acceptDrop:`

### What's Missing
- No acceptance of external drags (simplaylist tracks)
- No hover detection during drag operations
- No auto-expand on hover
- No visual feedback for external drop targets

---

## Pasteboard Types

### To Accept

| Type | Constant | Source | Data Format |
|------|----------|--------|-------------|
| SimPlaylist rows | `com.foobar2000.simplaylist.rows` | SimPlaylistView | `NSArray<NSNumber*>` row indices (NSKeyedArchiver) |
| Files | `NSPasteboardTypeFileURL` | Finder | File URLs |
| Internal | `com.foobar2000.plorg.node` | Plorg (existing) | Node path (NSKeyedArchiver) |

### Pasteboard Type Constants

```objc
// File scope constants (before @implementation)
static NSPasteboardType const PlorgNodePasteboardType = @"com.foobar2000.plorg.node";
static NSPasteboardType const SimPlaylistPasteboardType = @"com.foobar2000.simplaylist.rows";
```

### Row Indices Semantics

SimPlaylist writes row indices referencing the **active playlist at drag start**. Important considerations:
- Indices are 0-based positions in the source playlist
- If source playlist is modified during drag (rare), indices may be stale
- Implementation MUST validate indices are in bounds before use (see §5 for bounds checking)

### Pasteboard Type Priority

When a drag contains multiple types, they are checked in this order:
1. `SimPlaylistPasteboardType` - Preferred for inter-component drops
2. `NSPasteboardTypeFileURL` - Fallback for Finder/file drags
3. Internal plorg node - Internal reordering only

This order ensures SimPlaylist drags take precedence even if the pasteboard also contains file URLs.

---

## Architecture

### Approach: Inline Implementation

All drag-hover logic will be implemented directly in `PlaylistOrganizerController`. The feature is simple enough that separate classes (DragHoverManager, DropTargetValidator) would add unnecessary indirection.

### Threading Model

All drag-drop code executes on the main thread. This is required because:
- NSOutlineView callbacks run on main thread
- NSTimer requires main thread for UI-related actions
- foobar2000 SDK playlist operations must be called from main thread

Note: `playlist_manager::get()` returns a thread-safe singleton, but actual playlist operations should always be performed on the main thread per SDK requirements.

### State Management

State is tracked implicitly via two instance variables:
- `_dragHoveredNode` - Currently hovered node (nil if none)
- `_hoverTimer` - Active timer (nil if no pending hover action)

```
No explicit state enum needed. State is derived:
- IDLE:          _hoverTimer == nil && _dragHoveredNode == nil
- HOVER_PENDING: _hoverTimer != nil && _dragHoveredNode != nil

Note: After timer fires, both ivars are set to nil, returning to IDLE.
Edge case: If _dragHoveredNode becomes nil (weak ref zeroed) while timer is pending,
the callback safely no-ops via null check.
```

Timer cancellation occurs when:
- `validateDrop:` called with a different item (restart timer for new item)
- `acceptDrop:` called (drop completed)
- `draggingEnded:` called (drag operation ended for any reason - drop, cancel, ESC)
- `draggingExited:` called (drag left the view)
- `dealloc` / `viewWillDisappear` (controller lifecycle)

Note: `validateDrop:` is called repeatedly during drag (every mouse move). The timer restart logic handles this by only restarting when the target item changes.

---

## Implementation Details

### 1. Registration (viewDidLoad)

```objc
// Add to existing registration in viewDidLoad
[self.outlineView registerForDraggedTypes:@[
    PlorgNodePasteboardType,                 // Internal (existing)
    SimPlaylistPasteboardType,               // SimPlaylist tracks
    NSPasteboardTypeFileURL                  // Finder files
]];
```

### 2. Instance Variables

```objc
// File scope constant (before @implementation, after pasteboard type constants)
static const NSTimeInterval kHoverExpandDelay = 1.0;

@implementation PlaylistOrganizerController {
    // Existing ivars...

    // Drag hover state
    __weak TreeNode *_dragHoveredNode;
    NSTimer *_hoverTimer;
    BOOL _hasPendingExpansionSave;  // Batch expansion persistence
}
```

### 3. Hover Timer Management

```objc
#pragma mark - Drag Hover Timer

- (void)startHoverTimerForNode:(TreeNode *)node {
    [self cancelHoverTimer];
    if (!node) return;

    _dragHoveredNode = node;
    __weak typeof(self) weakSelf = self;
    __weak TreeNode *weakNode = node;

    // Create timer WITHOUT scheduling (scheduledTimer uses wrong runloop mode)
    _hoverTimer = [NSTimer timerWithTimeInterval:kHoverExpandDelay
                                         repeats:NO
                                           block:^(NSTimer *timer) {
        [weakSelf handleHoverTimeoutForNode:weakNode];
    }];

    // Schedule in event tracking mode - REQUIRED for timer to fire during drag
    [[NSRunLoop currentRunLoop] addTimer:_hoverTimer forMode:NSEventTrackingRunLoopMode];
}

- (void)cancelHoverTimer {
    [_hoverTimer invalidate];
    _hoverTimer = nil;
    _dragHoveredNode = nil;
}

- (void)handleHoverTimeoutForNode:(TreeNode *)node {
    if (!node || node != _dragHoveredNode) return;

    _hoverTimer = nil;  // Clear reference to fired timer (matches IDLE state: _hoverTimer == nil)

    if (node.nodeType == TreeNodeTypeFolder) {
        // Expand closed folder
        if (![self.outlineView isItemExpanded:node]) {
            [self.outlineView expandItem:node];
            node.isExpanded = YES;
            _hasPendingExpansionSave = YES;  // Defer save until drag ends
        }
    } else if (node.nodeType == TreeNodeTypePlaylist) {
        // Activate playlist in foobar2000
        [self activatePlaylistNamed:node.name];
    }

    _dragHoveredNode = nil;  // Prevent re-trigger on same node
}
```

### 4. NSOutlineViewDataSource Drag Methods

```objc
#pragma mark - NSOutlineViewDataSource (Drag)

- (NSDragOperation)outlineView:(NSOutlineView *)outlineView
                  validateDrop:(id<NSDraggingInfo>)info
                  proposedItem:(id)item
            proposedChildIndex:(NSInteger)index
{
    NSPasteboard *pb = info.draggingPasteboard;
    TreeNode *targetNode = (TreeNode *)item;

    // Handle external SimPlaylist drops (checked first - highest priority)
    if ([pb.types containsObject:SimPlaylistPasteboardType]) {
        // Update hover timer when target changes
        if (targetNode != _dragHoveredNode) {
            [self startHoverTimerForNode:targetNode];
        }

        // Accept drops on playlists (tracks append to end regardless of drop position)
        if (targetNode && targetNode.nodeType == TreeNodeTypePlaylist) {
            return NSDragOperationCopy;
        }
        // Folders: hover-expand only, no drop accepted
        return NSDragOperationNone;
    }

    // Handle file drops - HOVER WORKS, DROP DISABLED UNTIL PHASE 4
    if ([pb.types containsObject:NSPasteboardTypeFileURL]) {
        if (targetNode != _dragHoveredNode) {
            [self startHoverTimerForNode:targetNode];
        }
        // Phase 4: Enable drop by returning NSDragOperationCopy for playlists
        return NSDragOperationNone;  // Don't show valid drop cursor until implemented
    }

    // Handle internal plorg node drops (existing behavior)
    if ([pb.types containsObject:PlorgNodePasteboardType]) {
        [self cancelHoverTimer];  // No hover for internal drags
        // ... preserve existing internal drop validation logic unchanged ...
        return [self validateInternalDrop:info proposedItem:item proposedChildIndex:index];
    }

    return NSDragOperationNone;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView
         acceptDrop:(id<NSDraggingInfo>)info
               item:(id)item
         childIndex:(NSInteger)index
{
    [self cancelHoverTimer];
    // Note: flushPendingExpansionSave handled by draggingEnded: (called after every drag)

    NSPasteboard *pb = info.draggingPasteboard;
    TreeNode *targetNode = (TreeNode *)item;

    if ([pb.types containsObject:SimPlaylistPasteboardType]) {
        return [self handleSimPlaylistDrop:info targetNode:targetNode];
    }

    if ([pb.types containsObject:NSPasteboardTypeFileURL]) {
        return [self handleFileDrop:info targetNode:targetNode];
    }

    if ([pb.types containsObject:PlorgNodePasteboardType]) {
        return [self handleInternalDrop:info targetNode:targetNode index:index];
    }

    return NO;
}
```

### 5. SimPlaylist Drop Handler

```objc
- (BOOL)handleSimPlaylistDrop:(id<NSDraggingInfo>)info targetNode:(TreeNode *)targetNode {
    if (!targetNode || targetNode.nodeType != TreeNodeTypePlaylist) {
        return NO;
    }

    NSPasteboard *pb = info.draggingPasteboard;
    NSData *data = [pb dataForType:SimPlaylistPasteboardType];
    if (!data) return NO;

    // Decode dropped row indices
    NSError *error;
    NSSet *classes = [NSSet setWithArray:@[NSArray.class, NSMutableArray.class, NSNumber.class]];
    NSArray<NSNumber*> *rowIndices = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes
                                                                         fromData:data
                                                                            error:&error];
    if (!rowIndices || rowIndices.count == 0 || error) {
        if (error) {
            NSLog(@"plorg: Failed to decode dropped rows: %@", error);
        }
        return NO;
    }

    // Get source and target playlist indices
    auto pm = playlist_manager::get();
    size_t sourcePlaylistIndex = pm->get_active_playlist();
    size_t targetPlaylistIndex = pm->find_playlist(
        [targetNode.name UTF8String],
        pfc_infinite
    );

    if (sourcePlaylistIndex == pfc_infinite) {
        NSLog(@"plorg: No active playlist for drop source");
        return NO;
    }
    if (targetPlaylistIndex == pfc_infinite) {
        NSLog(@"plorg: Target playlist '%@' not found", targetNode.name);
        return NO;
    }

    // Build bit_array for selected rows WITH BOUNDS CHECKING
    size_t sourceItemCount = pm->playlist_get_item_count(sourcePlaylistIndex);
    if (sourceItemCount == 0) {
        return NO;
    }

    pfc::bit_array_bittable selection(sourceItemCount);
    size_t validCount = 0;
    for (NSNumber *index in rowIndices) {
        size_t idx = index.unsignedIntegerValue;
        if (idx < sourceItemCount) {
            selection.set(idx, true);
            validCount++;
        }
        // Silently ignore out-of-bounds indices (stale from playlist modification)
    }

    if (validCount == 0) {
        return NO;
    }

    // Get tracks from source playlist
    metadb_handle_list tracks;
    pm->playlist_get_items(sourcePlaylistIndex, tracks, selection);

    if (tracks.get_count() == 0) {
        return NO;
    }

    // Add tracks to target playlist, selecting newly added items
    size_t insertPosition = pm->playlist_get_item_count(targetPlaylistIndex);
    pm->playlist_insert_items(targetPlaylistIndex, insertPosition, tracks, pfc::bit_array_true());

    return YES;
}
```

### 6. File Drop Handler

```objc
- (BOOL)handleFileDrop:(id<NSDraggingInfo>)info targetNode:(TreeNode *)targetNode {
    if (!targetNode || targetNode.nodeType != TreeNodeTypePlaylist) {
        return NO;
    }

    NSPasteboard *pb = info.draggingPasteboard;
    NSArray *urls = [pb readObjectsForClasses:@[NSURL.class]
                                      options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    if (!urls || urls.count == 0) {
        return NO;
    }

    // Find target playlist
    auto pm = playlist_manager::get();
    size_t targetPlaylistIndex = pm->find_playlist(
        [targetNode.name UTF8String],
        pfc_infinite
    );

    if (targetPlaylistIndex == pfc_infinite) {
        return NO;
    }

    // Convert URLs to paths and add to playlist
    pfc::list_t<const char*> paths;
    std::vector<std::string> pathStorage;  // Keep strings alive
    pathStorage.reserve(urls.count);

    for (NSURL *url in urls) {
        if (url.isFileURL) {
            pathStorage.push_back([url.path UTF8String]);
            paths.add_item(pathStorage.back().c_str());
        }
    }

    if (paths.get_count() == 0) {
        return NO;
    }

    // TODO: Phase 4 - Implement async file import
    // Use playlist_incoming_item_filter to add files
    // This handles media files, playlists, and directories
    // Actual implementation requires async handling via playlist_incoming_item_filter_v2
    // or similar SDK pattern

    return NO;  // Not yet implemented
}
```

### 7. Playlist Activation

```objc
- (void)activatePlaylistNamed:(NSString *)name {
    if (!name) return;

    auto pm = playlist_manager::get();
    size_t index = pm->find_playlist([name UTF8String], pfc_infinite);

    if (index != pfc_infinite) {
        pm->set_active_playlist(index);
    }
}
```

### 8. Timer Cleanup on Drag Exit (PlorgOutlineView Subclass)

NSOutlineView handles drag destination callbacks internally. To receive drag lifecycle callbacks, subclass NSOutlineView:

```objc
// PlorgOutlineView.h
@protocol PlorgOutlineViewDelegate <NSOutlineViewDelegate>
@optional
- (void)outlineView:(NSOutlineView *)outlineView draggingExited:(id<NSDraggingInfo>)sender;
- (void)outlineView:(NSOutlineView *)outlineView draggingEnded:(id<NSDraggingInfo>)sender;
@end

@interface PlorgOutlineView : NSOutlineView
@end

// PlorgOutlineView.m
@implementation PlorgOutlineView

- (void)draggingExited:(id<NSDraggingInfo>)sender {
    [super draggingExited:sender];

    id<PlorgOutlineViewDelegate> delegate = (id)self.delegate;
    if ([delegate respondsToSelector:@selector(outlineView:draggingExited:)]) {
        [delegate outlineView:self draggingExited:sender];
    }
}

// CRITICAL: draggingEnded: is called when ANY drag operation ends (drop, cancel, ESC).
// This is the definitive cleanup point. Without this, ESC to cancel while over the view
// would leave the hover timer running.
- (void)draggingEnded:(id<NSDraggingInfo>)sender {
    [super draggingEnded:sender];

    id<PlorgOutlineViewDelegate> delegate = (id)self.delegate;
    if ([delegate respondsToSelector:@selector(outlineView:draggingEnded:)]) {
        [delegate outlineView:self draggingEnded:sender];
    }
}

@end
```

Note: `concludeDragOperation:` is only called after `acceptDrop:` returns YES. We use `draggingEnded:` instead because it's called unconditionally when any drag ends.

### 9. Controller Delegate Implementation

```objc
#pragma mark - PlorgOutlineViewDelegate

- (void)outlineView:(NSOutlineView *)outlineView draggingExited:(id<NSDraggingInfo>)sender {
    [self cancelHoverTimer];
    // Don't flush here - drag may re-enter, and draggingEnded: will handle final cleanup
}

- (void)outlineView:(NSOutlineView *)outlineView draggingEnded:(id<NSDraggingInfo>)sender {
    [self cancelHoverTimer];
    [self flushPendingExpansionSave];
}

- (void)flushPendingExpansionSave {
    if (_hasPendingExpansionSave) {
        [self saveTreeToYAML];
        _hasPendingExpansionSave = NO;
    }
}
```

### 10. Lifecycle Cleanup

```objc
- (void)dealloc {
    [self cancelHoverTimer];
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    [self cancelHoverTimer];
    [self flushPendingExpansionSave];
}
```

---

## Drop Behavior Matrix

| Drag Source | Drop Target | Hover Action | Drop Action | Operation |
|-------------|-------------|--------------|-------------|-----------|
| SimPlaylist rows | Playlist | Activate playlist | Add tracks (selected) | Copy |
| SimPlaylist rows | Folder | Expand folder | Reject | None |
| SimPlaylist rows | Root (nil) | None | Reject | None |
| Finder files | Playlist | Activate playlist | Reject (Phase 4) | None |
| Finder files | Folder | Expand folder | Reject | None |
| Finder files | Root (nil) | None | Reject | None |
| Plorg node | Playlist | None | Reorder/move | Move |
| Plorg node | Folder | None | Move into folder | Move |
| Plorg node | Root (nil) | None | Move to root level | Move |

Note: Internal plorg drags (node reordering) do not trigger hover-expand. This is intentional - folder expansion during reordering would be disorienting and users can expand manually before starting the drag.

---

## Visual Feedback

Standard NSOutlineView drop highlighting is used. No custom visual feedback.

NSOutlineView provides:
- Row highlight when hovering over valid drop target
- Insertion indicator line for between-row drops
- No-drop cursor when over invalid targets

---

## Design Decisions

### D1: Track Transfer via SDK

Tracks are transferred using `playlist_manager` SDK:
1. Get active playlist index as source
2. Find target playlist by name
3. Build `bit_array_bittable` from row indices (with bounds validation)
4. Call `playlist_get_items()` to retrieve track handles
5. Call `playlist_insert_items()` to add to target with selection

### D2: Hover Delay

Fixed at 1.0 second (matches macOS Finder behavior). Not configurable.

### D3: Folder Expansion Persistence

Folders auto-expanded during drag remain expanded after drop. Expansion state is persisted to YAML, but save is deferred until drag operation completes (prevents multiple I/O during rapid folder exploration).

### D4: NSTimer with Event Tracking Mode

NSTimer must be scheduled in `NSEventTrackingRunLoopMode` to fire during drag operations. The default `scheduledTimerWithTimeInterval:` uses `NSDefaultRunLoopMode` which does not run during event tracking.

### D5: Inserted Tracks Selected

Newly inserted tracks are selected (`bit_array_true()`) so user can see what was added. This matches standard drag-drop UX.

### D6: Stale Index Handling

Row indices that exceed current playlist bounds are silently ignored. This handles the rare case where source playlist is modified during drag.

### D7: Source Playlist Identification

SimPlaylist pasteboard data contains only row indices, not the source playlist identifier. The implementation uses `get_active_playlist()` at drop time to determine the source.

**Known limitation:** If the active playlist changes during drag, the wrong source is used. This is inherent to the SimPlaylist pasteboard format and cannot be fixed in plorg alone.

**Risk:** Low - requires user to actively change playlists while holding a drag.

**Mitigation:** None available without SimPlaylist pasteboard format changes.

### D8: Target Playlist Identification

Target playlist is identified by name via `find_playlist([targetNode.name UTF8String], pfc_infinite)`.

**Known limitation:** If the target playlist is renamed during drag, the drop fails gracefully (returns NO).

**Risk:** Very low - requires user to rename a playlist while holding a drag over it.

**Mitigation:** None needed - graceful failure is acceptable for this edge case.

### D9: No Auto-Activation on Drop

Dropping tracks does NOT activate the target playlist. Rationale:
- Hover-to-activate already provides this if user wants it (hold over playlist for 1s)
- Auto-switching could be jarring for rapid multi-playlist operations
- Selection in target playlist ensures tracks are visible when user navigates there

---

## Testing Plan

### Manual Test Cases

| # | Scenario | Expected Result |
|---|----------|-----------------|
| T1 | Drag from simplaylist, hover over closed folder 1s | Folder expands |
| T2 | Drag from simplaylist, hover over playlist 1s | Playlist activates in player |
| T3 | Drag from simplaylist, drop on playlist | Tracks added, newly added tracks selected |
| T4 | Drag from simplaylist, drop on folder | Rejected (no drop) |
| T5 | Drag from simplaylist, move away before 1s | No expansion |
| T6 | Drag from simplaylist, exit plorg view | Timer cancelled, no action |
| T7 | Rapid hover over multiple items | Only last item triggers after delay |
| T8 | Internal plorg drag | Existing behavior unchanged, no hover timer |
| T9 | Source playlist deleted during drag | Drop fails gracefully (returns NO) |
| T10 | Target playlist deleted during drag | Drop fails gracefully (find_playlist returns pfc_infinite) |
| T11 | Drag exits window entirely | Timer cancelled via draggingExited: or draggingEnded: |
| T12 | Drop empty selection | No tracks added, returns NO |
| T13 | Drop with stale/out-of-bounds indices | Valid indices processed, invalid ignored |
| T14 | Expand multiple folders via hover, then drop | Single YAML save after drop completes |
| T15 | Drag files from Finder to playlist | No valid drop cursor shown, hover-expand still works |
| T16 | Drag files from Finder to folder | Folder expands, drop rejected |
| T17 | Drag, expand folders via hover, press ESC | Timer cancelled via draggingEnded:, expansions persist |
| T18 | Drag from SimPlaylist to same playlist (via plorg) | Tracks duplicated at end (valid behavior) |
| T19 | Target playlist renamed during drag | Drop fails gracefully (returns NO) |
| T20 | Rapid drag across multiple items | Only last hovered item triggers, no timer accumulation |
| T21 | Drag files from Finder to root area | Drop rejected, no hover action |

---

## Implementation Phases

### Phase 1: Hover-Expand Foundation
- Add pasteboard registration
- Implement PlorgOutlineView subclass for drag lifecycle callbacks (draggingExited:, draggingEnded:)
- Implement hover timer with NSTimer (NSEventTrackingRunLoopMode)
- Auto-expand folders on hover
- Deferred expansion persistence (flush on draggingEnded:)

### Phase 2: Playlist Activation
- Activate playlist on hover timeout via `activatePlaylistNamed:`

### Phase 3: Track Drop Handling
- Decode SimPlaylist row indices
- Bounds-check indices before use
- Retrieve track handles via SDK
- Add tracks to target playlist with selection
- Handle all error cases gracefully

### Phase 4: File Drop Support
- Accept `NSPasteboardTypeFileURL`
- Import files to target playlist via SDK
- Handle directories and playlists

---

## Files to Modify

| File | Changes |
|------|---------|
| `PlaylistOrganizerController.mm` | Registration, validateDrop:, acceptDrop:, timer logic, dealloc |
| `PlorgOutlineView.h` (new) | Subclass header with PlorgOutlineViewDelegate protocol |
| `PlorgOutlineView.mm` (new) | Subclass implementation forwarding draggingExited:/draggingEnded: |

---

## References

- `SimPlaylistView.mm:1994-2328` - SimPlaylist drag implementation
- `QueueManagerController.mm:196-344` - Queue Manager drop handling (pattern reference)
- Apple: [Drag and Drop Programming Topics](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/DragandDrop/DragandDrop.html)
- Apple: [NSTimer and Run Loop Modes](https://developer.apple.com/documentation/foundation/nstimer)
- foobar2000 SDK: `playlist_manager` interface
