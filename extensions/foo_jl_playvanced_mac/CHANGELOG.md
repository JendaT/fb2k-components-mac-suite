# PlayVanced Changelog

## [Unreleased]

### Added
- **Up Next popover**: List button in the bar shows Now playing, Queued and "Next from" sections; reorder, remove, clear.
- **Keyboard shortcuts**: Space play/pause, ⌘←/→ prev/next, ⌘↑/↓ volume, ⌘S shuffle, ⌘R repeat, ⌥⌘U Up Next.
- **Queue feedback**: Adding to the queue pulses Up Next and shows "Added N tracks to queue".

### Changed
- **Drop on bar**: Dropped tracks are added to the up-next queue (or play immediately when idle) instead of the active playlist.
- **Stopped bar**: All controls stay visible when stopped; Play/Space starts what you queued.
- **Stop button**: Removed from the bar (Pause covers it; Stop stays in the Playback menu).
- **Play keeps the queue**: Playing a track from Up Next no longer flushes queued items.

## [1.0.0] - 2026-03-20

### Added
- Initial release
- Large album art display with rounded corners
- Track metadata: title, artist, album, date, genre
- Technical info: codec, bitrate, sample rate, channels
- Progress bar with elapsed/remaining time
- Selection-aware: shows selected track info when nothing is playing
- Dark mode and vibrancy support
- Scrollable layout for smaller panel sizes
