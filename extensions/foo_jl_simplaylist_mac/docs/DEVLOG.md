# foo_simplaylist_mac Development Log

## 2024-12-22: Phase 1 Implementation Complete

### Initial Implementation
Created core files for Phase 1 (flat list view):
- `src/fb2k_sdk.h` - SDK include wrapper
- `src/Prefix.pch` - Precompiled header
- `src/Core/GroupNode.h/.mm` - Node model for tracks/groups
- `src/Core/ColumnDefinition.h/.mm` - Column configuration
- `src/Core/TitleFormatHelper.h/.cpp` - Title formatting cache
- `src/Core/ConfigHelper.h` - Configuration persistence
- `src/UI/SimPlaylistView.h/.mm` - Custom NSView with virtual scrolling
- `src/UI/SimPlaylistController.h/.mm` - View controller
- `src/Integration/PlaylistCallbacks.h/.mm` - SDK callback handling
- `src/Integration/Main.mm` - Component registration

### Build Scripts
Created standard build script set matching foo_wave_seekbar_mac:
- `Scripts/generate_xcode_project.rb` - Pure Ruby pbxproj generator
- `Scripts/build.sh` - Build with options
- `Scripts/install.sh` - Install to foobar2000
- `Scripts/clean.sh` - Clean build artifacts
- `Scripts/test_install.sh` - One-command test workflow

### Bug: Segmentation Fault on Component Load

**Symptom**: foobar2000 crashed with segfault immediately after "Pre component load" message.

**Diagnosis**:
1. Temporarily moved `foo_simplaylist` out of user-components
2. foobar2000 loaded successfully without it
3. Confirmed crash was caused by our component

**Root Cause**: Static initialization of `playlist_callback_single_impl_base`

The original code had:
```cpp
static simplaylist_playlist_callback g_playlist_callback;
```

This creates a global static object whose constructor runs during dylib load, BEFORE the foobar2000 SDK is initialized. The `playlist_callback_single_impl_base` constructor tries to register with the playlist manager, which doesn't exist yet.

**Fix**: Defer callback creation to `initquit::on_init()`:

```cpp
// Pointer - created in on_init, destroyed in on_quit
static simplaylist_playlist_callback* g_playlist_callback = nullptr;

void SimPlaylistCallbackManager::initCallbacks() {
    if (!g_playlist_callback) {
        g_playlist_callback = new simplaylist_playlist_callback();
    }
}

void SimPlaylistCallbackManager::shutdownCallbacks() {
    delete g_playlist_callback;
    g_playlist_callback = nullptr;
}
```

Then in Main.mm:
```cpp
void on_init() override {
    SimPlaylistCallbackManager::instance().initCallbacks();
}

void on_quit() override {
    SimPlaylistCallbackManager::instance().shutdownCallbacks();
}
```

**Key Lesson**: Never create SDK-dependent objects as static globals. Use:
1. `FB2K_SERVICE_FACTORY` for services (handles timing correctly)
2. Pointer + `initquit::on_init()` for other objects that need SDK access

### Other Compile Fixes Applied

1. **service_ptr_t boolean check**: Use `.is_valid()` not implicit conversion
   ```cpp
   // Wrong: if (store)
   // Right: if (store.is_valid())
   ```

2. **ui_element_mac interface**: macOS uses different API than Windows
   - Methods: `instantiate()`, `match_name()`, `get_name()`, `get_guid()`
   - NOT: `get_view()`, `set_configuration()`

3. **Block capture of bit_array_bittable**: Collect to NSArray first
   ```objc
   // Blocks capture by value, making bit_array_bittable const
   NSMutableArray<NSNumber *> *indices = [NSMutableArray array];
   [view.selectedIndices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
       [indices addObject:@(idx)];
   }];
   for (NSNumber *num in indices) {
       mask.set([num unsignedLongValue], true);
   }
   ```

### Status
- Component builds successfully
- Component loads without crash (4 services registered)
- Ready for UI testing

---

## 2024-12-22: Phase 2 Implementation - Grouping

### Phase 1 Fixes
Before implementing Phase 2, fixed issues from Phase 1 testing:

1. **Column loading from ConfigHelper**: Modified `ColumnDefinition.mm` to parse
   columns from `getDefaultColumnsJSON()` instead of hardcoded values.

2. **Font sizes**: Updated from 11pt to 13pt for tracks (standard list size),
   13pt bold for headers, 12pt medium for subgroups.

3. **Row heights**: Increased from 20px to 22px to accommodate larger font.

4. **Group column width**: Set to 0 until Phase 3 (album art) is implemented.

### New Files
- `src/Core/GroupPreset.h/.mm` - Group preset model with JSON parsing

### Grouping Implementation
Updated `SimPlaylistController::rebuildFromPlaylist` to:
1. Load active group preset from `GroupPreset::defaultPresets`
2. Compile header pattern and subgroup patterns via TitleFormatHelper
3. Create header nodes when header value changes between tracks
4. Create subgroup nodes when subgroup value changes
5. Apply proper indent levels (0 for flat, 1 for grouped, 2 for subgrouped)
6. Map row indices to playlist indices for selection/focus sync

### Group Preset Structure (from ConfigHelper JSON)
```json
{
  "presets": [{
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
    "subgroups": [{
      "pattern": "[Disc %discnumber%]",
      "display": "text"
    }]
  }]
}
```

### Status
- Grouping engine implemented
- Header and subgroup nodes created based on titleformat patterns
- Track indentation based on group depth
- Ready for Phase 3 (album art) or Phase 4 (column headers)
