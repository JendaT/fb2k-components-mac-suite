//
//  ArtistNameMatcher.h
//  foo_jl_biography_mac
//
//  Artist-name disambiguation rules shared by the API clients.
//  Contains NO foobar2000 SDK dependency and NO networking code.
//  Logic moved verbatim from AudioDbClient/DeezerClient; behavior unchanged.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ArtistNameMatcher : NSObject

/// Whether a name returned by an API is an acceptable match for the requested artist.
/// Case-insensitive exact match; containment only for names >= 4 chars (QUAL-16);
/// falls back to comparison with "the/a/an" prefixes stripped.
+ (BOOL)name:(nullable NSString *)returnedName matchesRequested:(nullable NSString *)requestedName;

/// Pick the best match from an array of result dictionaries (SEC-9):
/// exact case-insensitive match on nameKey wins; otherwise the first result
/// is accepted only if it contains the search term and the term is >= 4 chars.
/// Returns nil when no acceptable match exists.
+ (nullable NSDictionary *)bestMatchInResults:(NSArray *)results
                                      forName:(NSString *)requestedName
                                      nameKey:(NSString *)nameKey;

@end

NS_ASSUME_NONNULL_END
