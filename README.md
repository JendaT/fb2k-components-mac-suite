# foobar2000 macOS Components

A collection of macOS components for foobar2000 v2 – mostly remakes of the components, which I used to love back then on windows.

DISCLAIMER: All of this is a WIP, actively tested on my foobar2000 instance, but WIP nonetheless, it may crash your foobar.

## Extensions

| Extension | Description | Version | Docs |
|-----------|-------------|---------|------|
| [SimPlaylist](#simplaylist) | Lightweight playlist viewer with album art and grouping | 1.1.7 | [📖](docs/simplaylist.md) |
| [Playlist Organizer](#playlist-organizer) | Tree-based playlist management | 1.3.0 | [📖](docs/plorg.md) |
| [Waveform Seekbar](#waveform-seekbar) | Audio visualization seekbar with effects | 1.1.0 | [📖](docs/waveform.md) |
| [Album Art (Extended)](#album-art-extended) | Multi-type album art viewer with selection support | 1.0.1 | [📖](docs/albumart.md) |
| [Queue Manager](#queue-manager) | Visual playback queue management | 1.0.0 | [📖](docs/queuemanager.md) |
| [Last.fm Scrobbler](#lastfm-scrobbler) | Last.fm integration and scrobbling | 1.0.0 | – |

---

### SimPlaylist

A flat playlist view with album grouping, embedded album art, and metadata display. The one plugin, which makes playlists nicer.

| Overview | Settings |
|----------|----------|
| ![SimPlaylist Overview](docs/images/simplaylist-overview.png) | ![SimPlaylist Settings](docs/images/simplaylist-settings.png) |

**Features:**
- Album-based grouping with customizable patterns
- Embedded album art thumbnails
- Multi-column track display
- Selection sync with foobar2000 playlist manager
- Virtual scrolling for large playlists

---

### Playlist Organizer

Tree-based playlist management with folder organization and smart import. Necesity to manage playlists more managable. No nice screenshots of hyper-organized playlists yet, they are scattered, but there are some import tools to import either from old windows thheme.fth or from Strawberry, which became an alternative for a time being.

| Overview | Import Menu |
|----------|-------------|
| ![Playlist Organizer](docs/images/plorg-overview.png) | ![Import Menu](docs/images/plorg-import-menu.png) |

| Path Mapping | Settings |
|--------------|----------|
| ![Path Mapping](docs/images/plorg-path-mapping.png) | ![Settings](docs/images/plorg-settings.png) |

**Features:**
- Hierarchical folder organization
- Drag-and-drop playlist reordering
- Smart import from filesystem with path mapping
- Autoplaylist support
- Playlist search and filtering

---

### Waveform Seekbar

Audio visualization seekbar with real-time waveform display and visual effects. This one was my favorite, a neat way to navigate through tracks.

| Overview | Settings |
|----------|----------|
| ![Waveform Seekbar](docs/images/waveform-overview.png) | ![Waveform Settings](docs/images/waveform-settings.png) |

**Features:**
- Real-time waveform visualization
- Multiple display modes (bars, lines, filled)
- Customizable colors and effects
- Click-to-seek functionality
- Downmix/channel selection

---

### Album Art (Extended)

Extended album art viewer with support for multiple artwork types and selection-based display. Unlike the built-in album art element, this one can show back covers, disc art, and more.

**Features:**
- Display front, back, disc, icon, or artist artwork
- Shows artwork for selected track (falls back to now playing)
- Right-click context menu to switch artwork type
- Navigation arrows on hover to cycle through available types
- Per-instance configuration (each panel remembers its type)
- Layout parameters for default artwork type

**Layout Usage:**
```
albumart_ext                    # Front cover (default)
albumart_ext type=back          # Back cover
albumart_ext type=disc          # Disc art

# Dual panel layout (front + back side by side)
splitter horizontal
  albumart_ext type=front
  albumart_ext type=back
```

---

### Queue Manager

Visual playback queue manager - functionality that exists in Windows foobar2000 but was missing on macOS. See all queued tracks and manage playback order.

<!-- Screenshot: Queue Manager -->

**Features:**
- Visual queue display with configurable columns
- Drag & drop reordering within queue
- Live updates when queue changes
- Double-click to play, Delete to remove
- Context menu (Play, Remove, Clear, Show in Playlist)

---

### Last.fm Scrobbler

Last.fm integration for scrobbling and now-playing updates. An absolute necesity for us, who celebrated 20 years of last.fm scrobbling this year.

![Last.fm Scrobbler Settings](docs/images/scrobbler-settings.png)

**Features:**
- Automatic track scrobbling after 50% or 4 minutes
- Now Playing notifications
- Browser-based Last.fm authentication
- Offline queue with automatic retry
- Library-only and dynamic source filtering

---

## Downloads

| Component | Download | Forum |
|-----------|----------|-------|
| SimPlaylist | [All Releases](https://github.com/JendaT/fb2k-components-mac-suite/releases?q=simplaylist) | TBD |
| Playlist Organizer | [All Releases](https://github.com/JendaT/fb2k-components-mac-suite/releases?q=plorg) | TBD |
| Waveform Seekbar | [All Releases](https://github.com/JendaT/fb2k-components-mac-suite/releases?q=waveform) | TBD |
| Album Art (Extended) | [All Releases](https://github.com/JendaT/fb2k-components-mac-suite/releases?q=albumart) | TBD |
| Queue Manager | [All Releases](https://github.com/JendaT/fb2k-components-mac-suite/releases?q=queuemanager) | TBD |
| Last.fm Scrobbler | [All Releases](https://github.com/JendaT/fb2k-components-mac-suite/releases?q=scrobble) | TBD |

## Installation

1. Download the `.fb2k-component` file from the links above
2. Double-click to install, or manually copy to `~/Library/foobar2000-v2/user-components/`
3. Restart foobar2000

## Requirements

- foobar2000 v2.6+ for macOS
- macOS 11 "Big Sur" or newer
- Intel or Apple Silicon processor

## Building from Source

Each extension can be built independently:

```bash
cd extensions/foo_jl_<name>_mac  # e.g., foo_jl_simplaylist_mac
ruby Scripts/generate_xcode_project.rb
./Scripts/build.sh
./Scripts/install.sh
```

Or build all extensions:

```bash
./Scripts/build_all.sh [--clean] [--install]
```

## Documentation

### Component Documentation
- [SimPlaylist](docs/simplaylist.md) - Features, configuration, and usage
- [Playlist Organizer](docs/plorg.md) - Features, configuration, and usage
- [Waveform Seekbar](docs/waveform.md) - Features, configuration, and usage
- [Album Art (Extended)](docs/albumart.md) - Features, configuration, and usage
- [Queue Manager](docs/queuemanager.md) - Features, configuration, and usage

### Development
- [Knowledge Base](knowledge_base/) - SDK patterns and best practices
- [Contributing](CONTRIBUTING.md) - Code standards and conventions
- [Troubleshooting](docs/TROUBLESHOOTING.md) - Debug tools and common issues
- [Changelog](CHANGELOG.md) - Version history

## Author

Hi there, I'm a random long-term foobar2000 enjoyer, who had to migrate to MacOS a few years back and have been waiting for some movement on the components field for quite some time. Now after some experience with Claude I put together what was necessary for it to start building the tools which I loved so much when I used foobar on windows.

If you like this project, you can support it here.

[![Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/jendalegenda)

## Layout Editor

To add these components to your layout, use **View → Layout → Enable Layout Editing Mode**, then right-click to add UI elements.

### Component Names for Layout

Use these names in the layout editor or when editing the layout text file directly:

| Component | Recommended | Also Accepted |
|-----------|-------------|---------------|
| SimPlaylist | `simplaylist` | `SimPlaylist`, `foo_jl_simplaylist`, `jl_simplaylist` |
| Playlist Organizer | `plorg` | `playlist-organizer`, `foo_jl_plorg`, `jl_plorg` |
| Waveform Seekbar | `waveform-seekbar` | `waveform_seekbar`, `foo_jl_wave_seekbar`, `jl_wave_seekbar` |
| Album Art (Extended) | `albumart_ext` | `album_art_ext`, `albumart-ext`, `foo_jl_album_art`, `jl_album_art` |
| Queue Manager | `Queue Manager` | `queue_manager`, `QueueManager`, `Queue`, `foo_jl_queue_manager` |

### Example Layout

Here's a complete layout configuration featuring all three UI components:

```
splitter horizontal style=thin
  waveform-seekbar
  splitter vertical style=thin
    splitter horizontal style=thin
      plorg tab-name="Playlists"
    splitter horizontal style=thin
      simplaylist
    splitter horizontal style=thin
      tabs
        splitter horizontal style=thin tab-name="Now Playing"
          albumart
          selection-properties sections=metadata
        audiounit mode=visualization name=AUGraphicEQ vendor=Apple tab-name="EQ"
      playback-controls
```

This creates a layout with:
- Waveform seekbar at the top
- Playlist Organizer on the left sidebar
- SimPlaylist as the main playlist view
- Tabbed panel with Now Playing info and EQ visualization
- Playback controls at the bottom

---

## License

MIT License - see [LICENSE](LICENSE)
