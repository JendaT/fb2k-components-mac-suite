//
//  TrackMetadata+FB2K.h
//  foo_jl_album_art_mac
//
//  SDK-dependent factory for TrackMetadata
//  Kept separate so TrackMetadata itself stays Foundation-only (testable)
//

#pragma once

#include "../fb2k_sdk.h"

#ifdef __OBJC__
#import "TrackMetadata.h"

NS_ASSUME_NONNULL_BEGIN

@interface TrackMetadata (FB2K)

/// Create metadata snapshot from SDK track handle
/// @param track metadb_handle_ptr; returns nil if invalid
+ (nullable instancetype)metadataFromTrack:(metadb_handle_ptr)track;

@end

NS_ASSUME_NONNULL_END

#endif // __OBJC__
