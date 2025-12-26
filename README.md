# foobar2000 macOS Components

A collection of macOS components for foobar2000 v2.

## Extensions

| Extension | Description | Version |
|-----------|-------------|---------|
| [Simple Playlist](extensions/foo_simplaylist_mac/) | Lightweight playlist viewer with album art and grouping | 1.0.0 |
| [Playlist Organizer](extensions/foo_plorg_mac/) | Tree-based playlist management | 1.0.0 |
| [Waveform Seekbar](extensions/foo_wave_seekbar_mac/) | Audio visualization seekbar with effects | 1.0.0 |
| [Last.fm Scrobbler](extensions/foo_scrobble_mac/) | Last.fm integration and scrobbling | 1.0.0 |

## Installation

1. Download the `.fb2k-component` file from [Releases](https://github.com/JendaT/fb2k-components-mac-suite/releases)
2. Double-click to install, or manually copy to `~/Library/foobar2000-v2/user-components/`
3. Restart foobar2000

## Requirements

- foobar2000 v2.6+ for macOS
- macOS 11 "Big Sur" or newer
- Intel or Apple Silicon processor

## Building from Source

Each extension can be built independently:

```bash
cd extensions/foo_<name>_mac
ruby Scripts/generate_xcode_project.rb
./Scripts/build.sh
./Scripts/install.sh
```

Or build all extensions:

```bash
./Scripts/build_all.sh
```

## Documentation

- [Knowledge Base](knowledge_base/) - SDK patterns and best practices
- [Contributing](CONTRIBUTING.md) - Code standards and conventions
- [Changelog](CHANGELOG.md) - Version history

## Author

**Jenda Legenda** (Jenda Tresnak)

[![Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/jendalegenda)

## License

MIT License - see [LICENSE](LICENSE)
