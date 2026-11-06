# Album Art (Extended)

Extended album artwork display with multiple artwork types for foobar2000 macOS.

## Features

### Multiple Artwork Types

Support for all 5 artwork types embedded in your music files:

| Type | Description |
|------|-------------|
| **Front** | Front cover (default) |
| **Back** | Back cover |
| **Disc** | CD/disc artwork |
| **Icon** | Small icon/thumbnail |
| **Artist** | Artist photo |

<!-- Screenshot: Different artwork types -->

### Selection-Based Display

Intelligently chooses which artwork to display:
1. **Selected track** - Shows artwork for the currently selected track
2. **Now playing** - Falls back to now playing if nothing selected

This allows you to browse your library and see artwork for selected tracks while music plays.

### Interactive Navigation

Hover over the artwork to reveal navigation arrows:
- **Left arrow** - Previous artwork type
- **Right arrow** - Next artwork type

Cycles through all available artwork types for the current track.

<!-- Screenshot: Navigation arrows on hover -->

### Context Menu

Right-click for quick access to:
- Switch to specific artwork type
- Fetch missing artwork from online sources (1.1.0, not released yet)

<!-- Screenshot: Context menu -->

### Fetch Missing Artwork

*Coming in 1.1.0, not released yet.*

Search online sources for artwork matching the current track (right-click >
**Fetch Missing...**). Results appear as thumbnails in a footer; click one to
open a lightbox with type filters (Front/Back/Disc/...), pick the images you
want, then save them to the album folder and/or embed them into the file tags.

Sources: Cover Art Archive (via MusicBrainz), iTunes, Deezer - no setup
required. TIDAL is available as an additional source with free developer
credentials (see the component README for setup).

### Per-Panel Artwork Type

Each Album Art panel shows its own artwork type, so several panels can show different artwork at once. A type picked from the context menu lasts until foobar2000 restarts or the layout is reloaded; set a lasting one with the `type=` layout parameter.

### Layout Parameters

Set the default artwork type directly in your layout configuration:

```
albumart_ext                    # Front cover (default)
albumart_ext type=front         # Explicit front cover
albumart_ext type=back          # Back cover
albumart_ext type=disc          # Disc art
albumart_ext type=icon          # Icon
albumart_ext type=artist        # Artist photo
```

### Dual Panel Setup

Display multiple artwork types side by side (`splitter vertical` places its children side by side, `splitter horizontal` stacks them):

```
splitter vertical
  albumart_ext type=front
  albumart_ext type=back
```

<!-- Screenshot: Dual panel showing front and back -->

### Native Rendering

- Proper aspect ratio preservation
- High-quality scaling for any panel size
- Retina display support
- Dark mode compatible

## Layout Editor

Open **View → Layout → Edit Layout...**, add a line with one of these names where you want the panel, and click **Apply**:
- `albumart_ext` (recommended)
- `foo_jl_album_art`
- `jl_album_art`

### Layout Examples

**Basic usage:**
```
albumart_ext
```

**With playlist:**
```
splitter horizontal
  albumart_ext
  simplaylist
```

**Front and back covers side by side:**
```
splitter vertical style=thin
  albumart_ext type=front
  albumart_ext type=back
```

**Complete layout with all components:**
```
splitter horizontal
  waveform-seekbar
  splitter vertical
    splitter horizontal style=thin
      albumart_ext type=front
      albumart_ext type=back
    simplaylist
```

## Requirements

- foobar2000 v2.x for macOS
- macOS 12.0 (Monterey) or later

## Notes

- Artwork is read from embedded metadata (ID3, Vorbis comments, etc.)
- External artwork files (folder.jpg, cover.png) support depends on foobar2000 configuration
- If a requested artwork type is not available, the panel shows the type's name (e.g. "Back Cover") as a placeholder

## Links

- [Main Project](../README.md)
- [Changelog](../extensions/foo_jl_album_art_mac/CHANGELOG.md)
- [Build Instructions](../extensions/foo_jl_album_art_mac/README.md)
