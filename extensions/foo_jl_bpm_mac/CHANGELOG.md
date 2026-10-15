# Changelog

All notable changes to BPM Analyzer will be documented in this file.

## [0.1.0] - Unreleased

Initial release.

### Added
- **Analyze BPM...**: Finds the tempo of the selected tracks and opens a review window; nothing is written until confirmed.
- **TIDAL tempo**: Used for tracks with an ISRC tag and tidal:// entries when the Tidal component is installed; exact matches only.
- **Local analysis**: Spectral-flux onsets, averaged autocorrelation, 120 BPM prior, sub-frame refinement; several tracks at a time at background priority.
- **Review window**: Current tag, new value, source, agreement with the tag (same / double / half / different), sortable columns, Double/Halve for selected rows.
- **Double BPM / Halve BPM**: Scale the existing BPM tag of the selected tracks.
- **Tag format**: Whole numbers, the only form ID3 TBPM and MP4 tmpo can hold.
- Universal binary (arm64 + x86_64).
