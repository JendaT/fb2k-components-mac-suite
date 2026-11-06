# foo_jl_queue_manager

> Part of [foobar2000 macOS Components Suite](../../README.md)

**[Features & Documentation](../../docs/queuemanager.md)** | **[Changelog](CHANGELOG.md)**

---

Visual playback queue manager for foobar2000 macOS - functionality that exists in Windows foobar2000 but was missing on macOS.

## Requirements

- foobar2000 for Mac 2.x
- macOS 12.0+ (Monterey or later)
- Xcode 15+ with Command Line Tools (for building from source)
- Ruby (for project generation)

## Quick Start

### Build and Install

```bash
# From this directory
./Scripts/build.sh --install            # Run tests, build Release and install
./Scripts/build.sh --clean --install    # Clean rebuild and install
./Scripts/build.sh --regenerate --install  # After adding/removing source files

# Restart foobar2000, then add the UI element
```

Never call `xcodebuild` directly; `build.sh` keeps output in the local `build/` directory so `install.sh` copies the binary you just built.

### From Binary

1. Download `foo_jl_queue_manager.fb2k-component` from [Releases](https://github.com/JendaT/fb2k-components-mac-suite/releases?q=Queue+Manager)
2. In foobar2000, open **Preferences** (⌘,) **→ Components**, click **+** and choose the file
3. Restart foobar2000 when it asks

## Usage

### Layout Editor Names

Open **View → Layout → Edit Layout...**, add a line with one of these names inside a splitter where you want the panel, and click **Apply**:

| Recommended | Also Accepted |
|-------------|---------------|
| `queue_manager` | `Queue Manager`, `QueueManager`, `Queue`, `foo_jl_queue_manager`, `jl_queue_manager` |

### Example Layout

```
splitter vertical
  simplaylist
  queue_manager
```

### Interaction

- **Double-click** - Play selected item
- **Delete/Backspace** - Remove selected items from queue
- **Enter** - Play selected item
- **Drag** - Reorder items within the queue
- **Right-click** - Stop After Queue / Turn Off After Stopping Once

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
│   │   ├── QueuePersistence.h/cpp  # Saved-queue serialization
│   │   ├── StopAfterQueuePolicy.h/cpp  # Stop After Queue decisions
│   ├── UI/
│   │   ├── QueueManagerController.h/mm  # Main view controller
│   │   ├── QueueItemWrapper.h/mm   # Safe wrapper for queue items
│   │   ├── QueueRowView.h          # Custom row view
│   │   └── QueueManagerPreferences.h/mm # Preferences UI
│   ├── Integration/
│   │   ├── Main.mm                 # Component registration
│   │   ├── QueueCallbackManager.h/mm  # Singleton callback dispatcher
│   │   ├── QueueCallback.mm        # playback_queue_callback service
│   │   └── StopAfterQueue.mm       # Stop After Queue glue + Playback menu command
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
3. Try rebuilding with `./Scripts/build.sh --clean --install`

### Queue doesn't update

1. Ensure the component is properly loaded (check Preferences > Components)
2. Try removing the `queue_manager` line from the layout, applying, then adding it back

### Build errors

1. Ensure the SDK is built (see [Building from Source](../../README.md#building-from-source) in the main README)
2. Regenerate the project: `./Scripts/build.sh --regenerate --install`

## License

MIT License - see LICENSE file
