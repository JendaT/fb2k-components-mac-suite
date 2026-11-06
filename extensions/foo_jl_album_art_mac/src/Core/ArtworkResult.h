//
//  ArtworkResult.h
//  foo_jl_album_art_mac
//
//  Model for a single artwork search result
//  Immutable data object returned from ArtworkSourceProvider
//

#pragma once

#import <Foundation/Foundation.h>
#import "RemoteArtworkTypes.h"

NS_ASSUME_NONNULL_BEGIN

/// Represents a single artwork result from a remote source
/// Immutable after creation
@interface ArtworkResult : NSObject

/// Source identifier (e.g., "caa", "itunes", "deezer")
@property (readonly, copy) NSString *sourceIdentifier;

/// Human-readable source name (e.g., "Cover Art Archive")
@property (readonly, copy) NSString *sourceName;

/// URL for thumbnail image (250-500px)
@property (readonly, strong) NSURL *thumbnailURL;

/// URL for full resolution image
@property (readonly, strong) NSURL *fullResolutionURL;

/// Image resolution (from API metadata, or CGSizeZero if unknown)
@property (readonly) CGSize resolution;

/// Type of artwork
@property (readonly) RemoteArtworkType artworkType;

/// SHA-256 hash of thumbnail for deduplication (lowercase hex, 64 chars)
/// Computed after thumbnail is downloaded
@property (readonly, copy, nullable) NSString *imageHash;

/// Variant descriptions (e.g., ["Vinyl", "Limited Edition"])
@property (readonly, copy, nullable) NSArray<NSString *> *variants;

/// Initialize with required properties
- (instancetype)initWithSourceIdentifier:(NSString *)sourceIdentifier
                              sourceName:(NSString *)sourceName
                            thumbnailURL:(NSURL *)thumbnailURL
                       fullResolutionURL:(NSURL *)fullResolutionURL
                              resolution:(CGSize)resolution
                             artworkType:(RemoteArtworkType)artworkType
                               imageHash:(nullable NSString *)imageHash
                                variants:(nullable NSArray<NSString *> *)variants;

/// Convenience initializer for sources without hash yet
- (instancetype)initWithSourceIdentifier:(NSString *)sourceIdentifier
                              sourceName:(NSString *)sourceName
                            thumbnailURL:(NSURL *)thumbnailURL
                       fullResolutionURL:(NSURL *)fullResolutionURL
                              resolution:(CGSize)resolution
                             artworkType:(RemoteArtworkType)artworkType;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// Create copy with updated hash (for post-download deduplication)
- (ArtworkResult *)resultWithImageHash:(NSString *)hash;

/// Resolution description for display
/// Returns "1200x1200" or "Unknown" if CGSizeZero
@property (readonly) NSString *resolutionDescription;

/// Type description including variants
/// Returns "Front Cover" or "Front Cover (Vinyl, Limited Edition)"
@property (readonly) NSString *typeDescription;

@end

#pragma mark - Hash Utility

/// Compute SHA-256 hash of image data for deduplication
NSString *ArtworkImageHash(NSData *imageData);

NS_ASSUME_NONNULL_END
