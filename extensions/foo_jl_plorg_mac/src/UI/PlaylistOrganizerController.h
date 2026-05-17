//
//  PlaylistOrganizerController.h
//  foo_plorg_mac
//
//  Main controller for the Playlist Organizer panel
//

#pragma once

#import <Cocoa/Cocoa.h>
#import "PlorgOutlineView.h"
#import "UUIDRemappingWindowController.h"

NS_ASSUME_NONNULL_BEGIN

@class TreeNode;
@class TreeModel;

@interface PlaylistOrganizerController : NSViewController <NSOutlineViewDataSource, PlorgOutlineViewDelegate, UUIDRemappingWindowDelegate>

@property (nonatomic, strong, readonly) NSOutlineView *outlineView;
@property (nonatomic, strong, readonly) NSScrollView *scrollView;

// Actions
- (void)reloadTree;
- (void)expandAll;
- (void)collapseAll;
- (void)revealPlaylist:(NSString *)playlistName;

// Context menu actions
- (IBAction)createFolder:(nullable id)sender;
- (IBAction)createPlaylist:(nullable id)sender;
- (IBAction)renameItem:(nullable id)sender;
- (IBAction)deleteItem:(nullable id)sender;
- (IBAction)sortAscending:(nullable id)sender;
- (IBAction)sortDescending:(nullable id)sender;

// Corruption check
- (NSArray *)checkForCorruptedPlaylists;
- (void)removeCorruptedPlaylists:(NSArray *)playlists;
- (void)showCorruptedPlaylistsDialog:(NSArray *)corrupted;

@end

NS_ASSUME_NONNULL_END
