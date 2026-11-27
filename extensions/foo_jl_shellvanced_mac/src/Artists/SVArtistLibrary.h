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

/// First track of the artist's newest album (for the cover fallback); invalid if unknown.
- (metadb_handle_ptr)representativeHandleForArtist:(NSString *)name;

@end

NS_ASSUME_NONNULL_END
