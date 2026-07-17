//
//  LastFmParsing.h
//  foo_jl_biography_mac
//
//  Pure parsing/sanitization of Last.fm artist.getinfo responses.
//  Contains NO foobar2000 SDK dependency and NO networking code.
//  Logic moved verbatim from LastFmBioClient/BiographyFetcher; behavior unchanged.
//

#pragma once

#import <Foundation/Foundation.h>

@class BiographyData;

NS_ASSUME_NONNULL_BEGIN

@interface LastFmParsing : NSObject

/// Parse artist info response into builder fields
/// @param response The JSON "artist" object from artist.getinfo
/// @return Dictionary with parsed fields (name, mbid, biography, tags, imageURL, stats, similarArtists)
+ (NSDictionary *)parseArtistInfoResponse:(NSDictionary *)response;

/// Decode HTML entities, strip tags, trim, remove the "Read more on Last.fm" suffix.
/// Caps input at 50k characters.
+ (nullable NSString *)cleanBiographyText:(nullable NSString *)text;

/// Map a parsed artist.getinfo response to an immutable BiographyData.
/// Skips the Last.fm default placeholder image.
+ (BiographyData *)biographyDataFromArtistInfoResponse:(NSDictionary *)response
                                            artistName:(NSString *)artistName;

@end

NS_ASSUME_NONNULL_END
