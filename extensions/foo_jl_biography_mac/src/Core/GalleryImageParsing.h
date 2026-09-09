//
//  GalleryImageParsing.h
//  foo_jl_biography_mac
//
//  Pure JSON->ArtistImage mapping for the gallery image sources.
//  Contains NO foobar2000 SDK dependency and NO networking code.
//  Logic moved verbatim from AudioDbClient/FanartTvClient/DeezerClient; behavior unchanged.
//

#pragma once

#import <Foundation/Foundation.h>

@class ArtistImage;

NS_ASSUME_NONNULL_BEGIN

@interface GalleryImageParsing : NSObject

/// TheAudioDB: map an artist object (search.php result) to images.
/// Enumerates strArtistFanart[1-4]/Thumb/Logo/WideThumb/Banner/Cutout/Clearart;
/// backgrounds get the "/preview" thumbnail suffix.
+ (NSArray<ArtistImage *> *)imagesFromAudioDbArtist:(NSDictionary *)artist;

/// Fanart.tv: map a v3 music response to images
/// (artistbackground, artistthumb, hdmusiclogo, musiclogo, musicbanner; keeps likes).
+ (NSArray<ArtistImage *> *)imagesFromFanartTvResponse:(NSDictionary *)response;

/// Deezer: map a matched artist object to its single best picture
/// (picture_xl > picture_big > picture_medium). Returns nil for the default
/// placeholder (empty-picture MD5 in the URL) or when no usable URL exists.
+ (nullable ArtistImage *)imageFromDeezerArtist:(NSDictionary *)artist;

/// Whether a string is a well-formed MusicBrainz ID (UUID). Guards against
/// path injection when the MBID is interpolated into request URLs.
+ (BOOL)isValidMBID:(nullable NSString *)mbid;

@end

NS_ASSUME_NONNULL_END
