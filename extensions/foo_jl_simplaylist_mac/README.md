# foo_jl_simplaylist

> Part of [foobar2000 macOS Components Suite](../../README.md)

**[Features & Documentation](../../docs/simplaylist.md)** | **[Changelog](CHANGELOG.md)**

---

A streamlined playlist view with album grouping and cover art display.

## Building from Source

### Requirements

- macOS 11.0 (Big Sur) or later
- Xcode 14.0 or later
- foobar2000 SDK 2025-03-07
- Ruby (for project generation)

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
foo_jl_simplaylist_mac/
├── src/
│   ├── Core/           # Configuration helpers
│   ├── UI/             # SimPlaylistView, Controller, Preferences
│   ├── Integration/    # SDK registration, callbacks
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

## Development

### Debug Build

```bash
./Scripts/build.sh --debug
```

### Clean Build

```bash
./Scripts/build.sh --clean
```

### Regenerate Project

```bash
ruby Scripts/generate_xcode_project.rb
```

## License

MIT License
