# foo_jl_playback_controls - Backlog

## Remaining Features for Future Releases

### v0.2.0 - Preferences & Polish

- [ ] **Preferences page** - Add dedicated preferences UI under foobar2000 Preferences
  - Top row format text field
  - Bottom row format text field
  - Reset to default layout button

- [ ] **Vertical volume slider** - Currently horizontal only, vertical orientation is stubbed but not fully implemented

- [ ] **Compact mode refinement** - Basic support exists but needs polish
  - Proper layout adjustments
  - Context menu toggle

### v0.3.0 - Advanced Features

- [ ] **Multiple instance support** - Config storage supports instance IDs but UI doesn't generate unique IDs yet
  - Each instance should get unique GUID on creation
  - Per-instance button order persistence

- [ ] **Seekbar integration** - Optional seekbar in the track info area

- [ ] **Album art thumbnail** - Small album art display option

### Known Issues

- [ ] Deprecated API warning for `view:stringForToolTip:point:userData:` in VolumeSliderView.mm (cosmetic, still works)

### Code Quality

- [ ] Add unit tests for config storage
- [ ] Add accessibility labels to buttons
- [ ] Localization support

## Completed (v0.1.0)

- [x] Transport buttons (prev, stop, play/pause, next)
- [x] Volume slider with mute toggle
- [x] Two-row track info display with configurable titleformat
- [x] Click track info to navigate to playing track
- [x] Playback callbacks for real-time updates
- [x] Drag-to-reorder editing mode with jiggle animation
- [x] Long-press to enter edit mode
- [x] Context menu with edit toggle
- [x] Button order persistence
- [x] ui_element_mac registration
