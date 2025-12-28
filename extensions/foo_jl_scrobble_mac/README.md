# foo_jl_scrobble

> Part of [foobar2000 macOS Components Suite](../../README.md)

**[Changelog](CHANGELOG.md)**

---

Last.fm scrobbler for foobar2000 macOS.

## Building from Source

### Requirements

- macOS 11.0 (Big Sur) or later
- Xcode 14.0 or later
- foobar2000 SDK 2025-03-07
- Ruby (for project generation)
- Last.fm API credentials

### API Credentials

Create `src/SecretConfig.h` from the template:
```bash
cp src/SecretConfig.h.template src/SecretConfig.h
```

Then edit with your Last.fm API credentials:
```cpp
#define LASTFM_API_KEY "your_api_key"
#define LASTFM_API_SECRET "your_api_secret"
```

Get credentials at: https://www.last.fm/api/account/create

### Build Steps

1. **Build SDK Libraries** (if not already done):
   ```bash
   cd ../SDK-2025-03-07/foobar2000
   xcodebuild -workspace foobar2000.xcworkspace -scheme "foobar2000 SDK" -configuration Release build
   ```

2. **Generate Xcode Project**:
   ```bash
   ruby Scripts/generate_xcode_project.rb
   ```

3. **Build**:
   ```bash
   ./Scripts/build.sh
   ```

4. **Install**:
   ```bash
   ./Scripts/install.sh
   ```

## Project Structure

```
foo_jl_scrobble_mac/
├── src/
│   ├── Core/           # Scrobble logic, API client, cache
│   ├── UI/             # Preferences controller
│   ├── Integration/    # SDK registration, playback callbacks
│   ├── SecretConfig.h.template
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
- Automatic scrobbling based on play duration
- Now Playing updates
- Offline cache for failed scrobbles
- Configurable scrobble threshold

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
