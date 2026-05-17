//
//  LibraryAlbumArtCache.h
//  foo_jl_libvanced
//
//  LRU album art cache for library tree nodes
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^AlbumArtCompletionBlock)(NSImage * _Nullable image);

@interface LibraryAlbumArtCache : NSObject

+ (instancetype)sharedCache;

// Get album art for a track path, loading asynchronously if needed
- (nullable NSImage *)imageForPath:(NSString *)path
                        completion:(nullable AlbumArtCompletionBlock)completion;

- (void)clearCache;

@end

NS_ASSUME_NONNULL_END
