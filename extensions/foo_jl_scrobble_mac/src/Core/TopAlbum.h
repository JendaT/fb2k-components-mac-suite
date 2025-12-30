//
//  TopAlbum.h
//  foo_jl_scrobble
//
//  Data model for Last.fm top album statistics
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TopAlbum : NSObject

@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic) NSInteger playcount;
@property (nonatomic) NSInteger rank;
@property (nonatomic, copy, nullable) NSURL *imageURL;      // Best available from fallback chain
@property (nonatomic, copy, nullable) NSURL *lastfmURL;
@property (nonatomic, copy, nullable) NSString *mbid;       // MusicBrainz ID (optional)

/// Create from Last.fm API response dictionary
+ (nullable instancetype)albumFromDictionary:(NSDictionary *)dict;

/// Get best available image URL from image array (fallback chain: extralarge > large > medium > small)
+ (nullable NSURL *)bestImageURLFromArray:(NSArray *)images;

@end

NS_ASSUME_NONNULL_END
