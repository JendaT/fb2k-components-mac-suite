//
//  PlaylistSelectionModel.h
//  foo_simplaylist_mac
//
//  Pure selection/focus/anchor state machine for the playlist view.
//
//  Contains NO foobar2000 SDK dependency and NO AppKit: only the multi-select
//  math (single/extend/toggle, group clicks, keyboard focus navigation) over
//  playlist indices. Extracted from SimPlaylistView so this logic can be
//  unit-tested without an NSView or a running host.
//
//  Row navigation (skipping header/subgroup/padding rows) is computed against
//  the PlaylistLayoutModel supplied at init. Methods mutate state only; the
//  owning view is responsible for delegate notifications, scrolling, and
//  redraw. `selectedIndices` is a single stable NSMutableIndexSet instance for
//  the model's lifetime — the view (and, through it, the controller) alias and
//  mutate the same set directly.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class PlaylistLayoutModel;

@interface PlaylistSelectionModel : NSObject

- (instancetype)initWithLayout:(PlaylistLayoutModel *)layout;

@property (nonatomic, strong, readonly) PlaylistLayoutModel *layout;
@property (nonatomic, strong, readonly) NSMutableIndexSet *selectedIndices;  // stable identity, playlist indices
@property (nonatomic, assign) NSInteger focusIndex;    // playlist index, -1 = none
@property (nonatomic, assign) NSInteger anchorIndex;   // shift-selection anchor, -1 = none

// Single click / shift-click on a track. With extend YES and a valid anchor,
// replaces the selection with the anchor..index range; otherwise selects just
// the index and moves the anchor. Focus follows the index in both cases.
- (void)selectPlaylistIndex:(NSInteger)playlistIndex extendFromAnchor:(BOOL)extend;

// Cmd-click on a track: toggles membership. Focus and anchor are untouched.
- (void)togglePlaylistIndex:(NSInteger)playlistIndex;

// Additive range selection (no anchor/focus change).
- (void)addIndexesInRange:(NSRange)range;

// Select all tracks (additive, like the original). No anchor/focus change.
- (void)selectAll;

// Clear the selection. Anchor and focus are untouched (original semantics).
- (void)deselectAll;

// Click on a group header / album-art column. range is the group's playlist
// index range. Cmd toggles the whole group; shift (with a valid anchor)
// extends from the anchor to the group's far edge; otherwise the group
// replaces the selection and the anchor moves to its first track. Focus moves
// to the group's first track in all cases.
- (void)clickGroupRange:(NSRange)range commandKey:(BOOL)hasCmd shiftKey:(BOOL)hasShift;

// Keyboard navigation by `delta` display rows from the current focus,
// skipping header/subgroup/padding rows (searching forward in the movement
// direction, then backward from the target). Updates selection, anchor and
// focus like the original view logic. Returns the display row the view should
// scroll to, or -1 if no move happened.
- (NSInteger)moveFocusBy:(NSInteger)delta extendSelection:(BOOL)extend;

@end

NS_ASSUME_NONNULL_END
