//
//  AlbumArtController.h
//  foo_jl_album_art_mac
//
//  Main controller for Album Art (Extended) component
//

#pragma once

#import <Cocoa/Cocoa.h>
#import "AlbumArtView.h"

#ifdef __cplusplus
#include "../Core/AlbumArtConfig.h"
#include <foobar2000/SDK/foobar2000.h>
#endif

NS_ASSUME_NONNULL_BEGIN

@interface AlbumArtController : NSViewController <AlbumArtViewDelegate>

// Initialize with layout parameters
- (instancetype)initWithParameters:(nullable NSDictionary<NSString*, NSString*>*)params;

// Playback callbacks (called from AlbumArtCallbackManager)
#ifdef __cplusplus
- (void)handleNewTrack:(metadb_handle_ptr)track;
#endif
- (void)handlePlaybackStop;

// Navigation
- (void)navigateToPreviousType;
- (void)navigateToNextType;

// Refresh artwork (e.g., after type change)
- (void)refreshArtwork;

@end

NS_ASSUME_NONNULL_END
