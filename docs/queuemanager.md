# Queue Manager

A visual playback queue manager for foobar2000 macOS - functionality that exists in Windows foobar2000 but was missing on macOS.

## Features

### Visual Queue Display

See all queued tracks in a familiar table view interface. The queue shows tracks waiting to be played in order.

![Queue Manager with queued tracks](images/queuemanager-overview.png)

### Drag & Drop Reordering

Rearrange queue order by dragging items. Move tracks up or down to change when they'll play.

### Live Updates

Queue state syncs in real-time. When tracks are added or removed from the queue (via context menu or other means), the display updates immediately.

### Queue Restore After Restart

foobar2000 empties the playback queue when it quits. Queue Manager saves the queue on quit and re-adds it on the next launch, keeping each track's playlist position when that position still holds the same track. Enabled by default; turn off with **Restore queue after restart** in preferences.

### Stop After Queue

With **Stop After Queue** on, playback stops when the last queued track finishes instead of continuing in the playlist. Toggle it from **Playback > Stop After Queue**, the Queue Manager context menu, or preferences. Off by default.

- Queuing more tracks while the last one plays cancels the pending stop; the stop moves to the new end of the queue.
- Skipping past the last queued track also cancels it.
- Only the queue running out during playback triggers it; clearing the queue by hand does not.
- **Turn off after it stops playback once** (preferences or context menu) makes it one-shot: after it stops playback, Stop After Queue switches itself off.

### Columns

The queue shows three columns: **#** (queue position), **Artist - Title** and **Duration**. Drag the header dividers to resize them. Choosing other columns is not implemented yet.

### Status Bar

The bar at the bottom shows how many items are queued.

### Keyboard Shortcuts

| Key | Action |
|-----|--------|
| Delete/Backspace | Remove selected from queue |
| Enter | Play selected item |
| Cmd+A | Select all |

### Context Menu

Right-click anywhere in Queue Manager for:
- **Stop After Queue** - Stop playback when the queue runs out
- **Turn Off After Stopping Once** - Make Stop After Queue one-shot (available while Stop After Queue is on)

## Adding Tracks to Queue

Use the standard foobar2000 context menu on any track:
- Right-click > **Playback** > **Add to playback queue**

Or use the keyboard shortcut (if configured).

## Configuration

Access settings via **Preferences > Display > Queue Manager**.

### Available Settings

| Setting | Description | Default |
|---------|-------------|---------|
| Transparent background (glass effect) | Translucent background; takes effect after restart | On |
| Restore queue after restart | Save the queue on quit and re-add it on launch | On |
| Stop after queue | Stop when the last queued track finishes | Off |
| Turn off after it stops playback once | Stop after queue switches itself off after stopping once | Off |

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
- macOS 12.0 (Monterey) or later

## Links

- [Main Project](../README.md)
- [Changelog](../extensions/foo_jl_queue_manager_mac/CHANGELOG.md)
- [Build Instructions](../extensions/foo_jl_queue_manager_mac/README.md)
