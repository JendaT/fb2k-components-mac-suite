//
//  ArtworkEmbedController.h
//  foo_jl_album_art_mac
//
//  Embeds artwork into audio file tags using the foobar2000 SDK
//

#pragma once

#import <Foundation/Foundation.h>
#import "ArtworkResult.h"
#import "TrackMetadata.h"

NS_ASSUME_NONNULL_BEGIN

/// Result of an embed operation
typedef NS_ENUM(NSInteger, ArtworkEmbedResult) {
    ArtworkEmbedResultSuccess = 0,
    ArtworkEmbedResultFileNotWritable,
    ArtworkEmbedResultFormatNotSupported,
    ArtworkEmbedResultEncodeFailed,
    ArtworkEmbedResultSDKError,
};

@interface ArtworkEmbedController : NSObject

/// Check if the given track's file format supports embedded artwork
+ (BOOL)formatSupportsEmbedding:(TrackMetadata *)metadata;

/// Check if artwork can be embedded (format supported AND file writable)
+ (BOOL)canEmbedArtworkForTrack:(TrackMetadata *)metadata;

/// Embed artwork into the track's audio file
/// @param image The artwork image to embed (will be converted to JPEG)
/// @param artworkType The type of artwork (front, back, etc.)
/// @param metadata Track metadata (provides file path)
/// @param error On failure, set to a description of the error
/// @return Result of the embed operation
+ (ArtworkEmbedResult)embedImage:(NSImage *)image
                     artworkType:(RemoteArtworkType)artworkType
                        metadata:(TrackMetadata *)metadata
                           error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
