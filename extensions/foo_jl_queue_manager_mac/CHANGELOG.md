# Changelog

## [1.0.0] - 2025-12-29

Initial release of Queue Manager for foobar2000 macOS.

### Features

- **Queue Display**: Visual table view showing all items in the playback queue
  - Queue position (#), Artist - Title, and Duration columns
  - Live updates when queue changes

- **Queue Management**
  - Double-click to play item from queue
  - Delete/Backspace key to remove selected items
  - Multi-selection support

- **Drag & Drop**
  - Internal reordering within the queue
  - Drop from SimPlaylist to add tracks to queue

- **Visual Design**
  - Matches SimPlaylist appearance (row height, colors, selection style)
  - Glass/vibrancy background option (transparent mode)
  - Custom header styling
  - Status bar showing item count

- **Preferences**
  - Transparent background toggle (Preferences > Display > Queue Manager)

### Technical

- Uses `NSVisualEffectView` for glass effect
- Persists settings via `fb2k::configStore`
- Thread-safe callback handling with debounce support
