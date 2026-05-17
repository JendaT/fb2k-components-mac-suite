//
//  LibVancedController.h
//  foo_jl_libvanced
//
//  Main view controller for the library browser panel
//

#pragma once

#import <Cocoa/Cocoa.h>
#include "../fb2k_sdk.h"

NS_ASSUME_NONNULL_BEGIN

@interface LibVancedController : NSViewController

// Library event handlers (called from LibraryCallbacks)
- (void)handleLibraryItemsAdded;
- (void)handleLibraryItemsRemoved;
- (void)handleLibraryItemsModified;

// Playback event handlers
- (void)handlePlaybackNewTrack:(metadb_handle_ptr)track;
- (void)handlePlaybackStopped;

@end

NS_ASSUME_NONNULL_END
