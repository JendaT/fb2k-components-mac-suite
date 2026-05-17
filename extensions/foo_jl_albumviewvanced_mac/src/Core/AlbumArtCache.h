#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^AlbumArtCompletion)(NSImage * _Nullable image);

@interface AlbumArtCache : NSObject

+ (instancetype)sharedCache;

/// Returns cached image immediately, or nil while loading asynchronously.
- (nullable NSImage *)imageForPath:(NSString *)path
                              size:(CGFloat)thumbnailSize
                        completion:(nullable AlbumArtCompletion)completion;

- (void)clearCache;

/// Placeholder image drawn when art is loading or missing.
+ (NSImage *)placeholderImageOfSize:(CGFloat)size;

@end

NS_ASSUME_NONNULL_END
