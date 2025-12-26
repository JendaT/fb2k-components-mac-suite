# foo_simplaylist_mac - Implementation Specification

**Document Version:** 1.0
**Date:** December 2025
**Status:** Research Complete - Ready for Implementation
**Prerequisites:** Read FOUNDATION.md first

---

## Table of Contents

1. [Use Cases](#1-use-cases)
2. [Edge Cases & Error Handling](#2-edge-cases--error-handling)
3. [SDK Hooks & Callbacks](#3-sdk-hooks--callbacks)
4. [Visual Component Specifications](#4-visual-component-specifications)
5. [Data Flow Architecture](#5-data-flow-architecture)
6. [Configuration System](#6-configuration-system)
7. [Implementation Plan](#7-implementation-plan)
8. [Testing Strategy](#8-testing-strategy)

---

## 1. Use Cases

### 1.1 Primary Use Cases

#### UC-1: Basic Playlist Display
**Actor:** User
**Description:** User views the current playlist with tracks grouped by album
**Preconditions:** Active playlist exists with tracks
**Flow:**
1. User adds SimPlaylist element to layout
2. SimPlaylist reads active playlist via `playlist_manager`
3. Groups are calculated based on active grouping preset
4. View renders headers, group columns (with album art), and track rows
5. Selection state is preserved and displayed

**Expected Result:** Playlist displayed with hierarchical grouping, album art visible in group column

#### UC-2: Track Selection
**Actor:** User
**Description:** User selects one or more tracks in the playlist
**Flow:**
1. User clicks on a track row
2. Single-click selects track, Cmd+click adds to selection, Shift+click extends selection
3. Selection is synchronized with playlist_manager via `playlist_set_selection()`
4. View updates to show selection highlighting

**Variants:**
- UC-2a: Select all tracks in a group (click on header)
- UC-2b: Select all tracks in a subgroup
- UC-2c: Rubber-band selection (drag to select multiple)

#### UC-3: Playback Initiation
**Actor:** User
**Description:** User double-clicks a track to start playback
**Flow:**
1. User double-clicks track row
2. SimPlaylist calls `playlist_execute_default_action()`
3. Playback starts from that track
4. Currently playing track is highlighted (playing indicator column)

#### UC-4: Context Menu Operations
**Actor:** User
**Description:** User right-clicks to access track operations
**Flow:**
1. User right-clicks on track(s)
2. Context menu appears with standard foobar2000 options
3. User selects operation (e.g., Remove, Properties, Send to...)
4. Operation executes, playlist updates via callbacks

#### UC-5: Seeking via Click
**Actor:** User
**Description:** User clicks duration column to seek within track
**Flow:**
1. User clicks on duration column of currently playing track
2. Duration column toggles between elapsed/remaining display
3. (Alternative) Clicking at position seeks to that time

#### UC-6: Album Art Resizing
**Actor:** User
**Description:** User adjusts album art display size
**Flow:**
1. User holds Ctrl and scrolls mouse wheel over group column
2. Album art size increases/decreases
3. Group column width adjusts accordingly
4. Preference is saved

#### UC-7: Column Reordering
**Actor:** User
**Description:** User reorders columns by dragging headers
**Flow:**
1. User drags column header to new position
2. Column order updates in real-time during drag
3. On drop, new order is persisted to config
4. All playlist views reflect new column order

#### UC-8: Group Preset Change
**Actor:** User
**Description:** User switches between grouping presets
**Flow:**
1. User opens Preferences > Display > SimPlaylist > Groups
2. User selects different preset from dropdown
3. Groups are recalculated
4. View re-renders with new grouping

### 1.2 Secondary Use Cases

#### UC-9: Inline Rating Edit
**Actor:** User
**Description:** User clicks rating column to change track rating
**Flow:**
1. User clicks on rating value in rating column
2. Rating updates (toggle or increment depending on implementation)
3. Track metadata is updated via metadb
4. Column reflects new value immediately

#### UC-10: Search Filter
**Actor:** User
**Description:** User filters playlist view by search term
**Flow:**
1. User presses F3 or clicks search element
2. Search field appears/focuses
3. User types search term
4. View filters to show only matching tracks
5. Groups with no matching tracks collapse/hide

#### UC-11: Drag & Drop Reorder
**Actor:** User
**Description:** User reorders tracks within playlist by dragging
**Flow:**
1. User selects track(s) and begins drag
2. Drop indicator shows insertion point
3. User drops at new position
4. Playlist reorders via `playlist_reorder_items()`
5. Groups recalculate if necessary

#### UC-12: Drag & Drop Import
**Actor:** User
**Description:** User drops files onto SimPlaylist
**Flow:**
1. User drags files from Finder onto SimPlaylist
2. Drop zone indicator appears
3. Files are processed via `playlist_incoming_item_filter`
4. New tracks inserted at drop position
5. View updates with new items

#### UC-13: Active Playlist Switch
**Actor:** System/User
**Description:** Active playlist changes in foobar2000
**Flow:**
1. User selects different playlist in playlist switcher
2. `on_playlist_activate` callback fires
3. SimPlaylist rebuilds view for new playlist
4. Scroll position resets to top (or saved position if available)

---

## 2. Edge Cases & Error Handling

### 2.1 Empty States

| Scenario | Expected Behavior |
|----------|------------------|
| Empty playlist | Display "Playlist is empty" message centered |
| Playlist with 0 matches after search | Display "No matches found" |
| All items in group removed | Group header/column removed |
| Last subgroup in group removed | Subgroup row removed, tracks promoted |

### 2.2 Large Playlists

| Scenario | Handling Strategy |
|----------|------------------|
| 10,000+ tracks | Virtual scrolling - only render visible rows |
| 1,000+ groups | Lazy group calculation - calculate on scroll |
| Complex title formatting | Cache formatted strings, invalidate on metadata change |
| Many album art images | LRU cache with size limit (50-100MB), async loading |

### 2.3 Data Integrity

| Scenario | Handling Strategy |
|----------|------------------|
| Missing album art | Display placeholder image |
| Invalid title format pattern | Fall back to `%filename%`, log warning |
| Track removed during playback | Update view, continue playback of next track |
| Metadata update during display | Invalidate affected rows, re-render |
| Playlist locked | Gray out modification controls, show lock indicator |

### 2.4 Concurrent Modifications

| Scenario | Handling Strategy |
|----------|------------------|
| Items added during scroll | Batch updates, apply at end of scroll |
| Rapid selection changes | Debounce view updates (16ms frame time) |
| Group recalc during animation | Queue recalc, apply after animation complete |

### 2.5 Error Recovery

```objc
// Pattern for error handling in callbacks
- (void)handlePlaylistModification:(NSNotification *)notification {
    @try {
        [self recalculateGroups];
        [self setNeedsDisplay:YES];
    } @catch (NSException *exception) {
        console::error("SimPlaylist: Failed to update groups");
        // Fall back to flat list display
        [self displayFlatList];
    }
}
```

### 2.6 Memory Pressure

```objc
// Respond to memory warnings
- (void)handleMemoryWarning:(NSNotification *)notification {
    // Clear album art cache
    [_albumArtCache removeAllObjects];

    // Clear formatted string cache
    [_formattedStringCache removeAllObjects];

    // Keep only essential data
    [self compactGroupModel];
}
```

---

## 3. SDK Hooks & Callbacks

### 3.1 Required Callbacks

#### playlist_callback_single (Primary - Active Playlist Only)

```cpp
class simplaylist_playlist_callback : public playlist_callback_single_impl_base {
public:
    simplaylist_playlist_callback()
        : playlist_callback_single_impl_base(
            flag_on_items_added |
            flag_on_items_removed |
            flag_on_items_reordered |
            flag_on_items_selection_change |
            flag_on_item_focus_change |
            flag_on_items_modified |
            flag_on_playlist_switch
        ) {}

    // Called when items are added to active playlist
    void on_items_added(t_size p_base, metadb_handle_list_cref p_data,
                        const bit_array & p_selection) override {
        // Recalculate groups for affected range
        // Update view
        notifyControllersItemsAdded(p_base, p_data.get_count());
    }

    // Called when items are removed from active playlist
    void on_items_removed(const bit_array & p_mask,
                         t_size p_old_count, t_size p_new_count) override {
        // Remove items from model
        // Recalculate affected groups
        notifyControllersItemsRemoved(p_mask);
    }

    // Called when items are reordered
    void on_items_reordered(const t_size * p_order, t_size p_count) override {
        // Full rebuild of groups (order changed)
        notifyControllersItemsReordered();
    }

    // Called when selection changes
    void on_items_selection_change(const bit_array & p_affected,
                                   const bit_array & p_state) override {
        // Update selection display
        notifyControllersSelectionChanged(p_affected, p_state);
    }

    // Called when focus item changes
    void on_item_focus_change(t_size p_from, t_size p_to) override {
        notifyControllersFocusChanged(p_from, p_to);
    }

    // Called when metadata changes (e.g., rating edited)
    void on_items_modified(const bit_array & p_mask) override {
        // Recalculate groups for modified items (metadata-based grouping)
        // Re-render affected rows
        notifyControllersItemsModified(p_mask);
    }

    // Called when active playlist changes
    void on_playlist_switch() override {
        // Full rebuild
        notifyControllersPlaylistSwitched();
    }
};
```

#### play_callback_static (Playback State)

```cpp
class simplaylist_play_callback : public play_callback_static {
public:
    unsigned get_flags() override {
        return flag_on_playback_new_track |
               flag_on_playback_stop |
               flag_on_playback_time;  // For elapsed time display
    }

    void on_playback_new_track(metadb_handle_ptr p_track) override {
        // Update "now playing" indicator
        notifyControllersNowPlayingChanged(p_track);
    }

    void on_playback_stop(play_control::t_stop_reason p_reason) override {
        // Clear "now playing" indicator
        notifyControllersPlaybackStopped();
    }

    void on_playback_time(double p_time) override {
        // Update duration column display if showing elapsed time
        notifyControllersPlaybackTime(p_time);
    }

    // Unused but required
    void on_playback_starting(play_control::t_track_command, bool) override {}
    void on_playback_seek(double) override {}
    void on_playback_pause(bool) override {}
    void on_playback_edited(metadb_handle_ptr) override {}
    void on_playback_dynamic_info(const file_info&) override {}
    void on_playback_dynamic_info_track(const file_info&) override {}
    void on_volume_change(float) override {}
};
```

### 3.2 Callback Manager Pattern

```objc
// SimPlaylistCallbackManager.h
@interface SimPlaylistCallbackManager : NSObject

+ (instancetype)sharedManager;

- (void)registerController:(SimPlaylistController *)controller;
- (void)unregisterController:(SimPlaylistController *)controller;

@end

// SimPlaylistCallbackManager.mm
static std::vector<__weak SimPlaylistController*> g_controllers;
static std::mutex g_controllersMutex;

@implementation SimPlaylistCallbackManager

+ (instancetype)sharedManager {
    static SimPlaylistCallbackManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SimPlaylistCallbackManager alloc] init];
    });
    return instance;
}

- (void)notifyControllersOnMainThread:(void(^)(SimPlaylistController*))block {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);

        for (__weak SimPlaylistController* weak : g_controllers) {
            SimPlaylistController* controller = weak;
            if (controller) {
                block(controller);
            }
        }
    });
}

@end
```

### 3.3 Callback Registration

```cpp
// In Main.mm
namespace {
    FB2K_SERVICE_FACTORY(simplaylist_playlist_callback);
    FB2K_SERVICE_FACTORY(simplaylist_play_callback);

    class simplaylist_initquit : public initquit {
    public:
        void on_init() override {
            console::info("[SimPlaylist] Initialized");
        }
        void on_quit() override {
            // Cleanup
        }
    };

    FB2K_SERVICE_FACTORY(simplaylist_initquit);
}
```

### 3.4 Callback Flow Diagram

```
[User Action]          [SDK Callback]           [SimPlaylist Response]
     |                       |                          |
     v                       |                          |
Add tracks to playlist ------> on_items_added() -------> recalculateGroups()
     |                       |                          |    |
     |                       |                          |    v
     |                       |                          | updateView()
     |                       |                          |
Double-click track ---------> (via execute_default_action)
     |                       |                          |
     |                on_playback_new_track() ---------> updateNowPlayingIndicator()
```

---

## 4. Visual Component Specifications

### 4.1 View Hierarchy

```
SimPlaylistController (NSViewController)
    |
    +-- SimPlaylistView (NSView - main container)
          |
          +-- SimPlaylistHeaderBar (NSView - column headers)
          |     |
          |     +-- Column header cells (draggable)
          |
          +-- SimPlaylistScrollView (NSScrollView)
                |
                +-- SimPlaylistContentView (NSView - flipped, content area)
                      |
                      +-- Rendered via drawRect:
                            - Group headers
                            - Group columns (album art)
                            - Subgroup separators
                            - Track rows
```

### 4.2 Layout Calculations

#### Row Height Constants

```objc
typedef struct {
    CGFloat headerHeight;      // Default: 28.0
    CGFloat subgroupHeight;    // Default: 22.0
    CGFloat trackRowHeight;    // Default: 20.0
    CGFloat groupColumnWidth;  // Default: 80.0 (adjustable)
    CGFloat minColumnWidth;    // Default: 40.0
    CGFloat columnPadding;     // Default: 8.0
} SimPlaylistLayoutMetrics;
```

#### Content Size Calculation

```objc
- (NSSize)calculatedContentSize {
    CGFloat totalHeight = 0;

    for (GroupNode *node in _flattenedNodes) {
        switch (node.type) {
            case GroupNodeTypeHeader:
                totalHeight += _metrics.headerHeight;
                break;
            case GroupNodeTypeSubgroup:
                totalHeight += _metrics.subgroupHeight;
                break;
            case GroupNodeTypeTrack:
                totalHeight += _metrics.trackRowHeight;
                break;
        }
    }

    // Width is sum of all column widths
    CGFloat totalWidth = _metrics.groupColumnWidth;
    for (ColumnDefinition *col in _columns) {
        totalWidth += col.width;
    }

    return NSMakeSize(totalWidth, totalHeight);
}
```

### 4.3 Virtual Scrolling Implementation

```objc
// Only render visible rows
- (void)drawRect:(NSRect)dirtyRect {
    NSRect visibleRect = [self visibleRect];

    // Find first and last visible row
    NSInteger firstVisibleRow = [self rowAtPoint:NSMakePoint(0, NSMinY(visibleRect))];
    NSInteger lastVisibleRow = [self rowAtPoint:NSMakePoint(0, NSMaxY(visibleRect))];

    // Clamp to valid range
    firstVisibleRow = MAX(0, firstVisibleRow - 1);  // One extra for partial
    lastVisibleRow = MIN(_flattenedNodes.count - 1, lastVisibleRow + 1);

    // Draw only visible rows
    CGFloat y = [self yOffsetForRow:firstVisibleRow];

    for (NSInteger row = firstVisibleRow; row <= lastVisibleRow; row++) {
        GroupNode *node = _flattenedNodes[row];
        CGFloat rowHeight = [self heightForNode:node];
        NSRect rowRect = NSMakeRect(0, y, self.bounds.size.width, rowHeight);

        if (NSIntersectsRect(rowRect, dirtyRect)) {
            [self drawNode:node inRect:rowRect row:row];
        }

        y += rowHeight;
    }

    // Draw group column (spans multiple rows)
    [self drawGroupColumnsInRect:dirtyRect];
}
```

### 4.4 Group Column Rendering (Album Art Spanning)

```objc
- (void)drawGroupColumnsInRect:(NSRect)dirtyRect {
    CGRect groupColumnRect = CGRectMake(0, 0, _metrics.groupColumnWidth, self.bounds.size.height);

    if (!CGRectIntersectsRect(groupColumnRect, dirtyRect)) {
        return;  // Group column not visible
    }

    for (GroupInfo *group in _groups) {
        // Calculate group's vertical extent
        CGFloat groupTop = [self yOffsetForRow:group.firstRowIndex];
        CGFloat groupBottom = [self yOffsetForRow:group.lastRowIndex + 1];
        CGFloat groupHeight = groupBottom - groupTop;

        CGRect artRect = CGRectMake(
            4,  // Padding
            groupTop + 4,
            _metrics.groupColumnWidth - 8,
            MIN(groupHeight - 8, _metrics.groupColumnWidth - 8)  // Square, capped
        );

        // Only draw if visible
        if (CGRectIntersectsRect(artRect, dirtyRect)) {
            NSImage *albumArt = [_albumArtCache imageForGroup:group];
            if (albumArt) {
                [albumArt drawInRect:artRect
                            fromRect:NSZeroRect
                           operation:NSCompositingOperationSourceOver
                            fraction:1.0
                      respectFlipped:YES
                               hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
            } else {
                // Draw placeholder
                [self drawAlbumArtPlaceholderInRect:artRect];
            }
        }
    }
}
```

### 4.5 Color Scheme

```objc
@interface SimPlaylistColors : NSObject

+ (NSColor *)backgroundColor;
+ (NSColor *)alternateRowColor;
+ (NSColor *)selectionColor;
+ (NSColor *)headerBackgroundColor;
+ (NSColor *)headerTextColor;
+ (NSColor *)subgroupBackgroundColor;
+ (NSColor *)subgroupTextColor;
+ (NSColor *)trackTextColor;
+ (NSColor *)trackTextDimmedColor;      // For <dimmed> markup
+ (NSColor *)nowPlayingBackgroundColor;
+ (NSColor *)focusRingColor;

@end

@implementation SimPlaylistColors

+ (NSColor *)backgroundColor {
    return [NSColor colorWithName:@"SimPlaylistBackground" dynamicProvider:^(NSAppearance *appearance) {
        BOOL isDark = [appearance.name containsString:NSAppearanceNameDarkAqua];
        return isDark ? [NSColor colorWithWhite:0.15 alpha:1.0]
                      : [NSColor colorWithWhite:1.0 alpha:1.0];
    }];
}

+ (NSColor *)selectionColor {
    return [NSColor selectedContentBackgroundColor];
}

// ... other colors

@end
```

### 4.6 Text Rendering with Dimming Markup

```objc
// Parse `<dimmed>` and `>highlighted<` markup
- (NSAttributedString *)attributedStringFromFormattedText:(NSString *)text
                                           baseAttributes:(NSDictionary *)attrs {
    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] init];

    NSColor *normalColor = attrs[NSForegroundColorAttributeName];
    NSColor *dimmedColor = [SimPlaylistColors trackTextDimmedColor];

    NSRegularExpression *dimRegex = [NSRegularExpression
        regularExpressionWithPattern:@"<([^>]+)>" options:0 error:nil];

    __block NSUInteger lastEnd = 0;

    [dimRegex enumerateMatchesInString:text options:0 range:NSMakeRange(0, text.length)
                            usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
        // Add normal text before match
        if (match.range.location > lastEnd) {
            NSString *normal = [text substringWithRange:NSMakeRange(lastEnd, match.range.location - lastEnd)];
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:normal attributes:attrs]];
        }

        // Add dimmed text
        NSString *dimmed = [text substringWithRange:[match rangeAtIndex:1]];
        NSMutableDictionary *dimAttrs = [attrs mutableCopy];
        dimAttrs[NSForegroundColorAttributeName] = dimmedColor;
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:dimmed attributes:dimAttrs]];

        lastEnd = NSMaxRange(match.range);
    }];

    // Add remaining text
    if (lastEnd < text.length) {
        NSString *remaining = [text substringFromIndex:lastEnd];
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:remaining attributes:attrs]];
    }

    return result;
}
```

---

## 5. Data Flow Architecture

### 5.1 Component Diagram

```
+------------------+     +-------------------+     +------------------+
|   playlist_mgr   |     |   GroupModel      |     | SimPlaylistView  |
|   (SDK Service)  |<--->|   (Data Layer)    |<--->|   (UI Layer)     |
+------------------+     +-------------------+     +------------------+
        |                        |                        |
        |                        v                        |
        |                +-------------------+            |
        +--------------->| TitleFormatter    |<-----------+
        |                | (Pattern Eval)    |
        |                +-------------------+
        |                        |
        |                        v
        |                +-------------------+
        +--------------->| AlbumArtCache     |
                         | (Image Loading)   |
                         +-------------------+
```

### 5.2 Data Structures

#### GroupNode (Display Node)

```objc
typedef NS_ENUM(NSInteger, GroupNodeType) {
    GroupNodeTypeHeader,
    GroupNodeTypeSubgroup,
    GroupNodeTypeTrack
};

@interface GroupNode : NSObject

@property (nonatomic, assign) GroupNodeType type;
@property (nonatomic, copy) NSString *displayText;
@property (nonatomic, assign) NSInteger playlistIndex;  // -1 for non-tracks
@property (nonatomic, assign) NSInteger indentLevel;
@property (nonatomic, assign) BOOL isSelected;
@property (nonatomic, assign) BOOL isPlaying;
@property (nonatomic, assign) BOOL isFocused;

// For headers
@property (nonatomic, assign) NSInteger groupStartIndex;  // First track index
@property (nonatomic, assign) NSInteger groupEndIndex;    // Last track index
@property (nonatomic, copy) NSString *albumArtKey;        // For cache lookup

// For tracks
@property (nonatomic, strong) NSArray<NSString *> *columnValues;

@end
```

#### GroupInfo (Group Metadata)

```objc
@interface GroupInfo : NSObject

@property (nonatomic, copy) NSString *headerValue;       // Formatted header text
@property (nonatomic, copy) NSString *groupColumnValue;  // Formatted group column text
@property (nonatomic, assign) NSInteger firstTrackIndex; // In playlist
@property (nonatomic, assign) NSInteger lastTrackIndex;
@property (nonatomic, assign) NSInteger firstRowIndex;   // In flattened display
@property (nonatomic, assign) NSInteger lastRowIndex;
@property (nonatomic, strong) NSArray<SubgroupInfo *> *subgroups;

// Statistics
@property (nonatomic, assign) NSTimeInterval totalDuration;
@property (nonatomic, assign) NSInteger trackCount;
@property (nonatomic, assign) NSInteger totalFileSize;

@end
```

### 5.3 Group Calculation Algorithm

```objc
- (void)rebuildGroupsFromPlaylist:(NSInteger)playlistIndex {
    auto pm = playlist_manager::get();
    t_size itemCount = pm->playlist_get_item_count(playlistIndex);

    if (itemCount == 0) {
        _groups = @[];
        _flattenedNodes = @[];
        return;
    }

    // Step 1: Get all tracks
    NSMutableArray<metadb_handle_ptr> *tracks = [NSMutableArray array];
    for (t_size i = 0; i < itemCount; i++) {
        metadb_handle_ptr handle;
        if (pm->playlist_get_item_handle(handle, playlistIndex, i)) {
            [tracks addObject:handle];
        }
    }

    // Step 2: Sort by sorting pattern (if different from playlist order)
    // Note: For now, use playlist order; sorting can be added later

    // Step 3: Group by header pattern
    NSMutableArray<GroupInfo *> *groups = [NSMutableArray array];
    NSString *currentHeaderValue = nil;
    GroupInfo *currentGroup = nil;

    for (NSInteger i = 0; i < tracks.count; i++) {
        NSString *headerValue = [self formatTrack:tracks[i] withPattern:_config.headerPattern];

        if (![headerValue isEqualToString:currentHeaderValue]) {
            // New group
            if (currentGroup) {
                currentGroup.lastTrackIndex = i - 1;
                [groups addObject:currentGroup];
            }

            currentGroup = [[GroupInfo alloc] init];
            currentGroup.headerValue = headerValue;
            currentGroup.firstTrackIndex = i;
            currentHeaderValue = headerValue;
        }
    }

    // Don't forget last group
    if (currentGroup) {
        currentGroup.lastTrackIndex = tracks.count - 1;
        [groups addObject:currentGroup];
    }

    // Step 4: Build subgroups within each group
    for (GroupInfo *group in groups) {
        [self buildSubgroupsForGroup:group tracks:tracks];
    }

    // Step 5: Flatten to display list
    _groups = groups;
    _flattenedNodes = [self flattenGroups:groups tracks:tracks];
}

- (NSArray<GroupNode *> *)flattenGroups:(NSArray<GroupInfo *> *)groups
                                 tracks:(NSArray<metadb_handle_ptr> *)tracks {
    NSMutableArray<GroupNode *> *result = [NSMutableArray array];
    NSInteger rowIndex = 0;

    for (GroupInfo *group in groups) {
        // Header node
        GroupNode *headerNode = [[GroupNode alloc] init];
        headerNode.type = GroupNodeTypeHeader;
        headerNode.displayText = group.headerValue;
        headerNode.groupStartIndex = group.firstTrackIndex;
        headerNode.groupEndIndex = group.lastTrackIndex;
        headerNode.albumArtKey = [self albumArtKeyForTrackIndex:group.firstTrackIndex];
        [result addObject:headerNode];

        group.firstRowIndex = rowIndex++;

        // Subgroups and tracks
        if (group.subgroups.count > 0) {
            for (SubgroupInfo *subgroup in group.subgroups) {
                // Subgroup node
                GroupNode *subgroupNode = [[GroupNode alloc] init];
                subgroupNode.type = GroupNodeTypeSubgroup;
                subgroupNode.displayText = subgroup.value;
                subgroupNode.indentLevel = 1;
                [result addObject:subgroupNode];
                rowIndex++;

                // Tracks in subgroup
                for (NSInteger i = subgroup.firstIndex; i <= subgroup.lastIndex; i++) {
                    GroupNode *trackNode = [self trackNodeForIndex:i tracks:tracks indentLevel:2];
                    [result addObject:trackNode];
                    rowIndex++;
                }
            }
        } else {
            // Tracks directly in group (no subgroups)
            for (NSInteger i = group.firstTrackIndex; i <= group.lastTrackIndex; i++) {
                GroupNode *trackNode = [self trackNodeForIndex:i tracks:tracks indentLevel:1];
                [result addObject:trackNode];
                rowIndex++;
            }
        }

        group.lastRowIndex = rowIndex - 1;
    }

    return result;
}
```

### 5.4 Album Art Loading

```objc
@interface AlbumArtCache : NSObject

@property (nonatomic, strong) NSCache<NSString *, NSImage *> *imageCache;
@property (nonatomic, strong) NSOperationQueue *loadQueue;
@property (nonatomic, strong) NSMutableSet<NSString *> *pendingLoads;

- (void)loadImageForKey:(NSString *)key
              trackPath:(const char *)path
             completion:(void (^)(NSImage *image))completion;

- (NSImage *)cachedImageForKey:(NSString *)key;
- (void)clearCache;

@end

@implementation AlbumArtCache

- (void)loadImageForKey:(NSString *)key
              trackPath:(const char *)path
             completion:(void (^)(NSImage *image))completion {

    // Check cache first
    NSImage *cached = [_imageCache objectForKey:key];
    if (cached) {
        completion(cached);
        return;
    }

    // Check if already loading
    @synchronized (_pendingLoads) {
        if ([_pendingLoads containsObject:key]) {
            return;  // Already in progress
        }
        [_pendingLoads addObject:key];
    }

    // Load asynchronously
    [_loadQueue addOperationWithBlock:^{
        NSImage *image = nil;

        @try {
            // Use SDK album_art_manager
            auto art_mgr = album_art_manager_v3::get();

            album_art_extractor_instance_v2::ptr extractor;
            playable_location_impl loc(path, 0);

            if (art_mgr->open(extractor, make_playable_location_path(path),
                             fb2k::noAbort)) {
                album_art_data::ptr data;
                if (extractor->query(album_art_ids::cover_front, data,
                                    fb2k::noAbort)) {
                    // Convert to NSImage
                    NSData *imageData = [NSData dataWithBytes:data->data()
                                                       length:data->size()];
                    image = [[NSImage alloc] initWithData:imageData];
                }
            }
        } @catch (...) {
            console::error("SimPlaylist: Failed to load album art");
        }

        // Cache and callback on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            if (image) {
                [self->_imageCache setObject:image forKey:key];
            }

            @synchronized (self->_pendingLoads) {
                [self->_pendingLoads removeObject:key];
            }

            completion(image);
        });
    }];
}

@end
```

---

## 6. Configuration System

### 6.1 Config Keys

```cpp
namespace simplaylist_config {
    // Prefix for all config keys
    static const char* const kPrefix = "foo_simplaylist_mac.";

    // Groups configuration (stored as JSON)
    static const char* const kGroupPresets = "group_presets";
    static const char* const kActivePresetIndex = "active_preset_index";

    // Column configuration (stored as JSON)
    static const char* const kColumns = "columns";
    static const char* const kColumnOrder = "column_order";

    // Appearance
    static const char* const kRowHeight = "row_height";
    static const char* const kHeaderHeight = "header_height";
    static const char* const kGroupColumnWidth = "group_column_width";
    static const char* const kShowRowNumbers = "show_row_numbers";

    // Behavior
    static const char* const kAutoExpandGroups = "auto_expand_groups";
    static const char* const kSmoothScrolling = "smooth_scrolling";

    // Defaults
    static const int64_t kDefaultRowHeight = 20;
    static const int64_t kDefaultHeaderHeight = 28;
    static const int64_t kDefaultGroupColumnWidth = 80;
    static const bool kDefaultShowRowNumbers = false;
    static const bool kDefaultAutoExpandGroups = true;
}
```

### 6.2 Config Helper (Using fb2k::configStore)

```cpp
// ConfigHelper.h
#pragma once
#include "../fb2k_sdk.h"
#include <string>

namespace simplaylist_config {

inline std::string getFullKey(const char* key) {
    return std::string(kPrefix) + key;
}

inline int64_t getConfigInt(const char* key, int64_t defaultValue) {
    try {
        auto store = fb2k::configStore::get();
        if (store) {
            return store->getConfigInt(getFullKey(key).c_str(), defaultValue);
        }
    } catch (...) {}
    return defaultValue;
}

inline void setConfigInt(const char* key, int64_t value) {
    try {
        auto store = fb2k::configStore::get();
        if (store) {
            store->setConfigInt(getFullKey(key).c_str(), value);
        }
    } catch (...) {}
}

inline std::string getConfigString(const char* key, const char* defaultValue) {
    try {
        auto store = fb2k::configStore::get();
        if (store) {
            pfc::string8 out;
            store->getConfigString(getFullKey(key).c_str(), out, defaultValue);
            return std::string(out.c_str());
        }
    } catch (...) {}
    return defaultValue;
}

inline void setConfigString(const char* key, const char* value) {
    try {
        auto store = fb2k::configStore::get();
        if (store) {
            store->setConfigString(getFullKey(key).c_str(), value);
        }
    } catch (...) {}
}

} // namespace
```

### 6.3 Preset JSON Format

```json
{
  "presets": [
    {
      "name": "Artist - album / cover",
      "sorting_pattern": "%path_sort%",
      "header": {
        "pattern": "[%album artist% - ]['['%date%']' ][%album%]",
        "display": "text"
      },
      "group_column": {
        "pattern": "[%album%]",
        "display": "front"
      },
      "subgroups": [
        {
          "pattern": "[Disc %discnumber%]",
          "display": "text"
        }
      ]
    }
  ],
  "active_index": 0
}
```

### 6.4 Column JSON Format

```json
{
  "columns": [
    {"name": "Playing", "pattern": "$if(%isplaying%,>,)", "width": 20, "alignment": "center"},
    {"name": "#", "pattern": "%tracknumber%", "width": 30, "alignment": "right"},
    {"name": "Title", "pattern": "%title%", "width": 200, "alignment": "left", "auto_resize": true},
    {"name": "Artist", "pattern": "%artist%", "width": 150, "alignment": "left", "auto_resize": true},
    {"name": "Duration", "pattern": "%length%", "width": 50, "alignment": "right"},
    {"name": "Rating", "pattern": "%rating%", "width": 60, "alignment": "center", "clickable": true}
  ]
}
```

---

## 7. Implementation Plan

### Phase 1: Foundation (1-2 weeks)

**Goal:** Basic view that displays playlist contents without grouping

**Tasks:**
1. Project setup (Xcode project, SDK linking)
2. Basic service registration (initquit, ui_element_mac)
3. SimPlaylistController (NSViewController)
4. SimPlaylistView (NSView) with basic track list rendering
5. Playlist data loading via playlist_manager
6. Selection handling (click, Cmd+click, Shift+click)
7. Focus handling and keyboard navigation
8. Basic playlist_callback_single implementation

**Deliverables:**
- Component loads in foobar2000
- Displays track list from active playlist
- Selection and focus work
- Responds to playlist changes

### Phase 2: Grouping (1-2 weeks)

**Goal:** Implement grouping system with headers and subgroups

**Tasks:**
1. GroupModel class implementation
2. GroupNode data structure
3. Title formatting wrapper (using SDK titleformat_compiler)
4. Group calculation algorithm
5. Header row rendering
6. Subgroup row rendering
7. Group presets data structure
8. Basic Groups preferences page

**Deliverables:**
- Tracks grouped by configurable pattern
- Headers and subgroups display correctly
- Groups recalculate on playlist changes

### Phase 3: Group Column & Album Art (1-2 weeks)

**Goal:** Album art display in group column

**Tasks:**
1. Group column rendering (spanning rows)
2. AlbumArtCache implementation
3. Async album art loading via album_art_manager
4. Placeholder display for missing art
5. Ctrl+scroll album art resizing
6. Album art memory management (cache eviction)

**Deliverables:**
- Album art displays in group column
- Images load asynchronously
- Resizing works
- Memory usage stays bounded

### Phase 4: Columns System (1-2 weeks)

**Goal:** Full column system with auto-resize and reordering

**Tasks:**
1. ColumnDefinition class
2. Column header bar with drag support
3. Column rendering in track rows
4. Auto-resize logic (album/artist/title priority)
5. Column reordering via drag
6. Column width persistence
7. Columns preferences page

**Deliverables:**
- Multiple columns display
- Columns can be reordered
- Auto-resize works correctly
- Column config persists

### Phase 5: Interactive Features (1-2 weeks)

**Goal:** Full interactivity and playback integration

**Tasks:**
1. Double-click to play
2. Context menu integration
3. Drag & drop reordering within playlist
4. Drag & drop import from Finder
5. Playing indicator column
6. Duration column toggle (elapsed/remaining)
7. Clickable rating column

**Deliverables:**
- All standard playlist interactions work
- Now playing indicated visually
- Rating editing works

### Phase 6: Polish & Optimization (1-2 weeks)

**Goal:** Production-ready quality

**Tasks:**
1. Virtual scrolling for large playlists
2. Performance profiling and optimization
3. Dark mode support
4. Accessibility labels
5. Complete preferences UI
6. Error handling and edge cases
7. Memory leak checking
8. Documentation

**Deliverables:**
- Handles 10k+ track playlists smoothly
- Full dark mode support
- All edge cases handled
- Ready for release

---

## 8. Testing Strategy

### 8.1 Unit Tests

| Component | Test Cases |
|-----------|------------|
| GroupModel | Empty playlist, single track, single group, multiple groups, subgroups, group boundary detection |
| TitleFormatter | Basic fields, conditionals, nested brackets, special characters, invalid patterns |
| AlbumArtCache | Cache hit, cache miss, async load, memory pressure, invalid image data |
| ColumnDefinition | Parse JSON, auto-resize calculation, minimum width |

### 8.2 Integration Tests

| Scenario | Steps | Expected Result |
|----------|-------|-----------------|
| Playlist switch | Switch playlists via sidebar | View rebuilds, scroll resets |
| Track add | Add tracks to playlist | Groups update, new tracks visible |
| Track remove | Remove tracks from playlist | Groups update, gaps closed |
| Metadata change | Edit track metadata | Affected groups recalculate |
| Selection sync | Select in SimPlaylist, check Default UI | Selections match |

### 8.3 Performance Tests

| Metric | Target |
|--------|--------|
| Initial render (1000 tracks) | < 100ms |
| Group recalculation (1000 tracks) | < 50ms |
| Album art load (first visible) | < 200ms |
| Scroll frame rate | 60 FPS |
| Memory usage (1000 tracks, 50 albums) | < 100MB |

### 8.4 Manual Test Checklist

- [ ] Empty playlist display
- [ ] Single track playlist
- [ ] 10,000+ track playlist performance
- [ ] All grouping presets
- [ ] Custom title format patterns
- [ ] Album art loading for various formats (JPEG, PNG, embedded)
- [ ] Dark mode appearance
- [ ] Window resize column behavior
- [ ] Keyboard navigation (arrow keys, Page Up/Down, Home/End)
- [ ] Multi-select operations
- [ ] Context menu all options
- [ ] Drag & drop reorder
- [ ] Drag & drop import
- [ ] Preferences persistence across restart

---

## References

### SDK Documentation
- [playlist_manager Class](http://foosion.foobar2000.org/doxygen/latest/classplaylist__manager.html)
- [Global Callbacks](https://wiki.hydrogenaudio.org/index.php?title=Foobar2000:Development:Global_Callbacks)
- [Official SDK](https://www.foobar2000.org/SDK)

### Original Component
- [SimPlaylist Wiki](https://wiki.hydrogenaudio.org/index.php?title=Foobar2000:Components/SimPlaylist_(foo_simplaylist))

### Knowledge Base
- Local: `../knowledge_base/` (all 8 documents)

---

## Document History

| Date | Version | Changes |
|------|---------|---------|
| 2025-12-22 | 1.0 | Initial comprehensive specification |

---

**Next Steps:** Begin Phase 1 implementation following this specification.
