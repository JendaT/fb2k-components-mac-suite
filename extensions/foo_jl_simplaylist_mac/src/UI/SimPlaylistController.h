//
//  SimPlaylistController.h
//  foo_simplaylist_mac
//
//  View controller for SimPlaylist UI element
//

#pragma once

#import <Cocoa/Cocoa.h>
#include "../fb2k_sdk.h"

NS_ASSUME_NONNULL_BEGIN

@class SimPlaylistView;
@class GroupNode;

@interface SimPlaylistController : NSViewController

@property (nonatomic, readonly) SimPlaylistView *playlistView;

// Playlist event handlers (called from PlaylistCallbacks)
- (void)handlePlaylistSwitched;
- (void)handleItemsAdded:(NSInteger)base count:(NSInteger)count;
- (void)handleItemsRemoved;
- (void)handleItemsReordered;
- (void)handleSelectionChanged;
- (void)handleFocusChanged:(NSInteger)from to:(NSInteger)to;
- (void)handleItemsModified;

// Playback event handlers
- (void)handlePlaybackNewTrack:(metadb_handle_ptr)track;
- (void)handlePlaybackStopped;

// Rebuild the view from current playlist
- (void)rebuildFromPlaylist;

@end

NS_ASSUME_NONNULL_END
