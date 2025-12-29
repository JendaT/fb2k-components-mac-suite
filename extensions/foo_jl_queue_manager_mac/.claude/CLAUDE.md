# foo_jl_queue_manager - Claude Code Context

**Revision:** 2.0 (Post-Architecture Review)

## Project Overview

foobar2000 macOS component providing a visual Queue Manager - a playlist-like interface for managing the playback queue. This functionality exists in Windows foobar2000 but is missing on macOS.

**Status:** Phase 1 (MVP) complete - basic table view, live updates, status bar, empty state.

## Documentation

- `docs/01_FOUNDATION.md` - Complete design document (v2.0, post-review)
- `docs/02_SDK_NOTES.md` - SDK API discoveries and patterns (v2.0)

## Critical Implementation Notes

### 1. Memory Safety (CRITICAL)
```objc
// WRONG - causes memory corruption
@property (nonatomic, assign) metadb_handle_ptr handle;

// CORRECT - use C++ member variable
@interface QueueItemWrapper : NSObject {
    metadb_handle_ptr _handle;
}
```

### 2. Callback Manager Pattern (HIGH)
Use `QueueCallbackManager` singleton, not direct service factory:
```cpp
class QueueCallbackManager {
    static QueueCallbackManager& instance();
    void registerController(QueueManagerController* ctrl);
    void unregisterController(QueueManagerController* ctrl);
    void onQueueChanged(t_change_origin origin);
};
```

### 3. Reorder Debouncing (HIGH)
Flush-and-rebuild triggers N+1 callbacks. Use debounce flag:
```objc
@property (nonatomic) BOOL isReorderingInProgress;
```

### 4. Stale Reference Validation
Always validate queue items before play/show-in-playlist:
```cpp
bool isQueueItemValid(const t_playback_queue_item& item);
```

## Key SDK APIs

```cpp
// Queue operations (from playlist_manager)
queue_get_count()
queue_get_contents(pfc::list_base_t<t_playback_queue_item>& out)
queue_add_item_playlist(t_size playlist, t_size item)  // Use this normally
queue_add_item(metadb_handle_ptr item)                  // Creates orphan
queue_remove_mask(const bit_array& mask)
queue_flush()

// Callback
class playback_queue_callback : public service_base {
    void on_changed(t_change_origin origin);
};
```

## Component Identity

- **Name:** Queue Manager
- **Subclass:** `ui_element_subclass_utility`
- **Min size:** 150 x 100 pixels

### match_name() Required
```cpp
bool match_name(const char* name) override {
    return strcmp(name, "Queue Manager") == 0 ||
           strcmp(name, "queue_manager") == 0 ||
           strcmp(name, "foo_jl_queue_manager") == 0 ||
           // ... more variations
}
```

## Implementation Phases

1. **Phase 1 (MVP):** Table view, live updates, status bar, empty state, accessibility
2. **Phase 2:** Interaction (delete, context menu, double-click play)
3. **Phase 3:** Internal drag & drop with debouncing
4. **Phase 4:** Column system, external drag research
5. **Phase 5:** Polish, dark mode, performance

**Deferred:** Custom column dialog, undo support

## File Structure

```
src/
  Core/
    ConfigHelper.h           # fb2k::configStore wrapper
    QueueConfig.h            # Configuration constants
    QueueOperations.h/cpp    # SDK queue operations wrapper
  Integration/
    Main.mm                  # UI element registration
    QueueCallbackManager.h/mm  # Singleton callback dispatcher
    QueueCallback.mm         # playback_queue_callback service
  UI/
    QueueManagerController.h/mm  # Main NSViewController
    QueueItemWrapper.h/mm    # Safe wrapper for t_playback_queue_item
Scripts/
  generate_xcode_project.rb  # Xcode project generator
  install.sh                 # Component installer
Resources/
  Info.plist                 # Bundle info
```

## Build Commands

```bash
ruby Scripts/generate_xcode_project.rb
xcodebuild -project foo_jl_queue_manager.xcodeproj -configuration Release
./Scripts/install.sh
```

## Risk Mitigations

| Risk | Mitigation |
|------|------------|
| Drag from playlist unsupported | "Add Selection to Queue" menu item |
| Memory leaks in wrapper | C++ member, not ObjC property |
| Reorder flicker | Debounce callbacks |
| Large queue performance | Virtualization if > 100 items |

## Install Path

```
~/Library/foobar2000-v2/user-components/foo_jl_queue_manager/foo_jl_queue_manager.component
```

## Debug

```bash
pkill -x foobar2000; /Applications/foobar2000.app/Contents/MacOS/foobar2000
```

Shows console::info/error messages in terminal.

## Reference Projects

- `../foo_jl_wave_seekbar_mac/` - Working macOS component patterns
- `../../knowledge_base/08_SETTINGS_AND_UI_PATTERNS.md`
- `../../knowledge_base/04_UI_ELEMENT_IMPLEMENTATION.md`
