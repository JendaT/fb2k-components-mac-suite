# foo_jl_scrobble

> Part of [foobar2000 macOS Components Suite](../../README.md)

**[Changelog](CHANGELOG.md)**

---

Last.fm scrobbler for foobar2000 macOS.

## Building from Source

### Requirements

- macOS 12.0 (Monterey) or later
- Xcode 15 or later
- foobar2000 SDK 2026-10-01 (at the repository root, see the [main README](../../README.md#building-from-source))
- Ruby (for project generation)
- Last.fm API credentials

### API Credentials

Create `src/LastFm/SecretConfig.h` from the template:
```bash
cp src/LastFm/SecretConfig.h.template src/LastFm/SecretConfig.h
```

Then edit with your Last.fm API credentials:
```cpp
#define LASTFM_API_KEY "your_api_key"
#define LASTFM_API_SECRET "your_api_secret"
```

Get credentials at: https://www.last.fm/api/account/create

### Build Steps

1. **Build the SDK libraries** once, as described in [Building from Source](../../README.md#building-from-source) in the main README.

2. **Build and install** (generates the Xcode project on the first run):
   ```bash
   ./Scripts/build.sh --install
   ```

3. Restart foobar2000.

## Project Structure

```
foo_jl_scrobble_mac/
├── src/
│   ├── Core/           # Scrobble logic, API client, cache
│   ├── LastFm/         # Last.fm API, SecretConfig.h.template
│   ├── UI/             # Preferences controller
│   ├── Integration/    # SDK registration, playback callbacks
│   ├── fb2k_sdk.h
│   └── Prefix.pch
├── Resources/
│   └── Info.plist
├── Scripts/
│   ├── generate_xcode_project.rb
│   ├── build.sh
│   └── install.sh
├── CHANGELOG.md
└── README.md
```

## Features

- Last.fm authentication via web browser
- Automatic scrobbling after 50% of the track or 4 minutes played (fixed)
- Now Playing updates
- Offline queue with automatic retry, and a queue viewer in the preferences
- Stats widget (layout element `lastfm_scrobbler`): top albums, artists and tracks, recent tracks with live Now Playing, listening streak

## Configuration

Access settings via **Preferences > Tools > Last.fm Scrobbler**

## Development

### Debug Build

```bash
./Scripts/build.sh --debug
```

### Clean Build

```bash
./Scripts/build.sh --clean
```

## License

MIT License
