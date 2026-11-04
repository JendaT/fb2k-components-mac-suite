//
//  TidalStreamResolver.h
//  foo_jl_tidal_mac
//
//  Stream URL resolution with DRM fallback
//

#pragma once

#import <Foundation/Foundation.h>
#import "../Core/TidalModels.h"
#import "../API/TidalConstants.h"

NS_ASSUME_NONNULL_BEGIN

/// Completion handler for stream resolution
typedef void (^JLTidalStreamResolverCompletion)(JLTidalPlaybackInfo * _Nullable info, NSError * _Nullable error);

/// Completion handler for metadata
typedef void (^JLTidalMetadataCompletion)(JLTidalTrack * _Nullable track, NSError * _Nullable error);

@interface JLTidalStreamResolver : NSObject

/// Shared resolver instance
+ (instancetype)shared;

/// Initialize the resolver (call on startup)
- (void)initialize;

/// Shutdown the resolver (call on quit)
- (void)shutdown;

#pragma mark - Stream Resolution

/// Resolve stream URL for a track at the globally preferred quality.
/// Implements quality fallback cascade if DRM is detected
/// Uses cache when available
- (void)resolveStreamForTrackID:(NSString *)trackID
                     completion:(JLTidalStreamResolverCompletion)completion;

/// Resolve at an explicit starting quality (a playlist entry's "?q=" pin).
/// Same fallback cascade; the pin is the ceiling, not a guarantee.
- (void)resolveStreamForTrackID:(NSString *)trackID
                        quality:(JLTidalQuality)quality
                     completion:(JLTidalStreamResolverCompletion)completion;

/// Invalidate cached streams for a track at every quality (e.g., after 403)
- (void)invalidateCacheForTrackID:(NSString *)trackID;

#pragma mark - Metadata

/// Get track metadata (uses cache)
- (void)getMetadataForTrackID:(NSString *)trackID
                   completion:(JLTidalMetadataCompletion)completion;

@end

NS_ASSUME_NONNULL_END
