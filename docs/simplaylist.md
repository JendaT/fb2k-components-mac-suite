# SimPlaylist

A streamlined playlist view with album grouping and cover art display for foobar2000 macOS.

## Features

### Album Grouping with Cover Art

SimPlaylist automatically groups tracks by album and displays album artwork alongside your music. Click on album art to select all tracks in that album.

<!-- Screenshot: Overview showing album groups with artwork -->
![SimPlaylist Overview](images/simplaylist-overview.png)

### Header Display Styles

Three configurable header display modes to match your preference:

| Style | Description |
|-------|-------------|
| **Above tracks** | Header row appears above track rows with separator line |
| **Album art aligned** | Header text starts at left edge, aligned with album art |
| **Inline** | Compact header style with smaller text, no separator line |

<!-- Screenshot: Comparison of header styles -->

### Now Playing Highlight

Optional yellow shading highlights the currently playing track, making it easy to spot in large playlists.

<!-- Screenshot: Now playing highlight example -->

### Subgroup Support

Display disc numbers as subgroups within album groups - perfect for multi-disc albums.

<!-- Screenshot: Multi-disc album with subgroups -->

### Virtual Scrolling

Efficiently handles playlists of any size with smooth scrolling performance.

### Keyboard Navigation

Full keyboard support:
- **Arrow keys** - Navigate between tracks
- **Page Up/Down** - Scroll by page
- **Home/End** - Jump to beginning/end
- **Enter** - Play selected track
- **Space** - Toggle play/pause

### Drag & Drop Reordering

Reorder tracks within the playlist using drag and drop.

### Context Menu

Right-click for the standard foobar2000 context menu with all playback and metadata options.

## Configuration

Access settings via **Preferences > Display > SimPlaylist**

<!-- Screenshot: Settings panel -->
![SimPlaylist Settings](images/simplaylist-settings.png)

### Available Settings

| Setting | Description | Default |
|---------|-------------|---------|
| Album Art Size | Size of album artwork in pixels | 80 |
| Header Display | Header style (Above/Aligned/Inline) | Above tracks |
| Highlight Now Playing | Show yellow highlight on playing track | Off |

## Layout Editor

Add SimPlaylist to your layout using any of these names:
- `simplaylist` (recommended)
- `SimPlaylist`
- `foo_jl_simplaylist`

Example layout:
```
splitter horizontal
  simplaylist
  albumart_ext
```

## Requirements

- foobar2000 v2.x for macOS
- macOS 11.0 (Big Sur) or later

## Links

- [Main Project](../README.md)
- [Changelog](../extensions/foo_jl_simplaylist_mac/CHANGELOG.md)
- [Build Instructions](../extensions/foo_jl_simplaylist_mac/README.md)
