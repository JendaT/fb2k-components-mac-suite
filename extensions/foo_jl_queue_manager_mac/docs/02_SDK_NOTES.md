# SDK Notes for Queue Manager

**Revision:** 2.0 (Post-Architecture Review)

---

## 0. Critical Implementation Notes

### 0.1 Memory Safety: C++ Smart Pointers in Objective-C

**CRITICAL:** Never use `@property (assign)` for C++ smart pointers like `metadb_handle_ptr`.

```objc
// WRONG - Will cause memory corruption
@property (nonatomic, assign) metadb_handle_ptr handle;

// CORRECT - Use C++ instance variable
@interface QueueItemWrapper : NSObject {
    metadb_handle_ptr _handle;  // C++ member
}
- (metadb_handle_ptr)handle;
@end
```

### 0.2 Callback Manager Pattern

Always use a singleton Callback Manager instead of direct service factory callbacks:

```cpp
// QueueCallbackManager dispatches to all registered controllers
// This handles multiple instances and proper lifecycle management
class QueueCallbackManager {
    static QueueCallbackManager& instance();
    void registerController(QueueManagerController* ctrl);
    void unregisterController(QueueManagerController* ctrl);
    void onQueueChanged(t_change_origin origin);
};
```

### 0.3 Reorder Debouncing

The flush-and-rebuild reorder pattern triggers N+1 callbacks (1 flush + N adds). Always debounce:

```objc
@property (nonatomic) BOOL isReorderingInProgress;

// In callback manager - skip if reordering
if (!controller.isReorderingInProgress) {
    [controller reloadQueueContents];
}
```

---

## 1. Playlist Selection API

The SDK provides comprehensive selection handling that we can reference for our queue component:

```cpp
// From playlist_manager
void playlist_get_selection_mask(t_size p_playlist, bit_array_var& out);
void playlist_get_selected_items(t_size p_playlist, pfc::list_base_t<metadb_handle_ptr>& out);
void playlist_set_selection(t_size p_playlist, const bit_array& affected, const bit_array& status);
void playlist_clear_selection(t_size p_playlist);
void playlist_remove_selection(t_size p_playlist, bool p_crop = false);
bool playlist_move_selection(t_size p_playlist, int p_delta);
t_size playlist_get_selection_count(t_size p_playlist, t_size p_max);
```

**Key pattern:** Selection is stored as a bit_array mask, not as a list of indices.

## 2. Drag & Drop: No Standard Pasteboard Type

**Finding:** The SDK does not define a standard NSPasteboard type for track handles on macOS.

On Windows, there's IDataObject/OLE integration, but for macOS:
- No `NSPasteboardType` constant for foobar2000 tracks
- No helper functions for macOS drag/drop

**Implications:**
- Internal queue reordering: We define our own pasteboard type
- External drag FROM playlists: Unknown if Default UI exposes a pasteboard type
- External drag TO queue: We may need to accept file URLs as fallback

**Investigation needed:**
```objc
// At runtime, check what Default UI puts on pasteboard during playlist drag
- (void)inspectPasteboard:(NSPasteboard*)pb {
    NSLog(@"Available types: %@", [pb types]);
    for (NSString* type in [pb types]) {
        NSLog(@"Type: %@ = %@", type, [pb dataForType:type]);
    }
}
```

## 3. ui_edit_context - Selection Interface

The SDK provides `ui_edit_context` as an abstract interface for selection-based editing:

```cpp
class ui_edit_context : public service_base {
    // Selection
    virtual t_size get_item_count() = 0;
    virtual bool is_item_selected(t_size index) = 0;
    virtual void get_selection_mask(pfc::bit_array_var& out);
    void get_selected_items(metadb_handle_list_ref out);
    t_size get_selection_count(t_size max);

    // Modification
    virtual void update_selection(const pfc::bit_array& affected, const pfc::bit_array& status) = 0;
    void select_all();
    void select_none();

    // Item access
    virtual void get_items(metadb_handle_list_ref out, pfc::bit_array const& mask) = 0;
    void get_all_items(metadb_handle_list_ref out);

    // Removal
    virtual void remove_items(pfc::bit_array const& mask) = 0;
    void remove_selection();
    void crop_selection();
    void clear();
};
```

**Consideration:** Should QueueManager implement `ui_edit_context`? This would allow:
- Standard Edit menu integration (Select All, etc.)
- Keyboard shortcut framework
- Context menu generation

## 4. Contextmenu Caller GUIDs

For context menu generation, the SDK defines standard "caller" contexts:

```cpp
static const GUID caller_active_playlist_selection;  // Selected items in active playlist
static const GUID caller_active_playlist;            // All items in active playlist
static const GUID caller_now_playing;                // Currently playing track
static const GUID caller_media_library_viewer;       // Library selection
static const GUID caller_undefined;                  // Generic/unknown
```

**For Queue Manager:** We should define our own caller GUID or use `caller_undefined`.

## 5. Title Formatting Compilation

For efficient column display, compile title format scripts once:

```cpp
class TitleFormatCache {
    std::map<std::string, titleformat_object::ptr> cache;

public:
    titleformat_object::ptr get(const char* pattern) {
        auto it = cache.find(pattern);
        if (it != cache.end()) return it->second;

        titleformat_object::ptr obj;
        titleformat_compiler::get()->compile_safe(obj, pattern);
        cache[pattern] = obj;
        return obj;
    }
};

// Usage
auto script = cache.get("[%artist% - ]%title%");
pfc::string8 result;
handle->format_title(nullptr, result, script, nullptr);
```

## 6. Thread Safety for Queue Operations

All `playlist_manager` operations (including queue) must be called from main thread:

```cpp
// Wrong - called from background thread
dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    playlist_manager::get()->queue_add_item(handle);  // CRASH or undefined behavior
});

// Correct - use fb2k::inMainThread
fb2k::inMainThread([=] {
    playlist_manager::get()->queue_add_item(handle);
});
```

For Objective-C:
```objc
dispatch_async(dispatch_get_main_queue(), ^{
    playlist_manager::get()->queue_add_item(handle);
});
```

## 7. Queue Change Notification Timing

`playback_queue_callback::on_changed()` is called:
- **After** the queue modification is complete
- On the **main thread**
- With origin indicating what happened

```cpp
void on_changed(t_change_origin origin) override {
    // Safe to query queue here
    auto pm = playlist_manager::get();
    size_t count = pm->queue_get_count();  // Reflects new state

    // Safe to update UI
    dispatch_async(dispatch_get_main_queue(), ^{
        [controller reloadData];
    });
}
```

## 8. metadb_handle Lifetime

Queue items contain `metadb_handle_ptr` which is a smart pointer:

```cpp
struct t_playback_queue_item {
    metadb_handle_ptr m_handle;  // Reference-counted, safe to copy
    t_size m_playlist;
    t_size m_item;
};
```

**Important:** The handle remains valid even if:
- The source playlist is deleted
- The item is removed from source playlist
- The file is moved/renamed (handle references the original path)

To check if handle is still valid:
```cpp
if (handle->is_info_loaded()) {
    // File exists and has been scanned
}
```

## 9. Playlist Lock Considerations

Playlists can be locked, preventing modifications. Queue references playlist items:

```cpp
// Check if source playlist allows removal
bool canRemoveFromPlaylist =
    (pm->playlist_lock_get_filter_mask(queueItem.m_playlist) &
     playlist_lock::filter_remove) == 0;
```

**For Queue Manager:** We modify queue, not playlist. Queue itself is never locked.

## 10. Double-Click to Play Implementation

To play a queued item on double-click:

```cpp
- (void)playQueueItem:(const t_playback_queue_item&)item {
    auto pm = playlist_manager::get();
    auto pc = playback_control::get();

    // Option 1: Play from source playlist position
    pm->set_active_playlist(item.m_playlist);
    pm->playlist_set_focus_item(item.m_playlist, item.m_item);
    pc->play_start(playback_control::track_command_settrack);

    // Option 2: Just start playback (queue will be consumed)
    pc->play_start();
}
```

**Note:** After playing a queued item, it's removed from queue (consumed by `changed_playback_advance`).

## 11. Efficient Queue Refresh

When queue changes, avoid full reload if possible:

```cpp
void on_changed(t_change_origin origin) override {
    switch (origin) {
        case changed_user_added:
            // Items added at end - can append
            break;
        case changed_user_removed:
            // Items removed - need mask to know which
            // Unfortunately SDK doesn't provide the mask
            break;
        case changed_playback_advance:
            // First item removed - just remove row 0
            break;
    }
    // In practice, full reload is simplest and queue is small
}
```

## 12. Empty State Handling

When queue is empty, show placeholder:

```objc
- (NSInteger)numberOfRowsInTableView:(NSTableView*)tv {
    if (_queueItems.count == 0) {
        [self showEmptyPlaceholder];
        return 0;
    }
    [self hideEmptyPlaceholder];
    return _queueItems.count;
}

- (void)showEmptyPlaceholder {
    // Show "Queue is empty" label or instructional text
}
```

## 13. Keyboard Handling

For keyboard shortcuts without global registration:

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

- (BOOL)acceptsFirstResponder {
    return YES;
}
```

## 14. Column Width Auto-Sizing

For columns that should fit content:

```objc
- (void)autoSizeColumn:(NSTableColumn*)column {
    CGFloat maxWidth = 0;
    for (NSInteger row = 0; row < self.numberOfRows; row++) {
        NSCell* cell = [self preparedCellAtColumn:[self columnWithIdentifier:column.identifier]
                                             row:row];
        CGFloat cellWidth = [cell cellSize].width;
        maxWidth = MAX(maxWidth, cellWidth);
    }
    column.width = MIN(maxWidth + 10, 300);  // Cap at 300
}
```

## 15. Stale Queue Reference Handling

Queue items reference their source playlist. When the playlist is modified, references can become stale.

### Validation Before Play

```cpp
bool isQueueItemValid(const t_playback_queue_item& item) {
    auto pm = playlist_manager::get();

    // Check playlist exists
    if (item.m_playlist >= pm->get_playlist_count()) return false;

    // Check item index valid
    if (item.m_item >= pm->playlist_get_item_count(item.m_playlist)) return false;

    // Check handle matches
    metadb_handle_ptr check;
    pm->playlist_get_item_handle(check, item.m_playlist, item.m_item);
    return check == item.m_handle;
}
```

### What Happens When References Go Stale

- **Playlist deleted:** `m_playlist` becomes invalid index
- **Item removed:** `m_item` may point to wrong track or be out of bounds
- **metadb_handle_ptr remains valid:** It's a database reference, not a playlist reference

### Recommendation

Always validate before:
- Playing a queue item
- Showing "Show in Playlist" action
- Any operation that uses `m_playlist` and `m_item`

---

## 16. queue_add_item vs queue_add_item_playlist

### queue_add_item_playlist(playlist, item)
- Preserves full playlist reference
- `m_playlist` and `m_item` are set correctly
- **Use for:** Normal queue additions from playlists

### queue_add_item(handle)
- Creates "orphan" queue item
- `m_playlist = ~0` (SIZE_MAX)
- `m_item = ~0`
- **Use for:** Items not in any playlist (e.g., files dropped from Finder)

### Detecting Orphan Items

```cpp
bool isOrphanQueueItem(const t_playback_queue_item& item) {
    return item.m_playlist == ~0;
}
```

---

## 17. configStore String API

For storing column configuration:

```cpp
// From fb2k::configStore
pfc::string8 getConfigString(const char* key, const char* def);
void setConfigString(const char* key, const char* value);

// Usage for column list
void saveVisibleColumns(const std::vector<std::string>& columns) {
    pfc::string8 joined;
    for (size_t i = 0; i < columns.size(); i++) {
        if (i > 0) joined << ",";
        joined << columns[i].c_str();
    }
    setConfigString("visible_columns", joined.c_str());
}

std::vector<std::string> loadVisibleColumns() {
    pfc::string8 stored = getConfigString("visible_columns", "queue_index,artist_title,duration");
    std::vector<std::string> result;
    // Split by comma...
    return result;
}
```
