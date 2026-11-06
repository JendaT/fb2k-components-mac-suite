# foo_jl_album_art

> Part of [foobar2000 macOS Components Suite](../../README.md)

**[Features & Documentation](../../docs/albumart.md)** | **[Changelog](CHANGELOG.md)**

---

Extended album artwork display with multiple artwork types for foobar2000 macOS.

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

### From Binary

1. Download `foo_jl_album_art.fb2k-component` from [Releases](https://github.com/JendaT/fb2k-components-mac-suite/releases/tag/albumart-v1.0.1)
2. In foobar2000, open **Preferences** (⌘,) **→ Components**, click **+** and choose the file
3. Restart foobar2000 when it asks

## Usage

### Layout Editor Names

Open **View → Layout → Edit Layout...**, add a line with one of these names inside a splitter where you want the panel, and click **Apply**:

| Recommended | Also Accepted |
|-------------|---------------|
| `albumart_ext` | `foo_jl_album_art`, `jl_album_art`, `jl_albumart`, `jl_albumart_ext` |

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

A common use case is displaying front and back cover side by side (`splitter vertical` places its children side by side, `splitter horizontal` stacks them):

```
splitter vertical
  albumart_ext type=front
  albumart_ext type=back
```

### Interaction

- **Right-click** - Opens context menu to change artwork type
- **Hover** - Reveals navigation arrows on left/right edges
- **Click arrows** - Cycle through available artwork types for the current track

### Fetch Missing Artwork

*Coming in 1.1.0, not released yet.*

Right-click the panel and choose **Fetch Missing...** to search online sources
for artwork matching the current track (artist + album, or MusicBrainz IDs when
tagged). Results appear as thumbnails in a footer below the artwork; click one
to open the lightbox, filter by artwork type, select the images you want, and
save them.

Sources (no configuration needed): **Cover Art Archive** (all artwork types,
via MusicBrainz lookup), **iTunes**, and **Deezer** (front covers).

Save options:
- **Save to album folder** - writes `front.jpg`, `back.jpg`, `disc.jpg`, ...
  next to the audio files (a save panel opens if the folder is not writable)
- **Embed in audio file** - writes the image into the file's tags (MP3, FLAC,
  M4A, ...; not available for WAV/AIFF)

#### TIDAL (optional)

TIDAL requires free developer credentials from
[developer.tidal.com](https://developer.tidal.com/dashboard) (create an app to
get a Client ID and Client Secret). Configure them once from Terminal:

```bash
defaults write com.foobar2000.mac JLAlbumArtTidalClientID "your-client-id"
defaults write com.foobar2000.mac JLAlbumArtTidalClientSecret "your-client-secret"
```

Restart foobar2000; TIDAL is then included in searches automatically. Without
credentials the source is simply skipped.

### Display Priority

1. **Selected track** in the active playlist (first selected item)
2. **Now playing** track (fallback when nothing is selected)

This means clicking a track in the playlist immediately updates the album art display.

## Build Scripts

All scripts are located in the `Scripts/` directory and share `shared/scripts/lib.sh`.

| Script | Purpose |
|--------|---------|
| `build.sh` | Run tests, then build (`--debug`, `--release`, `--clean`, `--regenerate`, `--install`) |
| `run_tests.sh` | Compile and run the Core unit tests standalone |
| `install.sh` | Install a pre-built component (`--config Debug`) |
| `clean.sh` | Remove the build directory and the generated Xcode project |

Never call `xcodebuild` directly; `build.sh` keeps output in the local `build/` directory so `install.sh` copies the binary you just built.

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

The artwork type picked from the context menu is stored in `fb2k::configStore` under a per-instance key (`foo_jl_album_art.instance.<GUID>.type`). The GUID is generated anew each time the panel is created, so after a restart or layout reload the panel starts from its `type=` parameter again.

## Troubleshooting

### Component doesn't load

1. Check Preferences > Components for error messages
2. Verify the component is in `~/Library/foobar2000-v2/user-components/foo_jl_album_art/foo_jl_album_art.component`
3. Try rebuilding with `./Scripts/build.sh --regenerate --install`

### Artwork not displaying

1. Ensure the track has embedded artwork or artwork files in the folder
2. Check foobar2000's album art preferences for fallback settings
3. Right-click and try a different artwork type

### Build errors

1. Ensure the SDK is built (see [Building from Source](../../README.md#building-from-source) in the main README)
2. Regenerate the project: `./Scripts/clean.sh && ./Scripts/build.sh --install`

## License

MIT License - see LICENSE file

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
