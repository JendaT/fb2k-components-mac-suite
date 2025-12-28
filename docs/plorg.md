# Playlist Organizer

Hierarchical playlist organization with folders for foobar2000 macOS.

## Features

### Folder Organization

Organize your playlists into folders with unlimited nesting depth. Create a logical hierarchy that matches how you think about your music.

<!-- Screenshot: Folder hierarchy example -->
![Playlist Organizer Overview](images/plorg-overview.png)

### Tree Lines Display

Optional Windows Explorer-style tree connection lines for visual clarity. Works best for single-level nesting.

<!-- Screenshot: Tree lines enabled vs disabled -->

### Drag & Drop

- Drag playlists into folders
- Reorder playlists and folders
- Move items between folders

### Customizable Display

Use title formatting syntax to customize how nodes are displayed:

```
%node_name%$if(%is_folder%, [%count%],)
```

Available fields:
- `%node_name%` - Name of playlist or folder
- `%is_folder%` - True if item is a folder
- `%count%` - Number of items in folder

### Auto-Sync

Automatically syncs with foobar2000's playlist manager:
- New playlists appear in the organizer
- Deleted playlists are removed
- Renamed playlists update automatically

### Import/Export

Share your organization structure:
- **Export** - Save current structure to file
- **Import** - Load structure from file
- Supports path mapping for portable configurations

<!-- Screenshot: Import menu -->
![Import Menu](images/plorg-import-menu.png)

### Path Mapping

When importing configurations from different systems, map paths to work with your local library:

<!-- Screenshot: Path mapping dialog -->
![Path Mapping](images/plorg-path-mapping.png)

## Configuration

Access settings via **Preferences > Display > Playlist Organizer**

<!-- Screenshot: Settings panel -->
![Playlist Organizer Settings](images/plorg-settings.png)

### Available Settings

| Setting | Description | Default |
|---------|-------------|---------|
| Node Format | Title formatting string for display | `%node_name%...` |
| Show Tree Lines | Display tree connection lines | Off |

### Configuration File

The tree structure is stored as human-readable YAML at:
```
~/Library/foobar2000-v2/foo_plorg.yaml
```

Example:
```yaml
# Playlist Organizer Configuration
node_format: "%node_name%$if(%is_folder%, [%count%],)"

tree:
  - folder: "Rock"
    expanded: true
    items:
      - playlist: "Classic Rock"
      - playlist: "Alternative"
  - folder: "Electronic"
    items:
      - playlist: "Ambient"
      - playlist: "Techno"
  - playlist: "Favorites"
```

## Layout Editor

Add Playlist Organizer to your layout using any of these names:
- `plorg` (recommended)
- `Playlist Organizer`
- `playlist_organizer`
- `foo_jl_plorg`

Example layout:
```
splitter horizontal style=thin
  plorg tab-name="Playlists"
  simplaylist
```

## Context Menu

Right-click options:
- **New Folder** - Create a new folder
- **Rename** - Rename selected item
- **Delete** - Remove folder (playlists moved to root)
- **Expand All / Collapse All** - Toggle all folders
- **Import / Export** - Configuration management

## Requirements

- foobar2000 v2.x for macOS
- macOS 11.0 (Big Sur) or later

## Links

- [Main Project](../README.md)
- [Changelog](../extensions/foo_jl_plorg_mac/CHANGELOG.md)
- [Build Instructions](../extensions/foo_jl_plorg_mac/README.md)
