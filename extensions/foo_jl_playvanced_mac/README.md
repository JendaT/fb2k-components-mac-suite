# foo_jl_playvanced

> Part of [foobar2000 macOS Components Suite](../../README.md)

Now Playing bar with transport controls, progress/seek, volume, and quick queue-drop behavior.

## Usage

Add **PlayVanced** to your layout (Layout Editor).

Accepted layout names:
- `PlayVanced` (recommended)
- `playvanced`
- `play_vanced`
- `NowPlaying`
- `nowplaying`
- `now_playing`

## Controls & Shortcut

- **Space** — play/pause
- **Prev / Play-Pause / Next / Stop** — transport control
- **Shuffle** — toggles shuffle tracks on/off
- **Repeat** — cycles: off → repeat playlist → repeat track → off
- **Progress bar** — seek within current track
- **Volume slider / Mute** — output volume control

## Important Behavior

- Selection-aware: when nothing is playing, PlayVanced can show the currently selected track.
- Drop tracks/files onto the panel to add them to active playlist + playback queue.
- If queue is empty and nothing is playing, dropping tracks can auto-start playback.
- Works with internal drag from LibVanced / AlbumViewVanced / SimPlaylist and with Finder file drops.

## Changelog

- [CHANGELOG.md](CHANGELOG.md)
