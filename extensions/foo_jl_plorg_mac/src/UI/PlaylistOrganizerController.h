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

@end

NS_ASSUME_NONNULL_END
