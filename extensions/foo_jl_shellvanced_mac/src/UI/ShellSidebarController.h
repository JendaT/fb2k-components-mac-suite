#pragma once

#import <Cocoa/Cocoa.h>
#include "../Core/ShellCore.h"

NS_ASSUME_NONNULL_BEGIN

@class ShellSidebarController;

@protocol ShellSidebarDelegate <NSObject>
// The user picked a row (click / arrow keys) or created a playlist.
- (void)sidebar:(ShellSidebarController *)sidebar didChooseDestination:(const shellcore::Destination &)destination;
@end

// Source-list sidebar: fixed "Albums" row, "Your Library" header with a +
// button and [Playlists] [Artists] filter chips, then playlist rows (every
// playlist except "Now Playing") and the artists section.
@interface ShellSidebarController : NSViewController

@property (nonatomic, weak, nullable) id<ShellSidebarDelegate> delegate;

// Re-reads playlists from foobar. Deferred while a rename is being typed.
- (void)reloadPlaylists;

// Highlights the row for `destination` without notifying the delegate.
// Clears the highlight when the row isn't visible (filtered out / missing).
- (void)reflectDestination:(const shellcore::Destination &)destination;

// Creates "New Playlist" (auto-numbered), opens it and starts inline rename.
- (void)createPlaylistAndBeginRename;

// The sidebar's list, for focus handling.
@property (nonatomic, readonly) NSTableView *tableView;

@end

NS_ASSUME_NONNULL_END
