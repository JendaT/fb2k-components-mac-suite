# foo_jl_albumviewvanced

> Part of [foobar2000 macOS Components Suite](../../README.md)

Album-first library browser with cover thumbnails and quick queue/play actions.

## Usage

Add **AlbumViewVanced** to your layout (Layout Editor).

Accepted layout names:
- `AlbumViewVanced` (recommended)
- `albumviewvanced`
- `album_view_vanced`

## Shortcuts & Interactions

- **Enter** — plays the selected album/track via the AlbumViewVanced temp playlist
- **Q** — add selected album/track to playback queue
- **Space** — play/pause
- **Esc** — collapse expanded album
- **Arrow keys** — navigate albums/tracks
- **Double-click** — same action as Enter
- **Right-click** — open context menu
- **Drag** album/track — drop into SimPlaylist, Queue Manager, PlayVanced, or Finder

## Important Behavior

- Double-click and Enter always play the album/track through `Now Playing`.
- If the playback queue already contains items, it is cleared before the album context starts.
- **Q** and context-menu queue actions keep their existing queue behavior.
- **Q** queues without switching view context.
- Context-menu **Play** uses the same temp-playlist playback path.
- Context-menu **Add to Now Playing** appends to `Now Playing`.
- Context-menu **Add to Playlist** can append to the current playlist, create a new playlist, or target any existing playlist (sorted list, excluding `Now Playing`).
- Search is live with a short debounce; **Enter** applies immediately and **Esc** in the search field clears it.

## Changelog

- [CHANGELOG.md](CHANGELOG.md)
