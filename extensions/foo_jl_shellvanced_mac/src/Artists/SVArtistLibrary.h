//
//  SVArtistLibrary.h
//  foo_jl_shellvanced_mac
//
//  Artist index over the foobar2000 media library. Objective-C++ header:
//  import from .mm only. All methods are MAIN THREAD ONLY.
//

#pragma once

#import <Foundation/Foundation.h>
#include "../fb2k_sdk.h"

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const SVArtistLibraryDidChangeNotification;

/// Singleton; rebuilds from library_manager (debounced 1 s) on library changes.
@interface SVArtistLibrary : NSObject

+ (instancetype)shared;

/// Display names, sorted by artistKey.
@property (readonly) NSArray<NSString *> *artistNames;

/// Owned + appears-on tracks in date/album/disc/track order.
- (metadb_handle_list)handlesForArtist:(NSString *)name;

- (NSUInteger)albumCountForArtist:(NSString *)name;   // owned + appears-on
- (NSUInteger)trackCountForArtist:(NSString *)name;

/// Album + track titles (raw), used to disambiguate Deezer candidates.
- (NSArray<NSString *> *)userTitlesForArtist:(NSString *)name;

/// Album titles only (owned + appears-on), raw.
- (NSArray<NSString *> *)albumTitlesForArtist:(NSString *)name;

/// Co-artist keys (artistKey) from the user's own tags: other artists on the same tracks / album artists
/// of albums the artist appears on. The artist itself is never included.
- (NSArray<NSString *> *)coArtistKeysForArtist:(NSString *)name;

/// Raw multi-artist tag strings ("A vs B") the artist appears in.
- (NSArray<NSString *> *)collabStringsForArtist:(NSString *)name;

/// Tracks to probe for cover art (newest album first, one per album, up to 6); empty if unknown.
- (metadb_handle_list)coverProbeHandlesForArtist:(NSString *)name;

/// First track of the artist's newest album (for the cover fallback); invalid if unknown.
- (metadb_handle_ptr)representativeHandleForArtist:(NSString *)name;

@end

NS_ASSUME_NONNULL_END
