# foo_jl_libvanced

> Part of [foobar2000 macOS Components Suite](../../README.md)

Tree-style library browser (artist/album/track) with multi-select, drag & drop, and queue/playlist actions.

## Usage

Add **LibVanced** to your layout (Layout Editor).

Accepted layout names:
- `LibVanced` (recommended)
- `libvanced`
- `lib_vanced`
- `Library Vanced`
- `foo_jl_libvanced`

## Shortcuts & Interactions

- **Enter** — send selection to current playlist
- **Q** — add selection to playback queue
- **Space** — play/pause
- **Cmd+A** — select all
- **Double-click** (track/group) — send to current playlist
- **Right-click** — context menu (send/add/queue + foobar actions)
- **Drag selection** — drop to SimPlaylist, Queue Manager, PlayVanced, or Finder

## Important Behavior

- Multi-select is supported for queue/send actions.
- Queue actions can auto-start playback when queue is empty and playback is stopped.
- Search/filter works with foobar2000 library query syntax.
- Drag payload is compatible with other suite components via shared pasteboard format.

## Changelog

- [CHANGELOG.md](CHANGELOG.md)
