# foo_jl_cloud_streamer

A foobar2000 macOS component for streaming Mixcloud and SoundCloud content directly in playlists.

## Features

- Stream Mixcloud mixes and SoundCloud tracks directly in foobar2000
- Add tracks via URL paste or drag-drop from browser
- Full metadata display (title, artist, duration, album art)
- Seeking support for both services
- Persistent metadata cache
- Automatic stream URL caching with TTL

## Requirements

- foobar2000 v2 for Mac
- macOS 12.0 or later
- **yt-dlp** (required for stream extraction)

## Installing yt-dlp

The component requires yt-dlp to be installed. Install via Homebrew:

```bash
brew install yt-dlp
```

Or download from: https://github.com/yt-dlp/yt-dlp/releases

## Installation

1. Download `foo_jl_cloud_streamer.component`
2. Copy to: `~/Library/foobar2000-v2/user-components/foo_jl_cloud_streamer/`
3. Restart foobar2000

## Usage

### Adding Tracks

1. Copy a Mixcloud or SoundCloud URL
2. In foobar2000, use Edit > Paste URL (or Cmd+V in playlist)
3. The track will be added to your playlist

### Supported URLs

```
https://www.mixcloud.com/username/track-name/
https://soundcloud.com/username/track-name
```

## Audio Quality

| Service    | Format    | Bitrate | Notes |
|------------|-----------|---------|-------|
| Mixcloud   | AAC       | 64 kbps | Service maximum |
| SoundCloud | AAC       | 160 kbps | Without subscription |
| SoundCloud | MP3       | 128 kbps | Fallback |

## Configuration

Access preferences via: foobar2000 > Preferences > Tools > Cloud Streamer

- **yt-dlp path**: Custom path to yt-dlp executable
- **Format preferences**: Select preferred audio format per service
- **Cache management**: View stats, clear cached data
- **Debug logging**: Enable verbose console output

## Limitations

- Audio quality is limited by service restrictions
- Mixcloud offers only 64kbps AAC
- SoundCloud Go+ quality (320kbps) requires authentication (not yet supported)
- Private or region-restricted tracks may not play

## Building from Source

### Requirements
- Xcode 15+
- foobar2000 macOS SDK (SDK-2025-03-07)

### Build
```bash
cd foo_jl_cloud_streamer_mac
./Scripts/build.sh
```

### Install
```bash
./Scripts/install.sh
```

## License

Personal/non-commercial use. Part of the foobar2000 macOS components suite.

## Author

Jenda Legenda

- GitHub: https://github.com/JendaT/fb2k-components-mac-suite
- Support: https://ko-fi.com/jendalegenda
