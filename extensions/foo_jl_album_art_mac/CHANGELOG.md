# Changelog

All notable changes to Album Art (Extended) will be documented in this file.

## [1.0.2] - 2025-12-30

### Fixed
- Fixed layout compression when no album art is available by setting low content hugging and compression resistance priorities

## [1.0.1] - 2025-12-29

### Fixed
- Fixed layout issue where album art images could affect parent container width, causing column resizing when navigating between tracks

## [1.0.0] - 2025-12-28

### Initial Release
- **Multiple Artwork Types**: Support for all 5 artwork types
  - Front cover (default)
  - Back cover
  - Disc art
  - Icon/thumbnail
  - Artist photo
- **Selection-Based Display**: Shows artwork for selected track, falls back to now playing
- **Interactive Navigation**: Arrows on hover to cycle through available artwork types
- **Context Menu**: Right-click to quickly switch artwork type
- **Per-Instance Configuration**: Each panel remembers its selected type
- **Layout Parameters**: Set default type via layout config (e.g., `albumart_ext type=back`)
- **Dual Panel Support**: Display multiple artwork types side by side
- Native macOS rendering with proper scaling
- Dark mode support
