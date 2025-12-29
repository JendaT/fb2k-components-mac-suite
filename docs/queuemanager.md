# Queue Manager

A visual playback queue manager for foobar2000 macOS - functionality that exists in Windows foobar2000 but was missing on macOS.

## Features

### Visual Queue Display

See all queued tracks in a familiar table view interface. The queue shows tracks waiting to be played in order.

<!-- Screenshot: Queue Manager with items -->

### Drag & Drop Reordering

Rearrange queue order by dragging items. Move tracks up or down to change when they'll play.

### Live Updates

Queue state syncs in real-time. When tracks are added or removed from the queue (via context menu or other means), the display updates immediately.

### Configurable Columns

Choose which information to display:

| Column | Description |
|--------|-------------|
| # | Queue position (1-based) |
| Artist - Title | Combined artist and title |
| Artist | Artist name only |
| Title | Track title only |
| Album | Album name |
| Duration | Track length |
| Codec | Audio format |
| Bitrate | Bitrate in kbps |
| Path | File path |

Right-click on the column header to show/hide columns.

### Keyboard Shortcuts

| Key | Action |
|-----|--------|
| Delete/Backspace | Remove selected from queue |
| Enter | Play selected item |
| Cmd+A | Select all |
| Escape | Deselect all |

### Context Menu

Right-click on items for:
- **Play** - Start playing the selected item
- **Remove from Queue** - Remove selected items
- **Clear Queue** - Remove all items from queue
- **Show in Playlist** - Navigate to the track's source playlist

### Empty State

When the queue is empty, a helpful message explains how to add items.

## Adding Tracks to Queue

Use the standard foobar2000 context menu on any track:
- Right-click > **Playback** > **Add to playback queue**

Or use the keyboard shortcut (if configured).

## Configuration

Access settings via **Preferences > Display > Queue Manager** (if available).

### Available Settings

| Setting | Description | Default |
|---------|-------------|---------|
| Show Status Bar | Display item count at bottom | On |
| Alternating Rows | Alternating row background colors | On |

## Layout Editor

Add Queue Manager to your layout using any of these names:
- `Queue Manager` (recommended)
- `queue_manager`
- `QueueManager`
- `Queue`
- `foo_jl_queue_manager`

Example layout:
```
splitter vertical
  simplaylist
  Queue Manager
```

## Requirements

- foobar2000 v2.x for macOS
- macOS 11.0 (Big Sur) or later

## Links

- [Main Project](../README.md)
- [Changelog](../extensions/foo_jl_queue_manager_mac/CHANGELOG.md)
- [Build Instructions](../extensions/foo_jl_queue_manager_mac/README.md)
