//
//  GroupBoundary.h
//  foo_simplaylist_mac
//
//  Sparse group boundary data for efficient large playlist handling
//  Instead of creating O(n) GroupNode objects, we store O(groups) boundaries
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Represents a group boundary (album/header) in the playlist
/// For 10,000 tracks with 100 albums, we only need ~100 of these objects
@interface GroupBoundary : NSObject

/// First playlist index in this group (inclusive)
@property (nonatomic, assign) NSInteger startPlaylistIndex;

/// Last playlist index in this group (inclusive)
@property (nonatomic, assign) NSInteger endPlaylistIndex;

/// Row offset where this group starts in the display
/// (accounts for previous headers)
@property (nonatomic, assign) NSInteger rowOffset;

/// Header text (album name, etc.)
@property (nonatomic, copy) NSString *headerText;

/// Album art cache key
@property (nonatomic, copy, nullable) NSString *albumArtKey;

/// Number of tracks in this group
- (NSInteger)trackCount;

/// Number of rows this group occupies (1 header + trackCount tracks)
- (NSInteger)rowCount;

/// Check if a playlist index falls within this group
- (BOOL)containsPlaylistIndex:(NSInteger)index;

/// Factory method
+ (instancetype)boundaryWithStartIndex:(NSInteger)start
                              endIndex:(NSInteger)end
                             rowOffset:(NSInteger)offset
                            headerText:(NSString *)text
                           albumArtKey:(nullable NSString *)artKey;

@end

NS_ASSUME_NONNULL_END
