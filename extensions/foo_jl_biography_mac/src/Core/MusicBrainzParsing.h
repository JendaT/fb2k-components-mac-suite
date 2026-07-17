//
//  MusicBrainzParsing.h
//  foo_jl_biography_mac
//
//  Pure parsing of MusicBrainz ws/2 responses.
//  Contains NO foobar2000 SDK dependency and NO networking code.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MusicBrainzParsing : NSObject

/// Pick the MBID of the best artist match from an artist search response.
/// Accepts only results with score >= 90 whose name passes ArtistNameMatcher
/// against the requested name; returns nil when nothing qualifies.
+ (nullable NSString *)bestMBIDFromSearchResponse:(NSDictionary *)response
                                    requestedName:(NSString *)requestedName;

/// Extract the Wikidata entity ID (e.g. "Q11647") from an artist lookup
/// response with url-rels included. Returns nil when no wikidata relation exists.
+ (nullable NSString *)wikidataQIDFromArtistResponse:(NSDictionary *)response;

@end

NS_ASSUME_NONNULL_END
