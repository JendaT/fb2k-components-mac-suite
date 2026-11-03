# Changelog

All notable changes to BPM Analyzer will be documented in this file.

## [0.1.0] - Unreleased

Initial release.

### Added
- **Analyze BPM...**: Finds the tempo of the selected tracks and opens a review window; nothing is written until confirmed.
- **TIDAL tempo**: Used for tracks with an ISRC tag and tidal:// entries when the Tidal component is installed; exact matches only.
- **Local analysis**: Spectral-flux onsets, averaged autocorrelation, 120 BPM prior, sub-frame refinement; several tracks at a time at background priority.
- **Review window**: Current tag, new value, source, agreement with the tag (same / double / half / different), sortable columns, Double/Halve for selected rows.
- **Uncertain results**: Estimates without a clear beat are marked and left unchecked.
- **Double BPM / Halve BPM**: Scale the existing BPM tag of the selected tracks.
- **Tag format**: Whole numbers, the only form ID3 TBPM and MP4 tmpo can hold.
- **Progress**: The bar moves with the decoded share of every track in flight, not only between tracks.
- **Beat grids**: A constant master beat grid per track with statistics per bar, stored with the track (not in tags) and served to Waveform Seekbar's phrase markers; analysed on request (the playing track first) and by Analyze BPM from the same decode.
- **Bars and phrases**: Bar and 32-beat phrase starts found from the track's section changes; bar statistics measured on the onsets at the grid beats, off-beat-only bars and confirmed re-anchors flagged.
- **Beat This!**: Beat grids from the Beat This! network (JKU Linz, MIT) on Core ML, bundled: beats on the kick rather than the off-beat hi-hat, tempo matching the tags more often, bars from its downbeats, beatless passages as no pulse; the classic tracker remains as fallback.
- Universal binary (arm64 + x86_64).
