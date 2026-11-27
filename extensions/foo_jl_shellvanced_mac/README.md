# foo_jl_shellvanced

> Part of [foobar2000 macOS Components Suite](../../README.md)

**[Changelog](CHANGELOG.md)**

---

Spotify-style shell for foobar2000 macOS: a "Your Library" sidebar with playlists and artists, hosted AlbumViewVanced and SimPlaylist pages, artist pages with Deezer photos, and back/forward navigation. Recommended layout, shortcuts and privacy notes: [docs/shellvanced.md](../../docs/shellvanced.md).

## Usage

Add **ShellVanced** to your layout (Layout Editor).

Accepted layout names:
- `ShellVanced` (recommended)
- `shellvanced`
- `vanced_shell`

## Requirements

- foobar2000 v2.x for macOS
- macOS 12.0 or later
- AlbumViewVanced 1.1+ and SimPlaylist 1.6+ installed (otherwise a placeholder is shown)
- PlayVanced 1.1+ recommended (Up Next popover)

## Building

```bash
./Scripts/build.sh --regenerate --install
```
