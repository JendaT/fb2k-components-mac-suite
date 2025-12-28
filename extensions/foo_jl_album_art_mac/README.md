# foo_jl_album_art - Album Art (Extended) for macOS foobar2000

A foobar2000 macOS component that displays album artwork with support for multiple artwork types and selection-based display.

## Features

- **Multiple Artwork Types** - Display front cover, back cover, disc, icon, or artist artwork
- **Selection-Based Display** - Shows artwork for the selected track in the playlist (falls back to now playing)
- **Right-Click Context Menu** - Switch artwork type on the fly
- **Navigation Arrows** - Hover to reveal arrows for cycling through available artwork types
- **Per-Instance Configuration** - Each panel remembers its own artwork type setting
- **Layout Parameters** - Set default artwork type via layout editor
- **Aspect Ratio Options** - Square mode and zoomable support

## Requirements

- foobar2000 for Mac 2.x
- macOS 11.0+ (Big Sur or later)
- Xcode 12+ with Command Line Tools (for building from source)
- Ruby (for project generation)

## Quick Start

### Build and Test Install

```bash
# One-command build and install for testing
./Scripts/test_install.sh

# Restart foobar2000, then add the UI element
```

### From Binary

1. Download `foo_jl_album_art.fb2k-component` from Releases
2. Create folder: `~/Library/foobar2000-v2/user-components/foo_jl_album_art/`
3. Copy `foo_jl_album_art.component` into that folder
4. Restart foobar2000

## Usage

### Layout Editor Names

Use these names in the layout editor:

| Recommended | Also Accepted |
|-------------|---------------|
| `albumart_ext` | `album_art_ext`, `albumart-ext`, `foo_jl_album_art`, `jl_album_art`, `jl_albumart` |

### Layout Parameters

```
albumart_ext                    # Front cover (default)
albumart_ext type=front         # Front cover
albumart_ext type=back          # Back cover
albumart_ext type=disc          # Disc/CD art
albumart_ext type=icon          # Album icon
albumart_ext type=artist        # Artist picture
albumart_ext type=front square  # Square aspect ratio
```

### Dual Panel Layout (Front + Back Cover)

A common use case is displaying front and back cover side by side:

```
splitter horizontal
  albumart_ext type=front
  albumart_ext type=back
```

### Interaction

- **Right-click** - Opens context menu to change artwork type
- **Hover** - Reveals navigation arrows on left/right edges
- **Click arrows** - Cycle through available artwork types for the current track

### Display Priority

1. **Selected track** in the active playlist (first selected item)
2. **Now playing** track (fallback when nothing is selected)

This means clicking a track in the playlist immediately updates the album art display.

## Build Scripts

All scripts are located in the `Scripts/` directory.

### test_install.sh

```bash
./Scripts/test_install.sh           # Clean build (Release) and install
./Scripts/test_install.sh --debug   # Build Debug configuration
./Scripts/test_install.sh --no-clean # Skip cleaning, faster rebuild
./Scripts/test_install.sh --regenerate # Force regenerate Xcode project
```

### install.sh

```bash
./Scripts/install.sh                # Install Release build
./Scripts/install.sh --config Debug # Install Debug build
```

### clean.sh

```bash
./Scripts/clean.sh                  # Clean build directory
```

## Project Structure

```
foo_jl_album_art_mac/
├── src/
│   ├── Core/
│   │   ├── AlbumArtConfig.h        # Artwork types, per-instance config
│   │   └── AlbumArtFetcher.h/mm    # Artwork fetching, callback manager
│   ├── UI/
│   │   ├── AlbumArtView.h/mm       # NSView with navigation arrows
│   │   └── AlbumArtController.h/mm # View controller, context menu
│   ├── Integration/
│   │   └── Main.mm                 # Component registration, callbacks
│   ├── fb2k_sdk.h                  # SDK configuration
│   └── Prefix.pch                  # Precompiled header
├── Resources/
│   └── Info.plist                  # Bundle metadata
├── Scripts/
│   ├── generate_xcode_project.rb   # Project generator
│   ├── install.sh                  # Install script
│   ├── clean.sh                    # Clean script
│   └── test_install.sh             # Build + install for testing
└── README.md
```

## Technical Details

### Artwork Types

| Type | SDK GUID | Description |
|------|----------|-------------|
| Front | `album_art_ids::cover_front` | Album front cover |
| Back | `album_art_ids::cover_back` | Album back cover |
| Disc | `album_art_ids::disc` | CD/disc artwork |
| Icon | `album_art_ids::icon` | Album icon |
| Artist | `album_art_ids::artist` | Artist picture |

### Callbacks

The component uses two callback systems:
- `play_callback_static` - For playback events (track change, stop)
- `playlist_callback_static` - For selection changes in the playlist

### Per-Instance Storage

Each component instance has a unique GUID. Artwork type preferences are stored in `fb2k::configStore` with keys like:
```
foo_jl_album_art.instance.<GUID>.type
```

## Troubleshooting

### Component doesn't load

1. Check Preferences > Components for error messages
2. Verify the component is in `~/Library/foobar2000-v2/user-components/foo_jl_album_art/foo_jl_album_art.component`
3. Try rebuilding with `./Scripts/test_install.sh --regenerate`

### Artwork not displaying

1. Ensure the track has embedded artwork or artwork files in the folder
2. Check foobar2000's album art preferences for fallback settings
3. Right-click and try a different artwork type

### Build errors

1. Ensure SDK is built: `cd ../SDK-2025-03-07 && xcodebuild`
2. Regenerate project: `./Scripts/clean.sh && ruby Scripts/generate_xcode_project.rb`

## License

MIT License - see LICENSE file

## Changelog

### 1.0.0 (2024)

- Initial release
- Support for all 5 artwork types (front, back, disc, icon, artist)
- Selection-based display with now-playing fallback
- Right-click context menu
- Navigation arrows on hover
- Per-instance configuration
- Layout parameter support
- Universal binary (arm64 + x86_64)
