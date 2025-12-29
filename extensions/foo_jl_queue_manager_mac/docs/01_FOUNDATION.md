# foo_jl_queue_manager - Foundation Document

**Revision:** 2.0 (Post-Architecture Review)

## 1. Project Overview

### 1.1 Purpose
Create a Queue Manager component for foobar2000 macOS that provides a visual, interactive interface for the playback queue - functionality that exists in Windows foobar2000 but is missing on macOS.

### 1.2 Core Features
- **Visual queue display** - NSTableView-based list showing queued tracks
- **Drag & drop reordering** - Drag items within queue to change playback order
- **Item removal** - Delete key or context menu to remove items
- **Configurable columns** - User-selectable columns (queue #, artist, track, album, etc.)
- **Live updates** - Real-time sync with queue state changes
- **Double-click to play** - Jump to queued item
- **Status bar** - Item count display

### 1.3 Component Identity
- **Name:** Queue Manager
- **Internal name:** `foo_jl_queue_manager`
- **UI Element name:** "Queue Manager" (appears in Layout Editor)
- **Subclass:** `ui_element_subclass_utility` (supplementary utility panel, not a playlist replacement)

### 1.4 Name Matching (for Layout Compatibility)

```cpp
bool match_name(const char* name) override {
    return strcmp(name, "Queue Manager") == 0 ||
           strcmp(name, "queue_manager") == 0 ||
           strcmp(name, "QueueManager") == 0 ||
           strcmp(name, "foo_jl_queue_manager") == 0 ||
           strcmp(name, "jl_queue_manager") == 0 ||
           strcmp(name, "foo_queue_manager") == 0;
}
```

### 1.5 Size Constraints

- **Minimum size:** 150 x 100 pixels
- **Resize behavior:** Columns resize proportionally; horizontal scroll below minimum width

---

## 2. SDK API Analysis

### 2.1 Queue Data Structure

```cpp
// From SDK/playlist.h
struct t_playback_queue_item {
    metadb_handle_ptr m_handle;   // The track (metadb handle)
    t_size m_playlist;            // Source playlist index
    t_size m_item;                // Item index within source playlist

    bool operator==(const t_playback_queue_item& other) const;
    bool operator!=(const t_playback_queue_item& other) const;
};
```

**Key insight:** Queue items reference their source playlist. This means:
- Same track can be queued multiple times from different playlists
- If source playlist is modified, queue references may become stale
- Queue items are not standalone - they're playlist references

### 2.2 Queue Management API

All queue operations go through `playlist_manager`:

```cpp
class playlist_manager : public service_base {
    // Query
    t_size queue_get_count();
    void queue_get_contents(pfc::list_base_t<t_playback_queue_item>& out);
    t_size queue_find_index(const t_playback_queue_item& item);  // Returns ~0 if not found
    bool queue_is_active();  // Helper: queue_get_count() > 0

    // Modify
    void queue_add_item(metadb_handle_ptr item);  // Add orphan (m_playlist = ~0)
    void queue_add_item_playlist(t_size playlist, t_size item);  // Add with playlist reference
    void queue_remove_mask(const bit_array& mask);  // Remove items matching mask
    void queue_flush();  // Helper: queue_remove_mask(bit_array_true())
};
```

**When to use which add method:**
- `queue_add_item_playlist(playlist, item)` - Preserves playlist reference. **Use for normal queue additions.**
- `queue_add_item(handle)` - Creates orphan queue item with `m_playlist = ~0`. Use only for items not in any playlist (e.g., files dropped from Finder).

**Important limitations:**
- No `queue_insert_at()` - can only add to end
- No `queue_move()` - reordering requires remove + re-add
- No `queue_set_contents()` - must manipulate incrementally

### 2.3 Queue Change Notifications - Callback Manager Pattern

**IMPORTANT:** Use the Callback Manager pattern, not simple service factory.

```cpp
// QueueCallbackManager.h
class QueueCallbackManager {
public:
    static QueueCallbackManager& instance();
    void registerController(QueueManagerController* controller);
    void unregisterController(QueueManagerController* controller);
    void onQueueChanged(playback_queue_callback::t_change_origin origin);

private:
    QueueCallbackManager() = default;
    std::mutex m_mutex;
    std::vector<__weak QueueManagerController*> m_controllers;
};

// QueueCallbackManager.mm
QueueCallbackManager& QueueCallbackManager::instance() {
    static QueueCallbackManager instance;
    return instance;
}

void QueueCallbackManager::onQueueChanged(playback_queue_callback::t_change_origin origin) {
    std::lock_guard<std::mutex> lock(m_mutex);
    for (auto weakController : m_controllers) {
        if (QueueManagerController* controller = weakController) {
            if (!controller.isReorderingInProgress) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [controller reloadQueueContents];
                });
            }
        }
    }
}

// QueueCallback.mm - Service factory only
class queue_callback_impl : public playback_queue_callback {
public:
    void on_changed(t_change_origin origin) override {
        QueueCallbackManager::instance().onQueueChanged(origin);
    }
};

FB2K_SERVICE_FACTORY(queue_callback_impl);
```

### 2.4 Stale Queue Reference Validation

When playing a queue item, validate the reference is still valid:

```cpp
bool isQueueItemValid(const t_playback_queue_item& item) {
    auto pm = playlist_manager::get();

    // Check playlist still exists
    if (item.m_playlist >= pm->get_playlist_count()) return false;

    // Check item index is valid
    if (item.m_item >= pm->playlist_get_item_count(item.m_playlist)) return false;

    // Check handle still matches
    metadb_handle_ptr check;
    pm->playlist_get_item_handle(check, item.m_playlist, item.m_item);
    return check == item.m_handle;
}
```

### 2.5 Track Metadata Access

Queue items contain `metadb_handle_ptr` which provides track info:

```cpp
metadb_handle_ptr handle = queueItem.m_handle;

// Get cached info (fast, may be incomplete)
file_info_impl info;
if (handle->get_info_async_locked(info)) {
    const char* artist = info.meta_get("ARTIST", 0);
    const char* title = info.meta_get("TITLE", 0);
    const char* album = info.meta_get("ALBUM", 0);
    double length = info.get_length();  // Duration in seconds
}

// For display, use title formatting
titleformat_object::ptr script;
titleformat_compiler::get()->compile_safe(script, "[%artist% - ]%title%");
pfc::string8 formatted;
handle->format_title(nullptr, formatted, script, nullptr);
```

### 2.6 Playback Control Integration

```cpp
// Check if item is currently playing
playback_control::ptr pc = playback_control::get();
metadb_handle_ptr nowPlaying;
if (pc->get_now_playing(nowPlaying)) {
    if (nowPlaying == queueItem.m_handle) {
        // This queue item is currently playing
    }
}

// Play specific queue item (validate first!)
if (isQueueItemValid(queueItem)) {
    playlist_manager::ptr pm = playlist_manager::get();
    pm->set_active_playlist(queueItem.m_playlist);
    pm->playlist_set_focus_item(queueItem.m_playlist, queueItem.m_item);
    playback_control::get()->play_start(playback_control::track_command_settrack);
}
```

---

## 3. UI Architecture

### 3.1 View Hierarchy

```
QueueManagerController (NSViewController)
└── containerView (NSView)
    ├── scrollView (NSScrollView)
    │   └── tableView (NSTableView)
    │       ├── Column: Queue #
    │       ├── Column: Artist - Title
    │       ├── Column: Duration
    │       └── (user-configurable)
    ├── statusBar (NSTextField) - "3 items in queue"
    └── emptyStateView (NSView) - shown when queue is empty
        ├── iconView (NSImageView) - optional
        ├── titleLabel - "Queue is empty"
        └── subtitleLabel - "Drag tracks here or use context menu"
```

### 3.2 NSTableView Configuration

```objc
@interface QueueTableView : NSTableView <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSMutableArray<QueueItemWrapper*>* queueItems;
@end

@implementation QueueTableView

- (void)setupTable {
    self.allowsMultipleSelection = YES;
    self.allowsColumnReordering = YES;
    self.allowsColumnResizing = YES;
    self.allowsColumnSelection = NO;
    self.usesAlternatingRowBackgroundColors = YES;
    self.gridStyleMask = NSTableViewSolidHorizontalGridLineMask;

    // Drag & drop (internal only for Phase 3)
    [self registerForDraggedTypes:@[kQueueItemPboardType]];
    [self setDraggingSourceOperationMask:NSDragOperationMove forLocal:YES];
}

// Focus handling
- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)becomeFirstResponder {
    [super becomeFirstResponder];
    // Update visual state to show focus if needed
    return YES;
}

@end
```

### 3.3 Column System

**Available columns:**

| Column ID | Header | Default Width | Format/Source |
|-----------|--------|---------------|---------------|
| `queue_index` | # | 30 | Queue position (1-based) |
| `artist_title` | Artist - Title | 250 | `[%artist% - ]%title%` |
| `artist` | Artist | 120 | `%artist%` |
| `title` | Title | 150 | `%title%` |
| `album` | Album | 150 | `%album%` |
| `duration` | Duration | 50 | `%length%` |
| `codec` | Codec | 60 | `%codec%` |
| `bitrate` | Bitrate | 60 | `%bitrate% kbps` |
| `path` | Path | 300 | `%path%` |

**Column persistence (JSON format):**
```cpp
// Using fb2k::configStore with JSON for robustness
static const char* kKeyColumnWidths = "column_widths_json";
// Value: {"queue_index":30,"artist_title":250,"duration":50}

static const char* kKeyVisibleColumns = "visible_columns";
// Value: "queue_index,artist_title,duration"

static const char* kKeyColumnOrder = "column_order";
// Value: "queue_index,artist_title,duration"
```

### 3.4 Queue Item Wrapper (CRITICAL: Memory Safety)

**IMPORTANT:** C++ smart pointers cannot be stored as Objective-C properties with `assign`. Use C++ member variables.

```objc
// QueueItemWrapper.h
@interface QueueItemWrapper : NSObject {
    metadb_handle_ptr _handle;  // C++ member, NOT a property
}

@property (nonatomic, readonly) size_t queueIndex;
@property (nonatomic, readonly) size_t sourcePlaylist;
@property (nonatomic, readonly) size_t sourceItem;

// Cached display values (for performance)
@property (nonatomic, strong) NSString* cachedArtist;
@property (nonatomic, strong) NSString* cachedTitle;
@property (nonatomic, strong) NSString* cachedAlbum;
@property (nonatomic, strong) NSString* cachedDuration;

- (instancetype)initWithQueueItem:(const t_playback_queue_item&)item queueIndex:(size_t)index;
- (metadb_handle_ptr)handle;
- (void)refreshCachedValues;
- (NSString*)formattedValueForColumn:(NSString*)columnId;

@end

// QueueItemWrapper.mm
@implementation QueueItemWrapper

- (instancetype)initWithQueueItem:(const t_playback_queue_item&)item queueIndex:(size_t)index {
    if (self = [super init]) {
        _handle = item.m_handle;  // Copy increments refcount
        _queueIndex = index;
        _sourcePlaylist = item.m_playlist;
        _sourceItem = item.m_item;
        [self refreshCachedValues];
    }
    return self;
}

- (metadb_handle_ptr)handle {
    return _handle;
}

- (void)dealloc {
    _handle.release();  // Explicitly release if needed
}

@end
```

### 3.5 Empty State Design

```objc
- (void)setupEmptyStateView {
    _emptyStateView = [[NSView alloc] initWithFrame:self.view.bounds];
    _emptyStateView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSTextField* titleLabel = [NSTextField labelWithString:@"Queue is empty"];
    titleLabel.font = [NSFont systemFontOfSize:16 weight:NSFontWeightMedium];
    titleLabel.textColor = [NSColor secondaryLabelColor];
    titleLabel.alignment = NSTextAlignmentCenter;

    NSTextField* subtitleLabel = [NSTextField labelWithString:@"Drag tracks here or use context menu"];
    subtitleLabel.font = [NSFont systemFontOfSize:12];
    subtitleLabel.textColor = [NSColor tertiaryLabelColor];
    subtitleLabel.alignment = NSTextAlignmentCenter;

    // Stack vertically, center in view
    NSStackView* stack = [NSStackView stackViewWithViews:@[titleLabel, subtitleLabel]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.spacing = 4;
    stack.alignment = NSLayoutAttributeCenterX;

    [_emptyStateView addSubview:stack];
    // Center stack in emptyStateView with constraints...

    _emptyStateView.hidden = YES;  // Initially hidden
    [self.view addSubview:_emptyStateView];
}

- (void)updateEmptyState {
    BOOL isEmpty = _queueItems.count == 0;
    _emptyStateView.hidden = !isEmpty;
    _scrollView.hidden = isEmpty;
}
```

### 3.6 Accessibility

```objc
// In QueueTableView
- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilityListRole;
}

- (NSString*)accessibilityLabel {
    NSInteger count = self.queueItems.count;
    if (count == 0) {
        return @"Playback queue, empty";
    } else if (count == 1) {
        return @"Playback queue with 1 item";
    } else {
        return [NSString stringWithFormat:@"Playback queue with %ld items", (long)count];
    }
}

- (BOOL)isAccessibilityElement {
    return YES;
}
```

---

## 4. Drag & Drop Implementation

### 4.1 Drag Source (Reordering Within Queue)

```objc
// NSTableViewDataSource
- (BOOL)tableView:(NSTableView*)tv writeRowsWithIndexes:(NSIndexSet*)rowIndexes
     toPasteboard:(NSPasteboard*)pboard {

    NSData* data = [NSKeyedArchiver archivedDataWithRootObject:rowIndexes
                                         requiringSecureCoding:YES error:nil];
    [pboard declareTypes:@[kQueueItemPboardType] owner:self];
    [pboard setData:data forType:kQueueItemPboardType];
    return YES;
}
```

### 4.2 Drop Target (Reorder)

```objc
- (NSDragOperation)tableView:(NSTableView*)tv
                validateDrop:(id<NSDraggingInfo>)info
                 proposedRow:(NSInteger)row
       proposedDropOperation:(NSTableViewDropOperation)op {

    if (op == NSTableViewDropOn) {
        [tv setDropRow:row dropOperation:NSTableViewDropAbove];
    }

    NSPasteboard* pboard = [info draggingPasteboard];
    if ([pboard availableTypeFromArray:@[kQueueItemPboardType]]) {
        return NSDragOperationMove;
    }
    return NSDragOperationNone;
}

- (BOOL)tableView:(NSTableView*)tv acceptDrop:(id<NSDraggingInfo>)info
              row:(NSInteger)row dropOperation:(NSTableViewDropOperation)op {

    NSPasteboard* pboard = [info draggingPasteboard];
    if ([pboard availableTypeFromArray:@[kQueueItemPboardType]]) {
        return [self handleInternalReorderToRow:row fromPasteboard:pboard];
    }
    return NO;
}
```

### 4.3 Queue Reorder Algorithm with Debouncing

**CRITICAL:** The flush-and-rebuild approach triggers multiple callbacks. Use debouncing.

```objc
// In QueueManagerController.h
@property (nonatomic) BOOL isReorderingInProgress;

// In QueueManagerController.mm
- (BOOL)handleInternalReorderToRow:(NSInteger)targetRow
                    fromPasteboard:(NSPasteboard*)pboard {

    NSData* data = [pboard dataForType:kQueueItemPboardType];
    NSIndexSet* draggedIndices = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSIndexSet class]
                                                                   fromData:data error:nil];

    // 1. Set debounce flag BEFORE any modifications
    self.isReorderingInProgress = YES;

    // 2. Capture current queue state
    pfc::list_t<t_playback_queue_item> currentQueue;
    playlist_manager::get()->queue_get_contents(currentQueue);

    // 3. Build new order
    pfc::list_t<t_playback_queue_item> newQueue;
    NSMutableIndexSet* remaining = [NSMutableIndexSet indexSetWithIndexesInRange:
                                    NSMakeRange(0, currentQueue.get_count())];
    [remaining removeIndexes:draggedIndices];

    // Adjust target for items being moved
    __block NSInteger adjustedTarget = targetRow;
    [draggedIndices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL* stop) {
        if ((NSInteger)idx < targetRow) adjustedTarget--;
    }];

    // Add items before target
    __block size_t insertIdx = 0;
    [remaining enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL* stop) {
        if ((NSInteger)insertIdx < adjustedTarget) {
            newQueue.add_item(currentQueue[idx]);
            insertIdx++;
        }
    }];

    // Add dragged items at target position
    [draggedIndices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL* stop) {
        newQueue.add_item(currentQueue[idx]);
    }];

    // Add remaining items after target
    [remaining enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL* stop) {
        if ((NSInteger)insertIdx >= adjustedTarget) {
            newQueue.add_item(currentQueue[idx]);
        }
        insertIdx++;
    }];

    // 4. Apply: flush and re-add
    auto pm = playlist_manager::get();
    pm->queue_flush();
    for (size_t i = 0; i < newQueue.get_count(); i++) {
        const auto& item = newQueue[i];
        pm->queue_add_item_playlist(item.m_playlist, item.m_item);
    }

    // 5. Clear debounce flag and reload AFTER all modifications complete
    dispatch_async(dispatch_get_main_queue(), ^{
        self.isReorderingInProgress = NO;
        [self reloadQueueContents];
    });

    return YES;
}
```

---

## 5. Column Configuration UI

### 5.1 Column Picker (Right-Click Header)

```objc
- (NSMenu*)tableView:(NSTableView*)tv menuForColumns:(NSIndexSet*)columns {
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Columns"];

    for (ColumnDefinition* col in self.allAvailableColumns) {
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:col.displayName
                                                      action:@selector(toggleColumn:)
                                               keyEquivalent:@""];
        item.representedObject = col;
        item.state = [self isColumnVisible:col.identifier] ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:item];
    }

    return menu;
}
```

---

## 6. Context Menu

### 6.1 Context Menu Caller GUID

```cpp
// In ContextMenuDefs.h
// Unique GUID for queue context menu caller
// {A1B2C3D4-E5F6-7890-ABCD-EF1234567890} - Generate actual unique GUID
static const GUID caller_queue_selection = {
    0xa1b2c3d4, 0xe5f6, 0x7890, { 0xab, 0xcd, 0xef, 0x12, 0x34, 0x56, 0x78, 0x90 }
};
```

### 6.2 Queue Item Context Menu

```objc
- (NSMenu*)menuForSelectedItems {
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Queue"];

    [menu addItemWithTitle:@"Play" action:@selector(playSelected:) keyEquivalent:@""];

    [menu addItem:[NSMenuItem separatorItem]];

    [menu addItemWithTitle:@"Remove from Queue"
                    action:@selector(removeSelected:)
             keyEquivalent:@""];

    [menu addItemWithTitle:@"Clear Queue"
                    action:@selector(clearQueue:)
             keyEquivalent:@""];

    [menu addItem:[NSMenuItem separatorItem]];

    [menu addItemWithTitle:@"Show in Playlist"
                    action:@selector(showInPlaylist:)
             keyEquivalent:@""];

    return menu;
}
```

### 6.3 Keyboard Shortcuts

```objc
- (void)keyDown:(NSEvent*)event {
    unichar key = [[event charactersIgnoringModifiers] characterAtIndex:0];

    if (key == NSDeleteCharacter || key == NSBackspaceCharacter) {
        [self removeSelectedItems:nil];
    } else if (key == NSCarriageReturnCharacter) {
        [self playSelectedItem:nil];
    } else {
        [super keyDown:event];
    }
}
```

| Key | Action |
|-----|--------|
| Delete/Backspace | Remove selected from queue |
| Cmd+A | Select all |
| Enter | Play selected item |
| Escape | Deselect all |

---

## 7. Settings Persistence

### 7.1 Configuration Keys

```cpp
namespace queue_config {
    static const char* kConfigPrefix = "foo_jl_queue_manager.";

    // Column settings (use JSON for robustness)
    static const char* kKeyVisibleColumns = "visible_columns";
    static const char* kKeyColumnWidthsJson = "column_widths_json";
    static const char* kKeyColumnOrder = "column_order";

    // UI settings
    static const char* kKeyShowStatusBar = "show_status_bar";
    static const char* kKeyAlternatingRows = "alternating_rows";
    static const char* kKeyFontSize = "font_size";

    // Defaults
    static const char* kDefaultVisibleColumns = "queue_index,artist_title,duration";
    static const char* kDefaultColumnWidths = R"({"queue_index":30,"artist_title":250,"duration":50})";
}
```

### 7.2 ConfigHelper Pattern

```cpp
// ConfigHelper.h
namespace queue_config {

inline pfc::string8 getConfigString(const char* key, const char* defaultValue) {
    try {
        auto store = fb2k::configStore::get();
        if (store) {
            pfc::string8 fullKey;
            fullKey << kConfigPrefix << key;
            return store->getConfigString(fullKey.c_str(), defaultValue);
        }
    } catch (...) {}
    return pfc::string8(defaultValue);
}

inline void setConfigString(const char* key, const char* value) {
    try {
        auto store = fb2k::configStore::get();
        if (store) {
            pfc::string8 fullKey;
            fullKey << kConfigPrefix << key;
            store->setConfigString(fullKey.c_str(), value);
        }
    } catch (...) {}
}

inline int64_t getConfigInt(const char* key, int64_t defaultValue) {
    try {
        auto store = fb2k::configStore::get();
        if (store) {
            pfc::string8 fullKey;
            fullKey << kConfigPrefix << key;
            return store->getConfigInt(fullKey.c_str(), defaultValue);
        }
    } catch (...) {}
    return defaultValue;
}

inline void setConfigInt(const char* key, int64_t value) {
    try {
        auto store = fb2k::configStore::get();
        if (store) {
            pfc::string8 fullKey;
            fullKey << kConfigPrefix << key;
            store->setConfigInt(fullKey.c_str(), value);
        }
    } catch (...) {}
}

} // namespace queue_config
```

---

## 8. Integration Layer

### 8.1 initquit Registration

```cpp
// Main.mm
class queue_manager_init : public initquit {
public:
    void on_init() override {
        QueueCallbackManager::instance();  // Ensure singleton exists
        console::info("[Queue Manager] Initialized");
    }

    void on_quit() override {
        // Cleanup if needed
    }
};

FB2K_SERVICE_FACTORY(queue_manager_init);
```

### 8.2 UI Element Registration

```cpp
// UIElement.mm
class queue_manager_ui_element : public ui_element {
public:
    GUID get_guid() override { return guid_queue_manager_element; }
    GUID get_subclass() override { return ui_element_subclass_utility; }

    void get_name(pfc::string_base& out) override {
        out = "Queue Manager";
    }

    bool get_description(pfc::string_base& out) override {
        out = "Visual playback queue manager with drag & drop reordering";
        return true;
    }

    ui_element_instance_ptr instantiate(fb2k::hwnd_t parent,
                                         ui_element_config::ptr cfg,
                                         ui_element_instance_callback_ptr callback) override {
        return new queue_manager_ui_element_instance(parent, cfg, callback);
    }

    // ... other methods
};

FB2K_SERVICE_FACTORY(queue_manager_ui_element);
```

---

## 9. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     foo_jl_queue_manager                        │
├─────────────────────────────────────────────────────────────────┤
│  Integration Layer                                              │
│  ├── Main.mm                  - Component entry, initquit       │
│  ├── UIElement.mm             - ui_element service              │
│  ├── QueueCallbackManager.h   - Singleton callback dispatcher   │
│  ├── QueueCallbackManager.mm                                    │
│  └── QueueCallback.mm         - playback_queue_callback factory │
├─────────────────────────────────────────────────────────────────┤
│  Core Layer                                                     │
│  ├── ConfigHelper.h           - fb2k::configStore wrapper       │
│  ├── QueueOperations.h/cpp    - Queue SDK operations wrapper    │
│  ├── QueueItemData.h          - Plain C++ data struct           │
│  ├── ColumnDefinition.h       - Column metadata                 │
│  └── TitleFormatter.h         - Title format compilation cache  │
├─────────────────────────────────────────────────────────────────┤
│  UI Layer                                                       │
│  ├── QueueManagerController.h/mm  - Main view controller        │
│  ├── QueueTableView.h/mm          - Custom table view           │
│  ├── QueueItemWrapper.h/mm        - ObjC wrapper (safe handle)  │
│  └── ColumnPickerMenu.mm          - Column configuration        │
├─────────────────────────────────────────────────────────────────┤
│  foobar2000 SDK                                                 │
│  └── playlist_manager, playback_queue_callback, metadb, etc.    │
└─────────────────────────────────────────────────────────────────┘
```

---

## 10. Implementation Plan

### Phase 1: Foundation (MVP)
1. Project setup (Xcode project, SDK integration)
2. initquit registration
3. Basic UI element registration with match_name()
4. Simple table view with hardcoded columns (queue #, artist-title, duration)
5. Queue content display (read-only)
6. QueueCallbackManager with debounce support
7. Live updates via playback_queue_callback
8. Status bar with item count
9. Empty state view
10. Accessibility basics

**Testing Phase 1:**
- Manual test: Add 100+ items, verify performance
- Verify component loads in layout editor
- Verify live updates work

### Phase 2: Interaction
1. Item selection and removal (Delete key)
2. Context menu (remove, clear, show in playlist)
3. Double-click to play (with validation)
4. Keyboard navigation
5. Focus handling

### Phase 3: Drag & Drop
1. Internal reordering (drag within queue) with debouncing
2. Visual feedback during drag

**Testing Phase 3:**
- Manual test: Reorder during playback, verify no crashes
- Verify no flicker during reorder

### Phase 4: Column System + External Drag
1. Multiple column support
2. Column visibility toggle (header right-click)
3. Column width persistence (JSON format)
4. Column reordering
5. Research pasteboard format from playlists
6. Implement external drag if supported (or "Add Selection to Queue" fallback)

### Phase 5: Polish
1. Preferences page (if needed)
2. Dark mode verification
3. Performance optimization for large queues
4. Edge case handling

**Deferred/Dropped:**
- Custom column dialog - Defer indefinitely (MVP doesn't need it)
- Undo support - Dropped (complexity not justified)

---

## 11. Risk Analysis

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Drag from playlist not supported by SDK | HIGH | MEDIUM | Use "Add Selection to Queue" menu item instead |
| Large queue causes performance issues | LOW | MEDIUM | Lazy loading, virtualization if > 100 items |
| Reorder flicker | HIGH | LOW | Debounce callbacks during reorder |
| Memory leaks in wrapper | HIGH | HIGH | Use C++ member for handle, not ObjC property |

---

## 12. File Structure

```
foo_jl_queue_manager/
├── docs/
│   ├── 01_FOUNDATION.md          (this document)
│   ├── 02_SDK_NOTES.md           (SDK discoveries)
│   └── 03_IMPLEMENTATION_LOG.md  (progress notes)
├── src/
│   ├── Core/
│   │   ├── ConfigHelper.h
│   │   ├── QueueOperations.h
│   │   ├── QueueOperations.cpp
│   │   ├── QueueItemData.h
│   │   ├── ColumnDefinition.h
│   │   └── TitleFormatter.h
│   ├── Integration/
│   │   ├── Main.mm
│   │   ├── UIElement.mm
│   │   ├── QueueCallbackManager.h
│   │   ├── QueueCallbackManager.mm
│   │   └── QueueCallback.mm
│   └── UI/
│       ├── QueueManagerController.h
│       ├── QueueManagerController.mm
│       ├── QueueTableView.h
│       ├── QueueTableView.mm
│       ├── QueueItemWrapper.h
│       ├── QueueItemWrapper.mm
│       └── ColumnPickerMenu.mm
├── Scripts/
│   ├── generate_xcode_project.rb
│   └── install.sh
├── .claude/
│   └── CLAUDE.md
├── LICENSE
└── README.md
```

---

## 13. Open Questions (Remaining)

### 13.1 Pasteboard Format for Playlist Items
- Does foobar2000 macOS expose a standard pasteboard type when dragging from playlists?
- Need to investigate at runtime during Phase 4
- Fallback: "Add Selection to Queue" context menu item

### 13.2 Playing Item Indication
- Should we highlight the currently playing item if it's in queue?
- Need playback_callback to track this
- Consider for Phase 5

---

## 14. References

- foobar2000 SDK: `SDK-2025-03-07/foobar2000/SDK/playlist.h`
- foo_wave_seekbar_mac: Implementation patterns for macOS components
- Knowledge base: `knowledge_base/08_SETTINGS_AND_UI_PATTERNS.md`
- Knowledge base: `knowledge_base/04_UI_ELEMENT_IMPLEMENTATION.md`
- Apple docs: NSTableView, NSDraggingSource, NSDraggingDestination, NSAccessibility
