//
//  AlbumArtController.h
//  foo_jl_album_art_mac
//
//  Main controller for Album Art (Extended) component
//

#pragma once

#import <Cocoa/Cocoa.h>
#import "AlbumArtView.h"
#import "ArtworkLightboxController.h"
#import "../Core/RemoteArtworkSearchController.h"
#import "../Core/ArtworkSaveController.h"

#ifdef __cplusplus
#include "../Core/AlbumArtConfig.h"
#include <foobar2000/SDK/foobar2000.h>
#endif

NS_ASSUME_NONNULL_BEGIN

@interface AlbumArtController : NSViewController <AlbumArtViewDelegate, RemoteArtworkSearchDelegate, ArtworkLightboxDelegate, ArtworkSaveDelegate>

// Initialize with layout parameters
- (instancetype)initWithParameters:(nullable NSDictionary<NSString*, NSString*>*)params NS_DESIGNATED_INITIALIZER;

// The controller is always constructed with layout parameters; there is no
// nib or archive to load it from
- (instancetype)initWithNibName:(nullable NSNibName)nibNameOrNil
                         bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

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

// Remote artwork search
- (void)fetchMissingArtwork;
- (void)cancelSearch;

@end

NS_ASSUME_NONNULL_END
