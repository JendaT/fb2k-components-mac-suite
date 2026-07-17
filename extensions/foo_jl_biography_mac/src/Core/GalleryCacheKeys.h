//
//  GalleryCacheKeys.h
//  foo_jl_biography_mac
//
//  Cache-key derivation for the artist image cache.
//  Contains NO foobar2000 SDK dependency and NO I/O.
//  Logic moved verbatim from ArtistImageCache; behavior unchanged.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GalleryCacheKeys : NSObject

/// SHA-256 of the absolute URL plus a "_thumb"/"_full" suffix.
+ (NSString *)keyForImageURL:(NSURL *)url thumbnail:(BOOL)thumbnail;

/// SHA-256 of the lowercased+trimmed artist name plus a "_gallery" suffix.
+ (NSString *)keyForArtist:(NSString *)artistName;

@end

NS_ASSUME_NONNULL_END
