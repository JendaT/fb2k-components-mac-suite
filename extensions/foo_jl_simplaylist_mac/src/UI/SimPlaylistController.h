//
//  SimPlaylistController.h
//  foo_simplaylist_mac
//
//  View controller for SimPlaylist UI element
//

#pragma once

#import <Cocoa/Cocoa.h>
#include <memory>
#include "../fb2k_sdk.h"

NS_ASSUME_NONNULL_BEGIN

@class SimPlaylistView;
@class GroupNode;

@interface SimPlaylistController : NSViewController

@property (nonatomic, readonly) SimPlaylistView *playlistView;

// Playlist event handlers (called from PlaylistCallbacks)
- (void)handlePlaylistSwitched;
- (void)handleItemsAdded:(NSInteger)base count:(NSInteger)count addedHandles:(std::shared_ptr<metadb_handle_list>)handles;
- (void)handleItemsRemoved:(NSInteger)newCount;
- (void)handleItemsReordered;
- (void)handleSelectionChanged;
- (void)handleFocusChanged:(NSInteger)from to:(NSInteger)to;
- (void)handleItemsModified;

// Scroll/visibility event handlers
- (void)handleEnsureVisible:(NSInteger)playlistIndex;

// Playback event handlers
- (void)handlePlaybackNewTrack:(metadb_handle_ptr)track;
- (void)handlePlaybackStopped;

// Queue event handlers
- (void)handleQueueChanged;

// Metadb event handlers — fires when tags are read/updated in background
- (void)handleMetadbChanged:(std::shared_ptr<metadb_handle_list>)changed;

// Rebuild the view from current playlist
- (void)rebuildFromPlaylist;

// Save group cache for current playlist (synchronous, for shutdown)
- (void)saveGroupCacheForCurrentPlaylist;

@end

NS_ASSUME_NONNULL_END
