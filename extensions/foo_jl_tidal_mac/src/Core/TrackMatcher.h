//
//  TrackMatcher.h
//  foo_jl_tidal_mac
//
//  Matching a local file to a TIDAL catalogue track, for the jl_tidal_lookup
//  service (shared/jl_tidal_api.h): cache keys, the search query, picking a
//  search result, and TIDAL's key spelling turned into the usual notation.
//
//  Pure: Foundation only, no foobar2000 SDK, no network.
//

#pragma once

#import <Foundation/Foundation.h>
#import "TidalModels.h"

NS_ASSUME_NONNULL_BEGIN

/// How far a search result's length may be from the local file's, seconds.
extern const double JLTidalMatchLengthTolerance;

@interface JLTidalTrackMatcher : NSObject

/// An ISRC tag reduced to its 12 characters ("US-AB1-23-45678" ->
/// "USAB12345678"), or nil when it is not a well-formed ISRC.
+ (nullable NSString *)normalizedISRC:(nullable NSString *)isrc;

/// Every name in ARTIST values, whole and split on the usual separators
/// ("A & B", "A feat. B", "A, B"), so "Simon & Garfunkel" still matches a
/// TIDAL artist of that name while "A feat. B" matches either. Names come
/// back folded (case, diacritics, width), ready for bestMatchIn: and the
/// cache key.
+ (NSArray<NSString *> *)artistNamesFromTagValues:(NSArray<NSString *> *)values;

/// "Artist Title" for the search endpoint: the first artist value, and the
/// title without trailing "(...)"/"[...]" groups, which TIDAL keeps in a
/// separate version field.
+ (NSString *)searchQueryForArtist:(NSString *)artist title:(NSString *)title;

/// The result that is the same recording: a shared artist, the same title
/// (with or without TIDAL's version suffix), and a length within the
/// tolerance. Closest length wins; ties keep TIDAL's ranking. Nil when none
/// qualifies or the local length is unknown.
+ (nullable JLTidalTrack *)bestMatchIn:(NSArray<JLTidalTrack *> *)candidates
                               artists:(NSArray<NSString *> *)artists
                                 title:(NSString *)title
                                length:(double)seconds;

/// Cache key for an item: "id:<trackID>" for a tidal:// entry, else
/// "isrc:<ISRC>", else "search:<artists>\t<title>\t<seconds>". Nil when
/// there is nothing to match on.
+ (nullable NSString *)cacheKeyForTrackID:(nullable NSString *)trackID
                                     isrc:(nullable NSString *)isrc
                                  artists:(NSArray<NSString *> *)artists
                                    title:(nullable NSString *)title
                                   length:(double)seconds;

/// TIDAL's key and scale in the usual notation: ("FSharp", "MINOR") ->
/// "F#m", ("Eb", "MAJOR") -> "Eb", ("D", "DORIAN") -> "D Dorian". The tonic
/// alone when the scale is unknown; empty when the key is.
+ (NSString *)keyNameForKey:(nullable NSString *)key scale:(nullable NSString *)scale;

@end

NS_ASSUME_NONNULL_END
