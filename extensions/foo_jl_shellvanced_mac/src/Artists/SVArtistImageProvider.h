//
//  SVArtistImageProvider.h
//  foo_jl_shellvanced_mac
//
//  Round artist images: Deezer photo (strict matching), else the newest
//  album's cover, else initials. Photos are fetched lazily on request and
//  cached on disk under ~/Library/Caches/foo_jl_shellvanced/artists/.
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface SVArtistImageProvider : NSObject

+ (instancetype)shared;

/// Main thread only. `completion` is always called on the main thread, possibly
/// synchronously when the image is already in memory. The image is round-cropped
/// at `points` (resolution independent, Retina-aware); never nil.
- (void)imageForArtist:(NSString *)name
                  size:(CGFloat)points
            completion:(void (^)(NSImage *image))completion;

@end

NS_ASSUME_NONNULL_END
