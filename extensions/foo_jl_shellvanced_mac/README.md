# foo_jl_shellvanced

> Part of [foobar2000 macOS Components Suite](../../README.md)

**[Changelog](CHANGELOG.md)**

---

Streaming-style shell for foobar2000 macOS. Hosts other components' UI elements (AlbumViewVanced, SimPlaylist) inside a single layout element. Early work in progress.

## Usage

Add **ShellVanced** to your layout (Layout Editor).

Accepted layout names:
- `ShellVanced` (recommended)
- `shellvanced`
- `vanced_shell`

## Requirements

- foobar2000 v2.x for macOS
- macOS 12.0 or later
- AlbumViewVanced installed (otherwise a placeholder is shown)

## Building

```bash
./Scripts/build.sh --regenerate --install
```
