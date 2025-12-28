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
- See which types are available for current track

<!-- Screenshot: Context menu -->

### Per-Instance Configuration

Each Album Art panel remembers its selected artwork type independently. Perfect for multi-panel setups showing different artwork simultaneously.

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

Display multiple artwork types side by side:

```
splitter horizontal
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

Add Album Art to your layout using any of these names:
- `albumart_ext` (recommended)
- `album_art_ext`
- `foo_jl_album_art`

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

**Front and back covers:**
```
splitter horizontal style=thin
  albumart_ext type=front
  albumart_ext type=back
```

**Complete layout with all components:**
```
splitter vertical
  waveform-seekbar
  splitter horizontal
    splitter horizontal style=thin
      albumart_ext type=front
      albumart_ext type=back
    simplaylist
```

## Requirements

- foobar2000 v2.x for macOS
- macOS 11.0 (Big Sur) or later

## Notes

- Artwork is read from embedded metadata (ID3, Vorbis comments, etc.)
- External artwork files (folder.jpg, cover.png) support depends on foobar2000 configuration
- If a requested artwork type is not available, the panel shows a placeholder or falls back to front cover

## Links

- [Main Project](../README.md)
- [Changelog](../extensions/foo_jl_album_art_mac/CHANGELOG.md)
- [Build Instructions](../extensions/foo_jl_album_art_mac/README.md)
