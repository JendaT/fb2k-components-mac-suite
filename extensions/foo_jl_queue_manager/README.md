# foo_jl_queue_manager

> Part of [foobar2000 macOS Components Suite](../../README.md)

**[Features & Documentation](../../docs/queuemanager.md)** | **[Changelog](CHANGELOG.md)**

---

Visual playback queue manager for foobar2000 macOS - functionality that exists in Windows foobar2000 but was missing on macOS.

## Requirements

- foobar2000 for Mac 2.x
- macOS 11.0+ (Big Sur or later)
- Xcode 12+ with Command Line Tools (for building from source)
- Ruby (for project generation)

## Quick Start

### Build and Install

```bash
# Generate Xcode project
ruby Scripts/generate_xcode_project.rb

# Build Release configuration
xcodebuild -project foo_jl_queue_manager.xcodeproj -configuration Release

# Install component
./Scripts/install.sh
```

### From Binary

1. Download `foo_jl_queue_manager.fb2k-component` from Releases
2. Create folder: `~/Library/foobar2000-v2/user-components/foo_jl_queue_manager/`
3. Copy `foo_jl_queue_manager.component` into that folder
4. Restart foobar2000

## Usage

### Layout Editor Names

Use these names in the layout editor:

| Recommended | Also Accepted |
|-------------|---------------|
| `Queue Manager` | `queue_manager`, `QueueManager`, `Queue`, `foo_jl_queue_manager`, `jl_queue_manager` |

### Example Layout

```
splitter vertical
  simplaylist
  Queue Manager
```

### Interaction

- **Double-click** - Play selected item
- **Delete/Backspace** - Remove selected items from queue
- **Enter** - Play selected item
- **Drag** - Reorder items within the queue
- **Right-click** - Context menu (Play, Remove, Clear, Show in Playlist)

### Adding Tracks to Queue

Use the standard foobar2000 context menu:
- Right-click any track > **Playback** > **Add to playback queue**

## Project Structure

```
foo_jl_queue_manager/
├── src/
│   ├── Core/
│   │   ├── ConfigHelper.h          # fb2k::configStore wrapper
│   │   ├── QueueConfig.h           # Configuration constants
│   │   ├── QueueOperations.h/cpp   # SDK queue operations wrapper
│   ├── UI/
│   │   ├── QueueManagerController.h/mm  # Main view controller
│   │   ├── QueueItemWrapper.h/mm   # Safe wrapper for queue items
│   │   ├── QueueRowView.h          # Custom row view
│   │   ├── QueueHeaderCell.h/mm    # Column header
│   │   └── QueueManagerPreferences.h/mm # Preferences UI
│   ├── Integration/
│   │   ├── Main.mm                 # Component registration
│   │   ├── QueueCallbackManager.h/mm  # Singleton callback dispatcher
│   │   └── QueueCallback.mm        # playback_queue_callback service
│   ├── fb2k_sdk.h                  # SDK configuration
│   └── Prefix.pch                  # Precompiled header
├── Resources/
│   └── Info.plist                  # Bundle metadata
├── Scripts/
│   ├── generate_xcode_project.rb   # Project generator
│   └── install.sh                  # Install script
├── docs/
│   ├── 01_FOUNDATION.md            # Design document
│   └── 02_SDK_NOTES.md             # SDK API notes
└── README.md
```

## Technical Details

### SDK APIs

The component uses these foobar2000 SDK APIs:

```cpp
// Queue operations (from playlist_manager)
queue_get_count()
queue_get_contents(pfc::list_base_t<t_playback_queue_item>& out)
queue_add_item_playlist(t_size playlist, t_size item)
queue_remove_mask(const bit_array& mask)
queue_flush()

// Callback for queue changes
class playback_queue_callback : public service_base {
    void on_changed(t_change_origin origin);
};
```

### Callback Manager Pattern

Uses singleton `QueueCallbackManager` to dispatch queue change events to all active controller instances. Includes debounce support to prevent flicker during reorder operations.

### Memory Safety

Queue items are wrapped in `QueueItemWrapper` using C++ member variables (not Objective-C properties) to safely hold `metadb_handle_ptr` references.

## Troubleshooting

### Component doesn't load

1. Check Preferences > Components for error messages
2. Verify the component is in `~/Library/foobar2000-v2/user-components/foo_jl_queue_manager/foo_jl_queue_manager.component`
3. Try rebuilding with a clean project

### Queue doesn't update

1. Ensure the component is properly loaded (check Preferences > Components)
2. Try closing and re-adding the Queue Manager UI element

### Build errors

1. Ensure SDK is built: `cd ../SDK-2025-03-07 && xcodebuild`
2. Regenerate project: `ruby Scripts/generate_xcode_project.rb`

## License

MIT License - see LICENSE file
